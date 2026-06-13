"""Real-engine APC prefix-cache benchmark/report for chat-apc (#571).

This is an operator-gated benchmark, not a CI test. It boots the production
portable-Metal `pie serve` path, installs the committed chat-apc inferlet, and
measures the same continuation prompt in two modes:

* cold/miss: a fresh cache key, so the full history is prefilled.
* warm/hit: a previously seeded key, so the shared prefix snapshot is opened
  and only the new suffix is appended.

The harness writes a machine-readable JSON artifact and a concise Markdown
summary. Engine-free unit tests exercise the SSE/report parser; use the live
path only on a local/operator machine with a built engine and cached weights.

Usage:

    make bench-apc-real

    MODEL=Qwen/Qwen3-0.6B \
      uv run --project Vendor/pie/client/python --with httpx \
        python Inferlets/chat-apc/apc_bench_real.py \
          --output test-logs/apc-bench.json
"""
from __future__ import annotations

import argparse
import asyncio
import contextlib
import dataclasses
import datetime as _dt
import json
import os
import statistics
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path
from typing import Iterable, Iterator, Any

MODEL = os.environ.get("MODEL", "Qwen/Qwen3-0.6B")
DEFAULT_OUTPUT = Path(os.environ.get("APC_BENCH_OUTPUT", "test-logs/apc-bench-real.json"))
MAX_SAFE_PIE_HOME_BYTES = 72

_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))


@contextlib.contextmanager
def benchmark_tempdir() -> Iterator[Path]:
    """Create a temp root whose PIE_HOME fits Pie's real-driver aux socket budget.

    The portable/Metal driver binds
    ``$PIE_HOME/standalone/<pid>/g0/aux.sock`` and macOS caps Unix socket paths
    at 104 bytes including NUL. RatioThink's launcher reserves 31 bytes for the
    engine suffix, leaving 72 bytes for PIE_HOME. Python's default TMPDIR on
    macOS lives under /var/folders/... and can exceed that budget, so live
    benchmarks intentionally anchor their short-lived home at /tmp.
    """
    with tempfile.TemporaryDirectory(prefix="apcb-", dir="/tmp") as tmp_s:
        tmp = Path(tmp_s)
        pie_home = tmp / "home"
        if len(str(pie_home).encode("utf-8")) > MAX_SAFE_PIE_HOME_BYTES:
            raise RuntimeError(
                f"benchmark PIE_HOME path too long for pie aux socket budget: {pie_home}"
            )
        yield tmp


@dataclasses.dataclass(frozen=True)
class StreamSummary:
    content: str = ""
    output_tokens: int | None = None
    generation_elapsed_s: float | None = None
    tokens_per_sec: float | None = None
    cache_diag: dict[str, Any] | None = None
    finish_reason: str | None = None
    done: bool = False
    error_events: tuple[dict[str, Any], ...] = ()


@dataclasses.dataclass(frozen=True)
class TurnMeasurement:
    label: str
    status_code: int
    wall_time_s: float
    ttft_s: float | None
    content: str
    cache_diag: dict[str, Any] | None
    output_tokens: int | None
    tokens_per_sec: float | None
    kv_pages_before: int | None
    kv_pages_after: int | None
    rss_bytes_before: int | None
    rss_bytes_after: int | None
    generation_elapsed_s: float | None = None
    finish_reason: str | None = None
    errors: tuple[str, ...] = ()

    def to_json(self) -> dict[str, Any]:
        return dataclasses.asdict(self)


@dataclasses.dataclass(frozen=True)
class Scenario:
    name: str
    messages_turn1: list[dict[str, str]]
    continuation_user: str
    max_tokens: int
    temperature: float = 0.0
    top_p: float = 1.0

    def continuation_messages(self, assistant_turn1: str) -> list[dict[str, str]]:
        return [
            *self.messages_turn1,
            {"role": "assistant", "content": assistant_turn1},
            {"role": "user", "content": self.continuation_user},
        ]


