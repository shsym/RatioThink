"""Shipped ToT profile vs single-pass accuracy harness (#852).

This is the slice-1 product-surface harness.  It deliberately does **not** run
the academic host-side BFS twin in :mod:`tot_accuracy_real`; it reuses that
module only for boot configuration, dataset selection/loading, tokenizer cost
accounting, and model defaults.  The measured arms are:

* ``single`` — ordinary ``/v1/chat/completions`` single pass.
* ``tot`` — shipped ``tree-of-thought`` inferlet dispatched through
  ``/v1/chat/completions`` via the advanced profile envelope.
* ``best_of_n`` — shipped ``best-of-n`` inferlet dispatched through the same
  advanced profile envelope, with the harness selecting one candidate by a
  deterministic no-gold self-consistency rule.

The matrix is resilient: transport/terminal/node failures are recorded per item
and disclosed, ungradable/error items are held out of accuracy denominators, and
the run continues to the next prompt/model.
"""
from __future__ import annotations

import asyncio
import json
import os
import statistics
import subprocess
import sys
import tempfile
import time
from dataclasses import asdict, dataclass, field
from difflib import SequenceMatcher
from pathlib import Path
from typing import Callable

import httpx
from pie_client import PieClient

_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

import e2e_test as h  # noqa: E402
import grade as g  # noqa: E402
import tot_accuracy_real as base  # noqa: E402


DEFAULT_MODELS = (
    "Qwen/Qwen3-0.6B",
    "Qwen/Qwen3-4B",
    "Qwen/Qwen3-8B",
    "Qwen/Qwen3-14B-GGUF",
)
DEFAULT_DATASETS = ("gsm8k", "humaneval", "mbpp", "mmlu")
MAX_PROMPTS = int(os.environ.get("MAX_PROMPTS", "6"))
MAX_TOKENS = int(os.environ.get("MAX_TOKENS", "512"))
TOT_BREADTH = int(os.environ.get("TOT_BREADTH", os.environ.get("TOT_WIDTH", "2")))
TOT_DEPTH = int(os.environ.get("TOT_DEPTH", os.environ.get("MATH_DEPTH", "2")))
TOT_BEAM = int(os.environ.get("TOT_BEAM", "1"))
TOT_TASK = os.environ.get("TOT_TASK", "reasoning")
TOT_TEMPERATURE = float(os.environ.get("TOT_TEMPERATURE", "0.7"))
BON_N = int(os.environ.get("BON_N", os.environ.get("BEST_OF_N", "3")))
BON_TEMPERATURE = float(os.environ.get("BON_TEMPERATURE", "0.7"))
BON_TOP_P = float(os.environ.get("BON_TOP_P", "0.95"))
BON_THINKING = os.environ.get("BON_THINKING", "false").lower() in ("1", "true", "yes")
OUT = os.environ.get("PROFILE_ACCURACY_OUT", "tot_profile_accuracy.json")
ARM_NAMES = ("single", "tot", "best_of_n")


class ModelBootError(Exception):
    """Expected per-model boot/setup failure that should not abort the matrix."""

    def __init__(self, original: Exception):
        self.original = original
        super().__init__(f"{type(original).__name__}: {original}")


@dataclass
class ArmResult:
    answer: str | None = None
    tokens: int = 0
    latency_s: float = 0.0
    error: str | None = None
    token_source: str | None = None
    n_token_fallback: int = 0
    node_errors: list[dict] = field(default_factory=list)
    selected_candidate_id: str | None = None
    release_snapshots: list[str] = field(default_factory=list)


@dataclass(frozen=True)
class BestOfNCandidate:
    id: str
    branch_index: int
    content: str
    snapshot_name: str | None = None


@dataclass
class ItemResult:
    dataset: str
    index: int
    prompt_id: str
    reference: dict
    single: ArmResult
    tot: ArmResult
    best_of_n: ArmResult


def _models_from_env() -> list[str]:
    if os.environ.get("MODELS"):
        return [m.strip() for m in os.environ["MODELS"].split(",") if m.strip()]
    if os.environ.get("MODEL"):
        return [os.environ["MODEL"]]
    return list(DEFAULT_MODELS)


def _arms_from_env() -> set[str]:
    raw = os.environ.get("PROFILE_ACCURACY_ARMS")
    if not raw:
        return set(ARM_NAMES)
    arms = {arm.strip() for arm in raw.split(",") if arm.strip()}
    unknown = arms.difference(ARM_NAMES)
    if unknown:
        raise SystemExit(f"unknown PROFILE_ACCURACY_ARMS values: {sorted(unknown)}")
    return arms


