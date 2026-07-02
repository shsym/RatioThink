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

_HERE = Path(__file__).resolve().parent
_ROOT = _HERE.parents[1]
_VENDORED_PIE_CLIENT = _ROOT / "Vendor" / "pie" / "client" / "python" / "src"
if str(_VENDORED_PIE_CLIENT) not in sys.path:
    sys.path.insert(0, str(_VENDORED_PIE_CLIENT))
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

from pie_client import PieClient  # noqa: E402
import e2e_test as h  # noqa: E402
import analyze_tree_dump as tree_analysis  # noqa: E402
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
PROMPT_INDEXES = os.environ.get("PROMPT_INDEXES", "")
SINGLE_TEMPERATURE = float(os.environ.get("SINGLE_TEMPERATURE", "0.0"))
SINGLE_THINKING = os.environ.get("SINGLE_THINKING", "false").lower() in ("1", "true", "yes")
TOT_BREADTH = int(os.environ.get("TOT_BREADTH", os.environ.get("TOT_WIDTH", "3")))
TOT_DEPTH = int(os.environ.get("TOT_DEPTH", os.environ.get("MATH_DEPTH", "2")))
TOT_BEAM = int(os.environ.get("TOT_BEAM", "2"))
TOT_TASK = os.environ.get("TOT_TASK", "reasoning")
TOT_TEMPERATURE = float(os.environ.get("TOT_TEMPERATURE", "0.7"))
TOT_SIBLING_PENALTY = float(os.environ.get("TOT_SIBLING_PENALTY", "0.0"))
TOT_PROMPT_FRAMING = os.environ.get("TOT_PROMPT_FRAMING", "baseline")
TOT_SWEEP = os.environ.get("TOT_SWEEP", "0") == "1"
PROFILE_ARMS = os.environ.get("PROFILE_ARMS", "both").strip().lower()
BON_N = int(os.environ.get("BON_N", os.environ.get("BEST_OF_N", "3")))
BON_TEMPERATURE = float(os.environ.get("BON_TEMPERATURE", "0.7"))
BON_TOP_P = float(os.environ.get("BON_TOP_P", "0.95"))
BON_THINKING = os.environ.get("BON_THINKING", "false").lower() in ("1", "true", "yes")
OUT = os.environ.get("PROFILE_ACCURACY_OUT", "tot_profile_accuracy.json")
RAW_TOT_DIR = os.environ.get("PROFILE_ACCURACY_RAW_TOT_DIR", "")
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
    any_correct_branch: bool | None = None
    correct_branch_count: int = 0
    answer_histogram: dict[str, int] = field(default_factory=dict)
    coverage_loss_kind: str | None = None
    node_count: int = 0
    selected_candidate_id: str | None = None
    release_snapshots: list[str] = field(default_factory=list)


@dataclass(frozen=True)
class TotSweepArm:
    name: str
    breadth: int
    depth: int
    beam_width: int
    temperature: float
    sibling_penalty: float
    prompt_framing: str


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
    best_of_n: ArmResult = field(default_factory=ArmResult)
    tot_sweep: dict[str, ArmResult] = field(default_factory=dict)


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


def _final_verdict(grader: str, answer: str, reference: dict) -> str:
    verdict = g.grade(grader, answer, reference)
    if verdict.passed is True:
        return "pass"
    if verdict.passed is False:
        return "fail"
    return "ungradable"


def parse_tot_stream(
    text: str,
    fallback_count: Callable[[str], int] | None = None,
    grader: str | None = None,
    reference: dict | None = None,
) -> ArmResult:
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
    nodes: list[dict] = []
    for e in events:
        if e.get("event") != "node_complete":
            continue
        node = e.get("node") or {}
        nodes.append(node)
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
    branch_summary = None
    if grader is not None and reference is not None:
        branch_summary = tree_analysis.analyze_record({
            "grader": grader,
            "reference": reference,
            "selected": terminal.get("selected_node_id"),
            "final_verdict": _final_verdict(grader, answer, reference),
            "nodes": nodes,
        })
    return ArmResult(
        answer=answer,
        tokens=tokens,
        token_source=token_source,
        n_token_fallback=n_token_fallback,
        node_errors=node_errors,
        any_correct_branch=(
            branch_summary["correct_in_tree"] if branch_summary is not None else None
        ),
        correct_branch_count=(
            branch_summary["n_correct_nodes"] if branch_summary is not None else 0
        ),
        answer_histogram=(
            branch_summary["answer_histogram"] if branch_summary is not None else {}
        ),
        coverage_loss_kind=(
            branch_summary["loss_kind"] if branch_summary is not None else None
        ),
        node_count=len(nodes),
    )


def _arm_name(
    breadth: int,
    depth: int,
    beam_width: int,
    temperature: float,
    sibling_penalty: float,
    prompt_framing: str,
    prefix: str = "sweep",
) -> str:
    temp = f"{temperature:g}"
    penalty = f"{sibling_penalty:g}"
    return (
        f"{prefix}_b{breadth}_d{depth}_beam{beam_width}_"
        f"t{temp}_pen{penalty}_{prompt_framing}"
    )