def default_scenarios(max_tokens: int) -> list[Scenario]:
    def visible_answer(prompt: str) -> str:
        return f"{prompt} /no_think"

    long_system = (
        "You are helping triage a long agent transcript. Preserve factual details, "
        "answer concisely, and do not invent missing evidence. "
        + "The workspace contains chat, model, helper, and engine components. " * 35
    )
    long_user = (
        "Summarize the following investigation notes in three bullets and name the "
        "highest-risk follow-up: "
        + "APC saves a canonical prefix after each clean assistant turn; retention is "
          "host-owned; unknown KV accounting must not be guessed. " * 45
    )
    return [
        Scenario(
            name="short_qa",
            messages_turn1=[{
                "role": "user",
                "content": visible_answer(
                    "What is the capital of France? Answer in one short sentence."
                ),
            }],
            continuation_user=visible_answer("And what is its most famous landmark? One short sentence."),
            max_tokens=max_tokens,
        ),
        Scenario(
            name="long_agent_summary",
            messages_turn1=[
                {"role": "system", "content": long_system},
                {"role": "user", "content": visible_answer(long_user)},
            ],
            continuation_user=(
                visible_answer(
                    "Continue from that context: give the next concrete benchmark step and "
                    "state which measurement would prove prefix reuse helped."
                )
            ),
            max_tokens=max_tokens,
        ),
    ]


def parse_sse_frames(lines: Iterable[bytes | str]) -> Iterator[dict[str, Any]]:
    """Yield JSON objects from SSE data frames, plus {event:"done"} for [DONE]."""
    data_lines: list[str] = []
    for raw in lines:
        line = raw.decode("utf-8", errors="replace") if isinstance(raw, bytes) else raw
        line = line.rstrip("\r\n")
        if not line:
            if data_lines:
                payload = "\n".join(data_lines)
                data_lines.clear()
                if payload == "[DONE]":
                    yield {"event": "done"}
                else:
                    yield json.loads(payload)
            continue
        if line.startswith(":"):
            continue
        if line.startswith("data:"):
            data_lines.append(line[5:].lstrip())
    if data_lines:
        payload = "\n".join(data_lines)
        if payload == "[DONE]":
            yield {"event": "done"}
        else:
            yield json.loads(payload)


def summarize_stream_frames(frames: Iterable[dict[str, Any]]) -> StreamSummary:
    content_parts: list[str] = []
    output_tokens: int | None = None
    generation_elapsed_s: float | None = None
    tokens_per_sec: float | None = None
    cache_diag: dict[str, Any] | None = None
    finish_reason: str | None = None
    done = False
    error_events: list[dict[str, Any]] = []

    for frame in frames:
        event = frame.get("event")
        if event == "done":
            done = True
            continue
        if event == "cache":
            cache_diag = frame
            continue
        if event == "generation_metrics":
            output_tokens = _maybe_int(frame.get("output_tokens"))
            generation_elapsed_s = _maybe_float(frame.get("elapsed_s"))
            tokens_per_sec = _maybe_float(frame.get("tokens_per_sec"))
            continue
        if event == "error":
            error_events.append(frame)
            continue
        if frame.get("object") == "chat.completion.chunk":
            choices = frame.get("choices") or []
            if not choices:
                continue
            choice = choices[0]
            delta = choice.get("delta") or {}
            if delta.get("content"):
                content_parts.append(delta["content"])
            if choice.get("finish_reason") is not None:
                finish_reason = choice.get("finish_reason")

    return StreamSummary(
        content="".join(content_parts),
        output_tokens=output_tokens,
        generation_elapsed_s=generation_elapsed_s,
        tokens_per_sec=tokens_per_sec,
        cache_diag=cache_diag,
        finish_reason=finish_reason,
        done=done,
        error_events=tuple(error_events),
    )


def compare_pair(cold: TurnMeasurement, warm: TurnMeasurement) -> dict[str, Any]:
    cold_outcome = (cold.cache_diag or {}).get("outcome")
    warm_outcome = (warm.cache_diag or {}).get("outcome")
    return {
        "cold_outcome": cold_outcome,
        "warm_outcome": warm_outcome,
        "ttft_saved_s": _delta(cold.ttft_s, warm.ttft_s),
        "wall_saved_s": _delta(cold.wall_time_s, warm.wall_time_s),
        "ttft_speedup": _ratio(cold.ttft_s, warm.ttft_s),
        "wall_speedup": _ratio(cold.wall_time_s, warm.wall_time_s),
        "cold_kv_pages_delta": _delta(cold.kv_pages_after, cold.kv_pages_before),
        "warm_kv_pages_delta": _delta(warm.kv_pages_after, warm.kv_pages_before),
        "cold_rss_bytes_delta": _delta(cold.rss_bytes_after, cold.rss_bytes_before),
        "warm_rss_bytes_delta": _delta(warm.rss_bytes_after, warm.rss_bytes_before),
        "warm_reused_prefix_tokens": (warm.cache_diag or {}).get("base_boundary"),
        "warm_appended_tokens": (warm.cache_diag or {}).get("appended"),
        "cold_appended_tokens": (cold.cache_diag or {}).get("appended"),
        "cold_output_tokens": cold.output_tokens,
        "warm_output_tokens": warm.output_tokens,
        "cold_tokens_per_sec": cold.tokens_per_sec,
        "warm_tokens_per_sec": warm.tokens_per_sec,
    }