def _skipped_arm() -> ArmResult:
    return ArmResult(token_source="skipped")


def shmem_name(index: int) -> str:
    return f"/tot_profile_accuracy_{os.getpid()}_{index}"


def parse_single_pass_response(payload: dict, fallback_count: Callable[[str], int]) -> ArmResult:
    try:
        msg = (payload.get("choices") or [{}])[0].get("message") or {}
        answer = ((msg.get("content") or "").strip()
                  or (msg.get("reasoning_content") or "").strip())
    except (AttributeError, IndexError) as e:
        return ArmResult(error=f"malformed chat response: {e}")
    usage = payload.get("usage") or {}
    completion_tokens = usage.get("completion_tokens")
    if isinstance(completion_tokens, int):
        return ArmResult(answer=answer, tokens=completion_tokens,
                         token_source="usage.completion_tokens")
    return ArmResult(answer=answer, tokens=fallback_count(answer or ""),
                     token_source="tokenizer_fallback", n_token_fallback=1)


def parse_tot_stream(text: str, fallback_count: Callable[[str], int] | None = None) -> ArmResult:
    events: list[dict] = []
    malformed: str | None = None
    for line in text.splitlines():
        if not line.startswith("data:"):
            continue
        payload = line[len("data:"):].strip()
        if not payload or payload == "[DONE]":
            continue
        try:
            events.append(json.loads(payload))
        except json.JSONDecodeError as e:
            malformed = f"malformed SSE JSON: {e}"
            break

    if malformed:
        return ArmResult(error=malformed)
    terminal = next((e for e in reversed(events)
                     if e.get("event") in ("tree_complete", "error")), None)
    metrics = next((e for e in reversed(events)
                    if e.get("event") == "generation_metrics"), {})
    node_errors: list[dict] = []
    for e in events:
        if e.get("event") != "node_complete":
            continue
        node = e.get("node") or {}
        if node.get("status") != "ok" or node.get("error") or node.get("score_error"):
            node_errors.append({
                "id": node.get("id"),
                "depth": node.get("depth"),
                "status": node.get("status"),
                "error": node.get("error"),
                "score_error": node.get("score_error"),
            })

    if not terminal:
        return ArmResult(error="missing terminal tree_complete/error frame",
                         node_errors=node_errors)
    if terminal.get("event") == "error":
        return ArmResult(error=terminal.get("message") or "terminal error",
                         node_errors=node_errors)

    answer = (terminal.get("final_answer") or "").strip()
    tokens = metrics.get("output_tokens")
    if isinstance(tokens, int):
        token_source = "generation_metrics.output_tokens"
        n_token_fallback = 0
    else:
        tokens = (fallback_count or (lambda s: len(s.split())))(answer)
        token_source = "tokenizer_fallback"
        n_token_fallback = 1
    return ArmResult(answer=answer, tokens=tokens, token_source=token_source,
                     n_token_fallback=n_token_fallback, node_errors=node_errors)


def _sse_events(text: str) -> tuple[list[dict], str | None]:
    events: list[dict] = []
    for line in text.splitlines():
        if not line.startswith("data:"):
            continue
        payload = line[len("data:"):].strip()
        if not payload or payload == "[DONE]":
            continue
        try:
            events.append(json.loads(payload))
        except json.JSONDecodeError as e:
            return events, f"malformed SSE JSON: {e}"
    return events, None


def _normalized_text_key(text: str) -> str:
    return " ".join(text.lower().split())


def _self_consistency_key(grader: str, text: str) -> str:
    if grader in ("gsm8k_numeric", "mcq_numeric"):
        tail = g.last_number(text)
        return f"number:{tail}" if tail is not None else f"text:{_normalized_text_key(text)}"
    if grader in ("humaneval_exec", "mbpp_exec"):
        return f"code:{_normalized_text_key(g.extract_code(text))}"
    if grader == "jsonschema_validate":
        extracted = g.extract_json(text)
        if extracted is not None:
            try:
                return "json:" + json.dumps(json.loads(extracted), sort_keys=True, separators=(",", ":"))
            except json.JSONDecodeError:
                return f"json_text:{_normalized_text_key(extracted)}"
        return f"text:{_normalized_text_key(text)}"
    return f"text:{_normalized_text_key(text)}"