def build_tot_sweep_arms() -> list[TotSweepArm]:
    arms = [
        TotSweepArm(
            name="default_b3_d2_beam2_t0.7_pen0_baseline",
            breadth=3,
            depth=2,
            beam_width=2,
            temperature=0.7,
            sibling_penalty=0.0,
            prompt_framing="baseline",
        )
    ]
    for breadth in (2, 3, 4, 5):
        for beam_width in (1, 2):
            for temperature in (0.7, 1.0, 1.3):
                for sibling_penalty in (0.0, 2.0):
                    for prompt_framing in ("baseline", "counter_reading"):
                        arms.append(TotSweepArm(
                            name=_arm_name(
                                breadth,
                                2,
                                beam_width,
                                temperature,
                                sibling_penalty,
                                prompt_framing,
                            ),
                            breadth=breadth,
                            depth=2,
                            beam_width=beam_width,
                            temperature=temperature,
                            sibling_penalty=sibling_penalty,
                            prompt_framing=prompt_framing,
                        ))
    return arms


def apply_prompt_framing(prompt: str, framing: str) -> str:
    if framing == "baseline":
        return prompt
    if framing == "counter_reading":
        return (
            f"{prompt}\n\n"
            "Before choosing, explicitly test the counter-reading that each "
            "statement could be false. Then give only the final choice number."
        )
    raise ValueError(f"unknown ToT prompt framing {framing!r}")


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


