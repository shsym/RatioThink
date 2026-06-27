"""Shipped ToT profile vs single-pass accuracy harness (#852).

This is the slice-1 product-surface harness.  It deliberately does **not** run
the academic host-side BFS twin in :mod:`tot_accuracy_real`; it reuses that
module only for boot configuration, dataset selection/loading, tokenizer cost
accounting, and model defaults.  The measured arms are:

* ``single`` — ordinary ``/v1/chat/completions`` single pass.
* ``tot`` — shipped ``tree-of-thought`` inferlet dispatched through
  ``/v1/chat/completions`` via the advanced profile envelope.

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
OUT = os.environ.get("PROFILE_ACCURACY_OUT", "tot_profile_accuracy.json")


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
    node_errors: list[dict] = field(default_factory=list)


@dataclass
class ItemResult:
    dataset: str
    index: int
    prompt_id: str
    reference: dict
    single: ArmResult
    tot: ArmResult


def _models_from_env() -> list[str]:
    if os.environ.get("MODELS"):
        return [m.strip() for m in os.environ["MODELS"].split(",") if m.strip()]
    if os.environ.get("MODEL"):
        return [os.environ["MODEL"]]
    return list(DEFAULT_MODELS)


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
                     token_source="tokenizer_fallback")


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
    else:
        tokens = (fallback_count or (lambda s: len(s.split())))(answer)
        token_source = "tokenizer_fallback"
    return ArmResult(answer=answer, tokens=tokens, token_source=token_source,
                     node_errors=node_errors)


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
    }


def _mean_paired_delta(items: list[ItemResult], attr: str) -> float | None:
    deltas: list[float] = []
    for item in items:
        if item.single.error or item.tot.error:
            continue
        if item.single.answer is None or item.tot.answer is None:
            continue
        deltas.append(float(getattr(item.tot, attr)) - float(getattr(item.single, attr)))
    return statistics.mean(deltas) if deltas else None


def _mean_paired_tokens_per_second_delta(items: list[ItemResult]) -> float | None:
    deltas: list[float] = []
    for item in items:
        if item.single.error or item.tot.error:
            continue
        if item.single.answer is None or item.tot.answer is None:
            continue
        if item.single.latency_s <= 0 or item.tot.latency_s <= 0:
            continue
        deltas.append(
            (item.tot.tokens / item.tot.latency_s)
            - (item.single.tokens / item.single.latency_s)
        )
    return statistics.mean(deltas) if deltas else None


def summarize_model(model: str, items: list[ItemResult], grader: str,
                    dataset: str | None = None) -> dict:
    dataset = dataset or (items[0].dataset if items else None)
    single = _cell(items, "single", grader)
    tot = _cell(items, "tot", grader)
    acc_delta = None
    if single["accuracy"] is not None and tot["accuracy"] is not None:
        acc_delta = tot["accuracy"] - single["accuracy"]
    return {
        "model": model,
        "dataset": dataset,
        "single": single,
        "tot": tot,
        "accuracy_delta_tot_minus_single": acc_delta,
        "mean_token_delta_tot_minus_single": _mean_paired_delta(items, "tokens"),
        "mean_latency_delta_s_tot_minus_single": _mean_paired_delta(items, "latency_s"),
        "mean_tokens_per_second_delta_tot_minus_single": (
            _mean_paired_tokens_per_second_delta(items)
        ),
        "items": [_item_to_json(item, grader) for item in items],
    }


def build_artifact(models: list[dict], settings: dict) -> dict:
    return {
        "framing": (
            "Shipped tree-of-thought profile vs ordinary single-pass "
            "/v1/chat/completions on identical prompts. This does not run "
            "the academic host-side BFS harness."
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
        "first_error": first_error,
        "node_error_count": 0,
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
        "accuracy_delta_tot_minus_single": None,
        "mean_token_delta_tot_minus_single": None,
        "mean_latency_delta_s_tot_minus_single": None,
        "mean_tokens_per_second_delta_tot_minus_single": None,
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
        for arm in ("single", "tot"):
            if (row.get(arm) or {}).get("n_graded", 0) > 0:
                return True
    return False


def _item_to_json(item: ItemResult, grader: str) -> dict:
    single_bucket, single_passed = _score_arm(item.single, grader, item.reference)
    tot_bucket, tot_passed = _score_arm(item.tot, grader, item.reference)
    return {
        "dataset": item.dataset,
        "index": item.index,
        "prompt_id": item.prompt_id,
        "reference": item.reference,
        "single": {**asdict(item.single), "grade": single_bucket, "passed": single_passed},
        "tot": {**asdict(item.tot), "grade": tot_bucket, "passed": tot_passed},
        "token_delta_tot_minus_single": item.tot.tokens - item.single.tokens
        if not (item.single.error or item.tot.error) else None,
        "latency_delta_s_tot_minus_single": item.tot.latency_s - item.single.latency_s
        if not (item.single.error or item.tot.error) else None,
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


async def _run_model_dataset(base_url: str, model: str, dataset: str, count) -> dict:
    grader = base._grader_for(dataset)
    records, total = base._load_prompts(dataset)
    if MAX_PROMPTS > 0:
        records = records[:MAX_PROMPTS]
    items: list[ItemResult] = []
    async with httpx.AsyncClient(timeout=900) as http_c:
        for i, rec in enumerate(records, 1):
            prompt_id = str(rec.get("id") or f"{dataset}:{i}")
            single = await _single_once(http_c, base_url, model, rec["prompt"], count)
            tot = await _tot_once(http_c, base_url, model, rec["prompt"], count)
            item = ItemResult(dataset, i, prompt_id, rec["reference"], single, tot)
            items.append(item)
            single_bucket, _ = _score_arm(single, grader, rec["reference"])
            tot_bucket, _ = _score_arm(tot, grader, rec["reference"])
            print(
                f"[profile-accuracy] {model} {dataset} {i}/{len(records)} "
                f"single={single_bucket} tot={tot_bucket} "
                f"tot_node_errors={len(tot.node_errors)}",
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
        "token_unit": unit,
        "tot": {
            "breadth": TOT_BREADTH,
            "depth": TOT_DEPTH,
            "beam_width": TOT_BEAM,
            "task": TOT_TASK,
            "temperature": TOT_TEMPERATURE,
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
    print("\n" + "=" * 96)
    print("SHIPPED ToT profile vs single-pass accuracy/cost")
    print("=" * 96)
    print(f"{'model':28} {'dataset':12} {'single':>8} {'ToT':>8} {'Δacc':>8} {'Δtok':>9} {'Δlat(s)':>9} {'ToT t/s':>9} {'nodeErr':>8}")
    print("-" * 96)
    for row in artifact["models"]:
        single = row["single"]
        tot = row["tot"]
        node_err = tot.get("node_error_count", 0)
        def f(x, fmt="{:.3f}"):
            return fmt.format(x) if isinstance(x, (int, float)) else "--"
        print(
            f"{row['model'][:28]:28} "
            f"{str(row.get('dataset') or '--')[:12]:12} "
            f"{f(single.get('accuracy')):>8} {f(tot.get('accuracy')):>8} "
            f"{f(row.get('accuracy_delta_tot_minus_single'), '{:+.3f}'):>8} "
            f"{f(row.get('mean_token_delta_tot_minus_single'), '{:+.1f}'):>9} "
            f"{f(row.get('mean_latency_delta_s_tot_minus_single'), '{:+.2f}'):>9} "
            f"{f(tot.get('mean_tokens_per_second'), '{:.1f}'):>9} "
            f"{node_err:>8}"
        )
        if single.get("first_error"):
            print(f"  single first_error: {single['first_error']}")
        if tot.get("first_error"):
            print(f"  ToT first_error: {tot['first_error']}")
    print("-" * 96)
    print("Accuracy excludes ungradable/error items per arm; nodeErr discloses ToT node status/error/score_error events.")


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