def select_best_of_n_candidate(
    candidates: list[BestOfNCandidate],
    answer_key: Callable[[str], str] | None = None,
) -> BestOfNCandidate:
    """Choose a Best-of-N candidate without consulting the gold answer.

    Prefer the modal extracted final answer (self-consistency).  Within that
    bucket, choose the response most textually central to all pickable
    candidates; length and branch index are stable tie-breakers.
    """
    if not candidates:
        raise ValueError("cannot select from an empty Best-of-N candidate list")
    key = answer_key or _normalized_text_key
    buckets: dict[str, list[BestOfNCandidate]] = {}
    for candidate in candidates:
        buckets.setdefault(key(candidate.content), []).append(candidate)
    majority = max(buckets.values(), key=lambda group: (len(group), -group[0].branch_index))
    if len(candidates) == 1:
        return candidates[0]

    def centrality(candidate: BestOfNCandidate) -> float:
        peers = [c for c in candidates if c.id != candidate.id]
        if not peers:
            return 1.0
        return statistics.mean(
            SequenceMatcher(None, candidate.content, peer.content).ratio()
            for peer in peers
        )

    return max(majority, key=lambda c: (centrality(c), len(c.content), -c.branch_index))


def parse_best_of_n_stream(
    text: str,
    fallback_count: Callable[[str], int] | None = None,
    answer_key: Callable[[str], str] | None = None,
) -> ArmResult:
    events, malformed = _sse_events(text)
    node_errors: list[dict] = []
    contents: dict[str, str] = {}
    branch_indexes: dict[str, int] = {}

    if malformed:
        return ArmResult(error=malformed)

    for e in events:
        if e.get("event") != "node_complete":
            continue
        node = e.get("node") or {}
        node_id = str(node.get("id") or "")
        if isinstance(node.get("branch_index"), int):
            branch_indexes[node_id] = node["branch_index"]
        content = str(node.get("content") or "").strip()
        if node.get("status") == "ok" and content:
            contents[node_id] = content
        else:
            node_errors.append({
                "id": node.get("id"),
                "depth": node.get("depth"),
                "status": node.get("status"),
                "error": node.get("error"),
                "score_error": node.get("score_error"),
            })

    terminal_error = next((e for e in reversed(events) if e.get("event") == "error"), None)
    if terminal_error:
        return ArmResult(
            error=terminal_error.get("message") or "terminal error",
            node_errors=node_errors,
        )

    selection = next((e for e in reversed(events)
                      if e.get("event") == "awaiting_selection"), None)
    if not selection:
        return ArmResult(
            error="missing terminal awaiting_selection frame",
            node_errors=node_errors,
        )

    candidates: list[BestOfNCandidate] = []
    release_snapshots: list[str] = []
    for pick in selection.get("candidates") or []:
        candidate_id = str(pick.get("id") or "")
        snapshot_name = pick.get("snapshot_name")
        if snapshot_name:
            release_snapshots.append(str(snapshot_name))
        if not candidate_id or candidate_id not in contents:
            continue
        branch_index = pick.get("branch_index")
        if not isinstance(branch_index, int):
            branch_index = branch_indexes.get(candidate_id, len(candidates))
        candidates.append(BestOfNCandidate(
            id=candidate_id,
            branch_index=branch_index,
            content=contents[candidate_id],
            snapshot_name=str(snapshot_name) if snapshot_name else None,
        ))

    if not candidates:
        return ArmResult(
            error="awaiting_selection had no parseable candidates",
            node_errors=node_errors,
            release_snapshots=release_snapshots,
        )

    selected = select_best_of_n_candidate(candidates, answer_key=answer_key)
    metrics = next((e for e in reversed(events)
                    if e.get("event") == "generation_metrics"), {})
    tokens = metrics.get("output_tokens")
    if isinstance(tokens, int):
        token_source = "generation_metrics.output_tokens"
        n_token_fallback = 0
    else:
        counter = fallback_count or (lambda s: len(s.split()))
        tokens = sum(counter(candidate.content) for candidate in candidates)
        token_source = "tokenizer_fallback_all_candidates"
        n_token_fallback = len(candidates)

    return ArmResult(
        answer=selected.content,
        tokens=tokens,
        token_source=token_source,
        n_token_fallback=n_token_fallback,
        node_errors=node_errors,
        selected_candidate_id=selected.id,
        release_snapshots=release_snapshots,
    )