def apply_single_prompt_framing(prompt: str) -> str:
    if not SINGLE_THINKING:
        return prompt
    return (
        "Use the hidden thought channel for a brief check before answering. "
        f"{prompt}"
    )


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
    coverage_measured = 0
    any_correct_branch = 0
    answer_histogram: dict[str, int] = {}
    token_sources: dict[str, int] = {}
    n_token_fallback = 0
    for item in items:
        arm: ArmResult = getattr(item, arm_name)
        node_error_count += len(arm.node_errors)
        if arm.any_correct_branch is not None:
            coverage_measured += 1
            if arm.any_correct_branch:
                any_correct_branch += 1
        for answer, count in arm.answer_histogram.items():
            answer_histogram[answer] = answer_histogram.get(answer, 0) + count
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
        "branch_coverage_measured": coverage_measured,
        "any_correct_branch_count": any_correct_branch,
        "answer_histogram": dict(sorted(answer_histogram.items())),
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
    row = {
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
    sweep_names = sorted({name for item in items for name in item.tot_sweep})
    if sweep_names:
        row["tot_sweep"] = {
            name: _cell([
                ItemResult(
                    dataset=item.dataset,
                    index=item.index,
                    prompt_id=item.prompt_id,
                    reference=item.reference,
                    single=item.single,
                    tot=item.tot_sweep[name],
                )
                for item in items
                if name in item.tot_sweep
            ], "tot", grader)
            for name in sweep_names
        }
    return row


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


def select_records_for_run(records: list[dict], indexes: str = "") -> list[tuple[int, dict]]:
    if not indexes.strip():
        selected = records[:MAX_PROMPTS] if MAX_PROMPTS > 0 else records
        return list(enumerate(selected, 1))
    out: list[tuple[int, dict]] = []
    for raw in indexes.split(","):
        raw = raw.strip()
        if not raw:
            continue
        idx = int(raw)
        if idx < 0 or idx >= len(records):
            raise ValueError(f"PROMPT_INDEXES entry {idx} outside 0..{len(records) - 1}")
        out.append((idx, records[idx]))
    return out


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


def write_raw_tot_stream(text: str, model: str, prompt_framing: str) -> None:
    if not RAW_TOT_DIR:
        return
    target = Path(RAW_TOT_DIR)
    target.mkdir(parents=True, exist_ok=True)
    safe_model = "".join(ch if ch.isalnum() or ch in "-_" else "_" for ch in model)
    name = f"tot-{int(time.time() * 1000)}-{os.getpid()}-{safe_model}-{prompt_framing}.sse"
    (target / name).write_text(text)


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
    out = {
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
    if item.tot_sweep:
        out["tot_sweep"] = {}
        for name, arm in sorted(item.tot_sweep.items()):
            bucket, passed = _score_arm(arm, grader, item.reference)
            out["tot_sweep"][name] = {
                **asdict(arm),
                "grade": bucket,
                "passed": passed,
            }
    return out


async def _single_once(http_c: httpx.AsyncClient, base_url: str, model: str,
                       prompt: str, count) -> ArmResult:
    body = {
        "model": model,
        "messages": [{"role": "user", "content": apply_single_prompt_framing(prompt)}],
        "temperature": SINGLE_TEMPERATURE,
        "thinking": SINGLE_THINKING,
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
                    prompt: str, count, grader: str | None = None,
                    reference: dict | None = None,
                    arm: TotSweepArm | None = None) -> ArmResult:
    breadth = arm.breadth if arm else TOT_BREADTH
    depth = arm.depth if arm else TOT_DEPTH
    beam_width = arm.beam_width if arm else TOT_BEAM
    temperature = arm.temperature if arm else TOT_TEMPERATURE
    sibling_penalty = arm.sibling_penalty if arm else TOT_SIBLING_PENALTY
    prompt_framing = arm.prompt_framing if arm else TOT_PROMPT_FRAMING
    body = {
        "inferlet": "tree-of-thought",
        "stream": True,
        "input": {
            "model": model,
            "messages": [{
                "role": "user",
                "content": apply_prompt_framing(prompt, prompt_framing),
            }],
            "breadth": breadth,
            "depth": depth,
            "beam_width": beam_width,
            "max_tokens_per_node": MAX_TOKENS,
            "temperature": temperature,
            "task": TOT_TASK,
            "sibling_penalty": sibling_penalty,
        },
    }
    started = time.monotonic()
    try:
        r = await http_c.post(f"{base_url}/v1/chat/completions", json=body)
        latency = time.monotonic() - started
        if r.status_code != 200:
            return ArmResult(latency_s=latency, error=f"tot dispatch {r.status_code}: {r.text[:200]}")
        write_raw_tot_stream(r.text, model, prompt_framing)
        parsed = parse_tot_stream(r.text, count, grader=grader, reference=reference)
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
    if PROFILE_ARMS not in {"both", "single"}:
        raise ValueError("PROFILE_ARMS must be 'both' or 'single'")
    grader = base._grader_for(dataset)
    records, total = base._load_prompts(dataset)
    selected_records = select_records_for_run(records, PROMPT_INDEXES)
    arms = _arms_from_env()
    if PROFILE_ARMS == "single":
        arms = {"single"}
    items: list[ItemResult] = []
    run_tot = "tot" in arms
    sweep_arms = build_tot_sweep_arms() if run_tot and TOT_SWEEP else []
    default_arm = sweep_arms[0] if sweep_arms else None
    async with httpx.AsyncClient(timeout=900) as http_c:
        for ordinal, (record_index, rec) in enumerate(selected_records, 1):
            prompt_id = str(rec.get("id") or f"{dataset}:{record_index}")
            single = (
                await _single_once(http_c, base_url, model, rec["prompt"], count)
                if "single" in arms else _skipped_arm()
            )
            if run_tot:
                tot = await _tot_once(
                    http_c, base_url, model, rec["prompt"], count, grader, rec["reference"],
                    arm=default_arm,
                )
            elif PROFILE_ARMS == "single":
                tot = ArmResult(error="skipped by PROFILE_ARMS=single")
            else:
                tot = _skipped_arm()
            best_of_n = (
                await _best_of_n_once(http_c, base_url, model, rec["prompt"], count, grader)
                if "best_of_n" in arms else _skipped_arm()
            )
            tot_sweep: dict[str, ArmResult] = {}
            for arm in sweep_arms[1:]:
                tot_sweep[arm.name] = await _tot_once(
                    http_c, base_url, model, rec["prompt"], count,
                    grader, rec["reference"], arm=arm,
                )
            item = ItemResult(
                dataset, record_index, prompt_id, rec["reference"], single, tot,
                best_of_n, tot_sweep
            )
            items.append(item)
            single_bucket, _ = _score_arm(single, grader, rec["reference"])
            tot_bucket, _ = _score_arm(tot, grader, rec["reference"])
            bon_bucket, _ = _score_arm(best_of_n, grader, rec["reference"])
            print(
                f"[profile-accuracy] {model} {dataset} {ordinal}/{len(selected_records)} "
                f"idx={record_index} "
                f"single={single_bucket} tot={tot_bucket} best_of_n={bon_bucket} "
                f"tot_node_errors={len(tot.node_errors)} "
                f"tot_any_correct_branch={tot.any_correct_branch} "
                f"bon_node_errors={len(best_of_n.node_errors)}",
                flush=True,
            )
    row = summarize_model(model, items, grader, dataset=dataset)
    row["coverage"] = {"measured": len(selected_records), "total": total}
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
        "prompt_indexes": PROMPT_INDEXES or None,
        "max_tokens": MAX_TOKENS,
        "models": models,
        "arms": sorted(_arms_from_env()),
        "token_unit": unit,
        "profile_arms": PROFILE_ARMS,
        "single": {
            "temperature": SINGLE_TEMPERATURE,
            "thinking": SINGLE_THINKING,
            "prompt_framing": "hidden_thought_channel" if SINGLE_THINKING else "baseline",
        },
        "tot": {
            "breadth": TOT_BREADTH,
            "depth": TOT_DEPTH,
            "beam_width": TOT_BEAM,
            "task": TOT_TASK,
            "temperature": TOT_TEMPERATURE,
            "sibling_penalty": TOT_SIBLING_PENALTY,
            "prompt_framing": TOT_PROMPT_FRAMING,
            "sweep_enabled": TOT_SWEEP,
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
    if TOT_SWEEP:
        settings["tot"]["sweep_arms"] = [asdict(arm) for arm in build_tot_sweep_arms()]

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