def render_markdown_summary(artifact: dict[str, Any]) -> str:
    status = "PASS" if artifact.get("correctness", {}).get("passed") else "FAIL"
    lines = [
        f"# APC real-continuation benchmark — {status}",
        "",
        f"- Model: `{artifact.get('model')}`",
        f"- Created: `{artifact.get('created_at')}`",
        f"- JSON artifact: `{artifact.get('output_path')}`",
        "",
        "| Scenario | cold | warm | TTFT saved | Wall saved | Reused prefix tokens |",
        "| --- | --- | --- | ---: | ---: | ---: |",
    ]
    for c in artifact.get("comparisons", []):
        lines.append(
            "| {scenario} | {cold} | {warm} | {ttft:.3f}s | {wall:.3f}s | {prefix} |".format(
                scenario=c.get("scenario"),
                cold=c.get("cold_outcome"),
                warm=c.get("warm_outcome"),
                ttft=_num(c.get("ttft_saved_s")),
                wall=_num(c.get("wall_saved_s")),
                prefix=c.get("warm_reused_prefix_tokens"),
            )
        )
    failures = artifact.get("correctness", {}).get("failures") or []
    if failures:
        lines.extend(["", "## Correctness failures"])
        lines.extend(f"- {f}" for f in failures)
    lines.append("")
    return "\n".join(lines)


def _maybe_int(value: Any) -> int | None:
    try:
        return None if value is None else int(value)
    except (TypeError, ValueError):
        return None


def _maybe_float(value: Any) -> float | None:
    try:
        return None if value is None else float(value)
    except (TypeError, ValueError):
        return None


def _delta(a: int | float | None, b: int | float | None) -> int | float | None:
    if a is None or b is None:
        return None
    return a - b


def _ratio(a: int | float | None, b: int | float | None) -> float | None:
    if a is None or b in (None, 0):
        return None
    return float(a) / float(b)


def _num(value: Any) -> float:
    return 0.0 if value is None else float(value)