def _score_arm(arm: ArmResult, grader: str, reference: dict) -> tuple[str, bool | None]:
    if arm.error:
        return "error", None
    if arm.answer is None:
        return "ungradable", None
    verdict = g.grade(grader, arm.answer, reference)
    if verdict.passed is None:
        return "ungradable", None
    return ("correct" if verdict.passed else "wrong"), verdict.passed


def _cell(items: list[ItemResult], arm_name: str, grader: str) -> dict:
    n_correct = n_wrong = n_ungradable = n_error = 0
    tokens: list[int] = []
    latencies: list[float] = []
    tokens_per_second: list[float] = []
    first_error: str | None = None
    node_error_count = 0
    token_sources: dict[str, int] = {}
    n_token_fallback = 0
    for item in items:
        arm: ArmResult = getattr(item, arm_name)
        node_error_count += len(arm.node_errors)
        bucket, passed = _score_arm(arm, grader, item.reference)
        if bucket == "error":
            n_error += 1
            first_error = first_error or arm.error
            continue
        if bucket == "ungradable":
            n_ungradable += 1
            continue
        if arm.token_source:
            token_sources[arm.token_source] = token_sources.get(arm.token_source, 0) + 1
        n_token_fallback += arm.n_token_fallback
        tokens.append(arm.tokens)
        latencies.append(arm.latency_s)
        if arm.latency_s > 0:
            tokens_per_second.append(arm.tokens / arm.latency_s)
        if passed is True:
            n_correct += 1
        else:
            n_wrong += 1
    n_graded = n_correct + n_wrong
    accuracy = (n_correct / n_graded) if n_graded else None
    return {
        "n_correct": n_correct,
        "n_wrong": n_wrong,
        "n_ungradable": n_ungradable,
        "n_error": n_error,
        "n_graded": n_graded,
        "accuracy": accuracy,
        "mean_tokens": statistics.mean(tokens) if tokens else None,
        "mean_latency_s": statistics.mean(latencies) if latencies else None,
        "mean_tokens_per_second": (
            statistics.mean(tokens_per_second) if tokens_per_second else None
        ),
        "first_error": first_error,
        "node_error_count": node_error_count,
        "token_sources": token_sources,
        "n_token_fallback": n_token_fallback,
    }


def _mean_paired_delta(items: list[ItemResult], attr: str, arm_name: str = "tot") -> float | None:
    deltas: list[float] = []
    for item in items:
        arm: ArmResult = getattr(item, arm_name)
        if item.single.error or arm.error:
            continue
        if item.single.answer is None or arm.answer is None:
            continue
        deltas.append(float(getattr(arm, attr)) - float(getattr(item.single, attr)))
    return statistics.mean(deltas) if deltas else None


def _mean_paired_tokens_per_second_delta(
    items: list[ItemResult], arm_name: str = "tot"
) -> float | None:
    deltas: list[float] = []
    for item in items:
        arm: ArmResult = getattr(item, arm_name)
        if item.single.error or arm.error:
            continue
        if item.single.answer is None or arm.answer is None:
            continue
        if item.single.latency_s <= 0 or arm.latency_s <= 0:
            continue
        deltas.append(
            (arm.tokens / arm.latency_s)
            - (item.single.tokens / item.single.latency_s)
        )
    return statistics.mean(deltas) if deltas else None


def summarize_model(model: str, items: list[ItemResult], grader: str,
                    dataset: str | None = None) -> dict:
    dataset = dataset or (items[0].dataset if items else None)
    single = _cell(items, "single", grader)
    tot = _cell(items, "tot", grader)
    best_of_n = _cell(items, "best_of_n", grader)
    acc_delta = bon_acc_delta = None
    if single["accuracy"] is not None and tot["accuracy"] is not None:
        acc_delta = tot["accuracy"] - single["accuracy"]
    if single["accuracy"] is not None and best_of_n["accuracy"] is not None:
        bon_acc_delta = best_of_n["accuracy"] - single["accuracy"]
    return {
        "model": model,
        "dataset": dataset,
        "single": single,
        "tot": tot,
        "best_of_n": best_of_n,
        "accuracy_delta_tot_minus_single": acc_delta,
        "accuracy_delta_best_of_n_minus_single": bon_acc_delta,
        "mean_token_delta_tot_minus_single": _mean_paired_delta(items, "tokens"),
        "mean_token_delta_best_of_n_minus_single": (
            _mean_paired_delta(items, "tokens", "best_of_n")
        ),
        "mean_latency_delta_s_tot_minus_single": _mean_paired_delta(items, "latency_s"),
        "mean_latency_delta_s_best_of_n_minus_single": (
            _mean_paired_delta(items, "latency_s", "best_of_n")
        ),
        "mean_tokens_per_second_delta_tot_minus_single": (
            _mean_paired_tokens_per_second_delta(items)
        ),
        "mean_tokens_per_second_delta_best_of_n_minus_single": (
            _mean_paired_tokens_per_second_delta(items, "best_of_n")
        ),
        "items": [_item_to_json(item, grader) for item in items],
    }