def _now_iso() -> str:
    return _dt.datetime.now(_dt.UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _process_rss_bytes(pid: int | None) -> int | None:
    if not pid:
        return None
    try:
        out = subprocess.check_output(["ps", "-o", "rss=", "-p", str(pid)], text=True)
        rss_kb = int(out.strip().splitlines()[-1])
        return rss_kb * 1024
    except Exception:
        return None


def _kv_pages_for_model(status: dict[str, Any] | None, model: str) -> tuple[int | None, int | None]:
    if not status:
        return None, None
    return _maybe_int(status.get(f"{model}.kv_pages_used")), _maybe_int(status.get(f"{model}.kv_pages_total"))


async def _query_model_status(client) -> dict[str, Any] | None:
    try:
        ok, result = await client.query("model_status", "")
        if not ok:
            return None
        return json.loads(result)
    except Exception:
        return None


def _directive(key: str, turn: int, policy: str = "auto", retention: dict[str, Any] | None = None) -> dict[str, Any]:
    out: dict[str, Any] = {"key": key, "turn": turn, "compat": "bench-v1", "policy": policy}
    if retention is not None:
        out["retention"] = retention
    return out


async def _stream_turn(http_c, base: str, client, *, model: str, engine_pid: int | None,
                       label: str, messages: list[dict[str, str]], cache: dict[str, Any],
                       max_tokens: int, temperature: float, top_p: float) -> TurnMeasurement:
    status_before = await _query_model_status(client)
    kv_before, _ = _kv_pages_for_model(status_before, model)
    rss_before = _process_rss_bytes(engine_pid)
    frames: list[dict[str, Any]] = []
    errors: list[str] = []
    first_content_at: float | None = None
    start = time.perf_counter()
    status_code = 0
    text_prefix = ""

    body = {
        "model": model,
        "messages": messages,
        "stream": True,
        "temperature": temperature,
        "top_p": top_p,
        "max_tokens": max_tokens,
        "cache": cache,
    }
    try:
        async with http_c.stream("POST", f"{base}/v1/chat/completions", json=body) as resp:
            status_code = resp.status_code
            if status_code != 200:
                text_prefix = (await resp.aread()).decode("utf-8", errors="replace")[:500]
            else:
                data_lines: list[str] = []
                async for raw_line in resp.aiter_lines():
                    line = raw_line.rstrip("\r\n")
                    if not line:
                        if not data_lines:
                            continue
                        payload = "\n".join(data_lines)
                        data_lines.clear()
                        if payload == "[DONE]":
                            frame = {"event": "done"}
                        else:
                            frame = json.loads(payload)
                        frames.append(frame)
                        if first_content_at is None and _frame_has_content(frame):
                            first_content_at = time.perf_counter()
                        continue
                    if line.startswith("data:"):
                        data_lines.append(line[5:].lstrip())
    except Exception as exc:  # keep benchmark artifact, mark correctness failed later
        errors.append(f"{label}: stream exception: {exc}")

    wall = time.perf_counter() - start
    status_after = await _query_model_status(client)
    kv_after, _ = _kv_pages_for_model(status_after, model)
    rss_after = _process_rss_bytes(engine_pid)
    summary = summarize_stream_frames(frames)
    if status_code != 200 and text_prefix:
        errors.append(f"{label}: HTTP {status_code}: {text_prefix!r}")
    for event in summary.error_events:
        errors.append(f"{label}: SSE error event: {event}")
    if status_code == 200 and not summary.done:
        errors.append(f"{label}: stream ended without [DONE]")

    return TurnMeasurement(
        label=label,
        status_code=status_code,
        wall_time_s=wall,
        ttft_s=(first_content_at - start) if first_content_at is not None else None,
        content=summary.content,
        cache_diag=summary.cache_diag,
        output_tokens=summary.output_tokens,
        tokens_per_sec=summary.tokens_per_sec,
        kv_pages_before=kv_before,
        kv_pages_after=kv_after,
        rss_bytes_before=rss_before,
        rss_bytes_after=rss_after,
        generation_elapsed_s=summary.generation_elapsed_s,
        finish_reason=summary.finish_reason,
        errors=tuple(errors),
    )


def _frame_has_content(frame: dict[str, Any]) -> bool:
    if frame.get("object") != "chat.completion.chunk":
        return False
    choices = frame.get("choices") or []
    if not choices:
        return False
    return bool((choices[0].get("delta") or {}).get("content"))


async def _nonstream_seed(http_c, base: str, *, model: str, key: str, messages: list[dict[str, str]],
                          max_tokens: int, temperature: float, top_p: float) -> tuple[str, dict[str, Any] | None, str | None]:
    body = {
        "model": model,
        "messages": messages,
        "stream": False,
        "temperature": temperature,
        "top_p": top_p,
        "max_tokens": max_tokens,
        "cache": _directive(key, len(messages)),
    }
    resp = await http_c.post(f"{base}/v1/chat/completions", json=body)
    raw_diag = resp.headers.get("X-ChatAPC-Cache")
    diag = json.loads(raw_diag) if raw_diag else None
    if resp.status_code != 200:
        return "", diag, f"seed HTTP {resp.status_code}: {resp.text[:500]!r}"
    content = resp.json()["choices"][0]["message"].get("content") or ""
    return content, diag, None


async def run_live(args: argparse.Namespace) -> dict[str, Any]:
    import httpx
    from pie_client import PieClient
    import e2e_test as E

    assert E.PIE_BIN.exists(), f"missing pie binary at {E.PIE_BIN}; run make engine-build"
    assert E.WASM_PATH.exists(), f"missing wasm at {E.WASM_PATH}; run make build-inferlets"
    E.verify_stamp()

    config_toml = f"""
[server]
host = "127.0.0.1"
port = 0

[auth]
enabled = false

[telemetry]
enabled = false

[runtime]
allow_fs = false
allow_network = true

[[model]]
name = "{args.model}"
hf_repo = "{args.model}"

[model.scheduler]
batch_policy = "adaptive"
request_timeout_secs = 120
default_endowment_pages = 4
admission_oversubscription_factor = 8.0
restore_pause_at_utilization = 0.85

[model.driver]
type = "portable"
device = ["metal"]
"""
    failures: list[str] = []
    scenario_reports: list[dict[str, Any]] = []
    comparisons: list[dict[str, Any]] = []
    runs = max(1, args.runs)

    with benchmark_tempdir() as tmp:
        cfg = tmp / "config.toml"
        cfg.write_text(config_toml)
        pie_home = tmp / "home"
        pie_home.mkdir()
        env = {**os.environ, "PIE_HOME": str(pie_home), "PIE_SHMEM_NAME": f"/apc_bench_{os.getpid()}"}
        proc = subprocess.Popen(
            [str(E.PIE_BIN), "serve", "--config", str(cfg), "--no-auth", "--debug"],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            env=env,
            bufsize=1,
        )
        try:
            ws_addr, token = await E._parse_handshake(proc, timeout=args.handshake_timeout)
            print(f"[apc-bench] engine ws=ws://{ws_addr}")
            drain = asyncio.create_task(E._drain_stdout(proc))
            try:
                client = PieClient(f"ws://{ws_addr}")
                await client.connect()
                await client.auth_by_token(token)
                await client.install_program(E.WASM_PATH, E.MANIFEST_PATH, force_overwrite=True)
                port = E._free_port()
                base = f"http://127.0.0.1:{port}"
                await client.launch_daemon("chat-apc@0.1.0", port)
                if not E._wait_for_port(port, timeout=30):
                    raise RuntimeError(f"daemon never bound port {port}")
                print(f"[apc-bench] daemon={base} model={args.model}")

                timeout = httpx.Timeout(args.request_timeout)
                async with httpx.AsyncClient(timeout=timeout) as http_c:
                    for scenario in default_scenarios(args.max_tokens):
                        run_pairs: list[dict[str, Any]] = []
                        for i in range(runs):
                            warm_key = str(uuid.uuid4())
                            cold_key = str(uuid.uuid4())
                            assistant1, seed_diag, seed_error = await _nonstream_seed(
                                http_c,
                                base,
                                model=args.model,
                                key=warm_key,
                                messages=scenario.messages_turn1,
                                max_tokens=args.seed_max_tokens,
                                temperature=scenario.temperature,
                                top_p=scenario.top_p,
                            )
                            if seed_error:
                                failures.append(f"{scenario.name}[{i}] {seed_error}")
                                continue
                            if not assistant1.strip():
                                failures.append(f"{scenario.name}[{i}] seed produced empty assistant text")
                                continue
                            hist2 = scenario.continuation_messages(assistant1)
                            cold = await _stream_turn(
                                http_c,
                                base,
                                client,
                                model=args.model,
                                engine_pid=proc.pid,
                                label=f"{scenario.name}[{i}].cold_miss",
                                messages=hist2,
                                cache=_directive(cold_key, len(hist2)),
                                max_tokens=scenario.max_tokens,
                                temperature=scenario.temperature,
                                top_p=scenario.top_p,
                            )
                            warm = await _stream_turn(
                                http_c,
                                base,
                                client,
                                model=args.model,
                                engine_pid=proc.pid,
                                label=f"{scenario.name}[{i}].warm_hit",
                                messages=hist2,
                                cache=_directive(warm_key, len(hist2)),
                                max_tokens=scenario.max_tokens,
                                temperature=scenario.temperature,
                                top_p=scenario.top_p,
                            )
                            pair = {
                                "run": i + 1,
                                "seed_diag": seed_diag,
                                "cold": cold.to_json(),
                                "warm": warm.to_json(),
                                "comparison": compare_pair(cold, warm),
                            }
                            _validate_pair(scenario.name, i, cold, warm, failures)
                            run_pairs.append(pair)
                        scenario_reports.append({"name": scenario.name, "runs": run_pairs})
                        comparisons.append(_aggregate_comparisons(scenario.name, run_pairs))
            finally:
                drain.cancel()
                with contextlib.suppress(Exception):
                    await client.close()
        finally:
            E._terminate_subprocess(proc, "apc-bench-engine")
            E._shm_unlink_quiet(f"/apc_bench_{os.getpid()}_g0")

    artifact = {
        "schema_version": 1,
        "created_at": _now_iso(),
        "model": args.model,
        "runs_per_scenario": runs,
        "max_tokens": args.max_tokens,
        "seed_max_tokens": args.seed_max_tokens,
        "scenarios": scenario_reports,
        "comparisons": comparisons,
        "correctness": {"passed": not failures, "failures": failures},
    }
    return artifact


def _validate_pair(scenario: str, idx: int, cold: TurnMeasurement, warm: TurnMeasurement,
                   failures: list[str]) -> None:
    prefix = f"{scenario}[{idx}]"
    if cold.errors:
        failures.extend(cold.errors)
    if warm.errors:
        failures.extend(warm.errors)
    if cold.status_code != 200:
        failures.append(f"{prefix} cold status {cold.status_code}")
    if warm.status_code != 200:
        failures.append(f"{prefix} warm status {warm.status_code}")
    if not cold.cache_diag:
        failures.append(f"{prefix} cold missing cache diag")
    elif cold.cache_diag.get("outcome") != "miss":
        failures.append(f"{prefix} cold outcome={cold.cache_diag.get('outcome')!r}, want miss")
    if not warm.cache_diag:
        failures.append(f"{prefix} warm missing cache diag")
    elif warm.cache_diag.get("outcome") != "hit":
        failures.append(f"{prefix} warm outcome={warm.cache_diag.get('outcome')!r}, want hit")
    elif (warm.cache_diag.get("base_boundary") or 0) <= 0:
        failures.append(f"{prefix} warm hit reused no prefix tokens: {warm.cache_diag!r}")


def _aggregate_comparisons(scenario: str, run_pairs: list[dict[str, Any]]) -> dict[str, Any]:
    comps = [p["comparison"] for p in run_pairs]
    if not comps:
        return {"scenario": scenario, "runs": 0}
    out: dict[str, Any] = {
        "scenario": scenario,
        "runs": len(comps),
        "cold_outcome": _mode([c.get("cold_outcome") for c in comps]),
        "warm_outcome": _mode([c.get("warm_outcome") for c in comps]),
    }
    for key in [
        "ttft_saved_s", "wall_saved_s", "ttft_speedup", "wall_speedup",
        "cold_kv_pages_delta", "warm_kv_pages_delta", "cold_rss_bytes_delta",
        "warm_rss_bytes_delta", "warm_reused_prefix_tokens", "warm_appended_tokens",
        "cold_appended_tokens", "cold_output_tokens", "warm_output_tokens",
        "cold_tokens_per_sec", "warm_tokens_per_sec",
    ]:
        vals = [c.get(key) for c in comps if c.get(key) is not None]
        out[key] = statistics.mean(vals) if vals else None
    return out


def _mode(values: list[Any]) -> Any:
    values = [v for v in values if v is not None]
    if not values:
        return None
    return max(set(values), key=values.count)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Benchmark APC prefix-cache real continuation performance")
    p.add_argument("--model", default=MODEL)
    p.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    p.add_argument("--runs", type=int, default=int(os.environ.get("APC_BENCH_RUNS", "1")))
    p.add_argument("--max-tokens", type=int, default=int(os.environ.get("APC_BENCH_MAX_TOKENS", "96")))
    p.add_argument("--seed-max-tokens", type=int, default=int(os.environ.get("APC_BENCH_SEED_MAX_TOKENS", "96")))
    p.add_argument("--request-timeout", type=float, default=float(os.environ.get("APC_BENCH_REQUEST_TIMEOUT", "300")))
    p.add_argument("--handshake-timeout", type=float, default=float(os.environ.get("APC_BENCH_HANDSHAKE_TIMEOUT", "180")))
    p.add_argument("--summary", type=Path, default=None, help="Markdown summary path (default: <output>.md)")
    return p.parse_args(argv)


async def _amain(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    artifact = await run_live(args)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    artifact["output_path"] = str(args.output)
    args.output.write_text(json.dumps(artifact, indent=2, sort_keys=True) + "\n")
    summary_path = args.summary or args.output.with_suffix(".md")
    summary_path.write_text(render_markdown_summary(artifact))
    print(render_markdown_summary(artifact))
    print(f"[apc-bench] wrote {args.output}")
    print(f"[apc-bench] wrote {summary_path}")
    return 0 if artifact["correctness"]["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(asyncio.run(_amain()))