def build_artifact(models: list[dict], settings: dict) -> dict:
    return {
        "framing": (
            "Shipped tree-of-thought and Best-of-N profiles vs ordinary "
            "single-pass /v1/chat/completions on identical prompts. This does "
            "not run the academic host-side BFS harness."
        ),
        "settings": settings,
        "models": models,
    }


def _empty_cell(first_error: str | None = None) -> dict:
    return {
        "n_correct": 0,
        "n_wrong": 0,
        "n_ungradable": 0,
        "n_error": 1 if first_error else 0,
        "n_graded": 0,
        "accuracy": None,
        "mean_tokens": None,
        "mean_latency_s": None,
        "mean_tokens_per_second": None,
        "first_error": first_error,
        "node_error_count": 0,
        "token_sources": {},
        "n_token_fallback": 0,
    }


def model_boot_error_row(model: str, exc: ModelBootError, dataset: str | None = None) -> dict:
    original = exc.original
    err = f"{type(original).__name__}: {original}"
    return {
        "model": model,
        "dataset": dataset or "unknown",
        "boot_error": err,
        "single": _empty_cell(err),
        "tot": _empty_cell(err),
        "best_of_n": _empty_cell(err),
        "accuracy_delta_tot_minus_single": None,
        "accuracy_delta_best_of_n_minus_single": None,
        "mean_token_delta_tot_minus_single": None,
        "mean_token_delta_best_of_n_minus_single": None,
        "mean_latency_delta_s_tot_minus_single": None,
        "mean_latency_delta_s_best_of_n_minus_single": None,
        "mean_tokens_per_second_delta_tot_minus_single": None,
        "mean_tokens_per_second_delta_best_of_n_minus_single": None,
        "items": [],
        "coverage": {"measured": 0, "total": None},
    }


async def collect_model_rows(
    models: list[str], datasets: list[str], run_one, write_partial=None
) -> list[dict]:
    rows: list[dict] = []
    for index, model in enumerate(models, 1):
        try:
            model_rows = await run_one(index, model)
        except ModelBootError as exc:
            model_rows = [model_boot_error_row(model, exc, dataset) for dataset in datasets]
            print(f"[profile-accuracy] model boot failed for {model}: "
                  f"{model_rows[0]['boot_error']}", file=sys.stderr, flush=True)
        rows.extend(model_rows)
        if write_partial is not None:
            write_partial(rows)
    return rows


def _datasets_from_env() -> list[str]:
    if os.environ.get("DATASETS"):
        return base._which_datasets()
    return list(DEFAULT_DATASETS)


async def collect_dataset_rows(model: str, datasets: list[str], run_one_dataset) -> list[dict]:
    rows: list[dict] = []
    for dataset in datasets:
        rows.append(await run_one_dataset(model, dataset))
    return rows


def atomic_write_json(path: str | Path, payload: dict) -> None:
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(
        prefix=f".{target.name}.",
        suffix=".tmp",
        dir=str(target.parent),
        text=True,
    )
    try:
        with os.fdopen(fd, "w") as tmp:
            json.dump(payload, tmp, indent=2)
            tmp.write("\n")
        os.replace(tmp_name, target)
    except Exception:
        try:
            os.unlink(tmp_name)
        except FileNotFoundError:
            pass
        raise


def has_any_graded_item(artifact: dict) -> bool:
    for row in artifact.get("models", []):
        for arm in ("single", "tot", "best_of_n"):
            if (row.get(arm) or {}).get("n_graded", 0) > 0:
                return True
    return False


def _item_to_json(item: ItemResult, grader: str) -> dict:
    single_bucket, single_passed = _score_arm(item.single, grader, item.reference)
    tot_bucket, tot_passed = _score_arm(item.tot, grader, item.reference)
    bon_bucket, bon_passed = _score_arm(item.best_of_n, grader, item.reference)
    return {
        "dataset": item.dataset,
        "index": item.index,
        "prompt_id": item.prompt_id,
        "reference": item.reference,
        "single": {**asdict(item.single), "grade": single_bucket, "passed": single_passed},
        "tot": {**asdict(item.tot), "grade": tot_bucket, "passed": tot_passed},
        "best_of_n": {**asdict(item.best_of_n), "grade": bon_bucket, "passed": bon_passed},
        "token_delta_tot_minus_single": item.tot.tokens - item.single.tokens
        if not (item.single.error or item.tot.error) else None,
        "token_delta_best_of_n_minus_single": item.best_of_n.tokens - item.single.tokens
        if not (item.single.error or item.best_of_n.error) else None,
        "latency_delta_s_tot_minus_single": item.tot.latency_s - item.single.latency_s
        if not (item.single.error or item.tot.error) else None,
        "latency_delta_s_best_of_n_minus_single": (
            item.best_of_n.latency_s - item.single.latency_s
        ) if not (item.single.error or item.best_of_n.error) else None,
    }


async def _single_once(http_c: httpx.AsyncClient, base_url: str, model: str,
                       prompt: str, count) -> ArmResult:
    body = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "temperature": 0.0,
        "max_tokens": MAX_TOKENS,
        "stream": False,
    }
    started = time.monotonic()
    try:
        r = await http_c.post(f"{base_url}/v1/chat/completions", json=body)
        latency = time.monotonic() - started
        if r.status_code != 200:
            return ArmResult(latency_s=latency, error=f"chat/completions {r.status_code}: {r.text[:200]}")
        parsed = parse_single_pass_response(r.json(), count)
        parsed.latency_s = latency
        return parsed
    except Exception as e:  # noqa: BLE001
        return ArmResult(latency_s=time.monotonic() - started,
                         error=f"{type(e).__name__}: {e}")


async def _tot_once(http_c: httpx.AsyncClient, base_url: str, model: str,
                    prompt: str, count) -> ArmResult:
    body = {
        "inferlet": "tree-of-thought",
        "stream": True,
        "input": {
            "model": model,
            "messages": [{"role": "user", "content": prompt}],
            "breadth": TOT_BREADTH,
            "depth": TOT_DEPTH,
            "beam_width": TOT_BEAM,
            "max_tokens_per_node": MAX_TOKENS,
            "temperature": TOT_TEMPERATURE,
            "task": TOT_TASK,
        },
    }
    started = time.monotonic()
    try:
        r = await http_c.post(f"{base_url}/v1/chat/completions", json=body)
        latency = time.monotonic() - started
        if r.status_code != 200:
            return ArmResult(latency_s=latency, error=f"tot dispatch {r.status_code}: {r.text[:200]}")
        parsed = parse_tot_stream(r.text, count)
        parsed.latency_s = latency
        return parsed
    except Exception as e:  # noqa: BLE001
        return ArmResult(latency_s=time.monotonic() - started,
                         error=f"{type(e).__name__}: {e}")


async def _release_best_of_n_snapshots(
    http_c: httpx.AsyncClient, base_url: str, names: list[str]
) -> str | None:
    if not names:
        return None
    try:
        r = await http_c.post(
            f"{base_url}/v1/chat/completions",
            json={"inferlet": "best-of-n", "stream": False, "input": {"release": names}},
        )
        if r.status_code != 200:
            return f"release {r.status_code}: {r.text[:200]}"
    except Exception as e:  # noqa: BLE001 - release failure is diagnostic only.
        return f"release {type(e).__name__}: {e}"
    return None


async def _best_of_n_once(http_c: httpx.AsyncClient, base_url: str, model: str,
                          prompt: str, count, grader: str) -> ArmResult:
    body = {
        "inferlet": "best-of-n",
        "stream": True,
        "input": {
            "model": model,
            "messages": [{"role": "user", "content": prompt}],
            "n": BON_N,
            "max_tokens_per_candidate": MAX_TOKENS,
            "temperature": BON_TEMPERATURE,
            "top_p": BON_TOP_P,
            "thinking": BON_THINKING,
        },
    }
    started = time.monotonic()
    try:
        r = await http_c.post(f"{base_url}/v1/chat/completions", json=body)
        latency = time.monotonic() - started
        if r.status_code != 200:
            return ArmResult(latency_s=latency, error=f"best-of-n dispatch {r.status_code}: {r.text[:200]}")
        parsed = parse_best_of_n_stream(
            r.text, count, answer_key=lambda text: _self_consistency_key(grader, text)
        )
        parsed.latency_s = latency
        release_error = await _release_best_of_n_snapshots(
            http_c, base_url, parsed.release_snapshots
        )
        if release_error:
            parsed.node_errors.append({"release_error": release_error})
        return parsed
    except Exception as e:  # noqa: BLE001
        return ArmResult(latency_s=time.monotonic() - started,
                         error=f"{type(e).__name__}: {e}")


async def _run_model_dataset(base_url: str, model: str, dataset: str, count) -> dict:
    grader = base._grader_for(dataset)
    records, total = base._load_prompts(dataset)
    if MAX_PROMPTS > 0:
        records = records[:MAX_PROMPTS]
    arms = _arms_from_env()
    items: list[ItemResult] = []
    async with httpx.AsyncClient(timeout=900) as http_c:
        for i, rec in enumerate(records, 1):
            prompt_id = str(rec.get("id") or f"{dataset}:{i}")
            single = (
                await _single_once(http_c, base_url, model, rec["prompt"], count)
                if "single" in arms else _skipped_arm()
            )
            tot = (
                await _tot_once(http_c, base_url, model, rec["prompt"], count)
                if "tot" in arms else _skipped_arm()
            )
            best_of_n = (
                await _best_of_n_once(http_c, base_url, model, rec["prompt"], count, grader)
                if "best_of_n" in arms else _skipped_arm()
            )
            item = ItemResult(dataset, i, prompt_id, rec["reference"], single, tot, best_of_n)
            items.append(item)
            single_bucket, _ = _score_arm(single, grader, rec["reference"])
            tot_bucket, _ = _score_arm(tot, grader, rec["reference"])
            bon_bucket, _ = _score_arm(best_of_n, grader, rec["reference"])
            print(
                f"[profile-accuracy] {model} {dataset} {i}/{len(records)} "
                f"single={single_bucket} tot={tot_bucket} best_of_n={bon_bucket} "
                f"tot_node_errors={len(tot.node_errors)} "
                f"bon_node_errors={len(best_of_n.node_errors)}",
                flush=True,
            )
    row = summarize_model(model, items, grader, dataset=dataset)
    row["coverage"] = {"measured": len(records), "total": total}
    return row


async def _run_model(base_url: str, model: str, datasets: list[str], count) -> list[dict]:
    async def run_one_dataset(_model: str, dataset: str) -> dict:
        return await _run_model_dataset(base_url, _model, dataset, count)

    return await collect_dataset_rows(model, datasets, run_one_dataset)


async def _run() -> dict:
    models = _models_from_env()
    datasets = _datasets_from_env()
    count, unit = base._load_tokenizer()
    settings = {
        "dataset": datasets[0] if len(datasets) == 1 else None,
        "datasets": datasets,
        "max_prompts": MAX_PROMPTS,
        "max_tokens": MAX_TOKENS,
        "models": models,
        "arms": sorted(_arms_from_env()),
        "token_unit": unit,
        "tot": {
            "breadth": TOT_BREADTH,
            "depth": TOT_DEPTH,
            "beam_width": TOT_BEAM,
            "task": TOT_TASK,
            "temperature": TOT_TEMPERATURE,
        },
        "best_of_n": {
            "n": BON_N,
            "max_tokens_per_candidate": MAX_TOKENS,
            "temperature": BON_TEMPERATURE,
            "top_p": BON_TOP_P,
            "thinking": BON_THINKING,
            "selection": "modal dataset-aware extracted answer, then textual centrality, length, branch order",
        },
    }

    def write_partial(rows: list[dict]) -> None:
        atomic_write_json(OUT, build_artifact(rows, settings))

    async def run_one(index: int, model: str) -> list[dict]:
        print(f"\n[profile-accuracy] booting model={model}", flush=True)
        with tempfile.TemporaryDirectory(prefix="tpa-", dir="/tmp") as tmp:
            tmp_path = Path(tmp)
            cfg = tmp_path / "config.toml"
            cfg.write_text(base.config_toml(model))
            pie_home = tmp_path / "home"
            pie_home.mkdir()
            env = {
                **os.environ,
                "PIE_HOME": str(pie_home),
                "PIE_SHMEM_NAME": shmem_name(index),
            }
            try:
                proc = subprocess.Popen(
                    [str(h.PIE_BIN), "serve", "--config", str(cfg), "--no-auth", "--debug"],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                    env=env,
                    bufsize=1,
                )
            except Exception as exc:  # noqa: BLE001 - subprocess setup is a model boot failure.
                raise ModelBootError(exc) from exc
            try:
                try:
                    ws_addr, token = await h._parse_handshake(proc, timeout=300)
                    print(f"[profile-accuracy] engine ws=ws://{ws_addr}", flush=True)
                except Exception as exc:  # noqa: BLE001 - handshake is a model boot failure.
                    raise ModelBootError(exc) from exc

                drain = asyncio.create_task(h._drain_stdout(proc))
                try:
                    try:
                        client = PieClient(f"ws://{ws_addr}")
                        await client.connect()
                        await client.auth_by_token(token)
                        await client.install_program(h.WASM_PATH, h.MANIFEST_PATH,
                                                     force_overwrite=True)
                        port = h._free_port()
                        base_url = f"http://127.0.0.1:{port}"
                        await client.launch_daemon("chat-apc@0.1.0", port)
                        if not h._wait_for_port(port, timeout=30):
                            raise RuntimeError(f"daemon never bound port {port}")
                    except Exception as exc:  # noqa: BLE001 - daemon setup is a model boot failure.
                        raise ModelBootError(exc) from exc
                    return await _run_model(base_url, model, datasets, count)
                finally:
                    drain.cancel()
            finally:
                h._terminate_subprocess(proc, "engine")

    rows = await collect_model_rows(models, datasets, run_one, write_partial)
    return build_artifact(rows, settings)


def _print(artifact: dict) -> None:
    print("\n" + "=" * 118)
    print("SHIPPED ToT + Best-of-N profiles vs single-pass accuracy/cost")
    print("=" * 118)
    print(f"{'model':28} {'dataset':12} {'single':>8} {'ToT':>8} {'BoN':>8} {'ΔToT':>8} {'ΔBoN':>8} {'ΔtokT':>9} {'ΔtokB':>9} {'ΔlatT':>9} {'ΔlatB':>9} {'nodeErr':>8}")
    print("-" * 118)
    for row in artifact["models"]:
        single = row["single"]
        tot = row["tot"]
        bon = row.get("best_of_n") or {}
        node_err = tot.get("node_error_count", 0) + bon.get("node_error_count", 0)
        def f(x, fmt="{:.3f}"):
            return fmt.format(x) if isinstance(x, (int, float)) else "--"
        print(
            f"{row['model'][:28]:28} "
            f"{str(row.get('dataset') or '--')[:12]:12} "
            f"{f(single.get('accuracy')):>8} {f(tot.get('accuracy')):>8} "
            f"{f(bon.get('accuracy')):>8} "
            f"{f(row.get('accuracy_delta_tot_minus_single'), '{:+.3f}'):>8} "
            f"{f(row.get('accuracy_delta_best_of_n_minus_single'), '{:+.3f}'):>8} "
            f"{f(row.get('mean_token_delta_tot_minus_single'), '{:+.1f}'):>9} "
            f"{f(row.get('mean_token_delta_best_of_n_minus_single'), '{:+.1f}'):>9} "
            f"{f(row.get('mean_latency_delta_s_tot_minus_single'), '{:+.2f}'):>9} "
            f"{f(row.get('mean_latency_delta_s_best_of_n_minus_single'), '{:+.2f}'):>9} "
            f"{node_err:>8}"
        )
        if single.get("first_error"):
            print(f"  single first_error: {single['first_error']}")
        if tot.get("first_error"):
            print(f"  ToT first_error: {tot['first_error']}")
        if bon.get("first_error"):
            print(f"  Best-of-N first_error: {bon['first_error']}")
    print("-" * 118)
    print("Accuracy excludes ungradable/error items per arm; nodeErr discloses ToT/Best-of-N node status/error/score_error events.")


async def main() -> int:
    assert h.PIE_BIN.exists(), f"missing pie binary at {h.PIE_BIN}"
    assert h.WASM_PATH.exists(), f"missing wasm at {h.WASM_PATH}"
    h.verify_stamp()
    artifact = await _run()
    atomic_write_json(OUT, artifact)
    _print(artifact)
    print(f"\n[profile-accuracy] artifact -> {OUT}")
    if not has_any_graded_item(artifact):
        print("[profile-accuracy] ERROR: no graded items were produced by any model/arm",
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
