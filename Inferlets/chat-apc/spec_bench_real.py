"""Real-model Fast Think (speculative decoding) measurement harness (#510).

Where `spec_smoke_real.py` PROVES Fast Think is *correct* (greedy
token-equivalence + at least one accepted draft), this harness *quantifies*
whether it helps and why. It boots `pie serve` with the production
**portable Metal** driver against a real cached model and, for each
scenario, streams the SAME greedy (temperature=0) chat under two profiles:

  * baseline   — `speculation:{enabled:false}` (drafting OFF, but the
                 `spec_metrics` surface is still emitted so we read the
                 engine-measured decode throughput); and
  * fast_think — `speculation:{enabled:true}` (linear Cacheback drafter).

Sending `enabled:false` for the baseline (rather than omitting the block)
is what makes the comparison apples-to-apples: both runs surface
`generated_tokens`, `decode_steps`, and `decode_tokens_per_sec` measured
by the same transport loop, so the only difference is whether drafting
engaged. No production decode behavior is changed — the metrics surface
already exists (#418).

Measured per run:

  Latency (client, via SSE)
    * model_ready_s   — request start -> `model_ready` frame (queue+prefill)
    * ttft_s          — request start -> first content/reasoning delta
    * wall_s          — request start -> `[DONE]`
    * client_decode_tok_per_s — generated_tokens / (wall - ttft)

  Speculation (engine, terminal `spec_metrics` frame)
    * enabled / fallback_reason   (engaged vs why-not)
    * generated_tokens, decode_steps
    * proposed / accepted / rejected draft tokens
    * accepted_ratio = accepted / proposed
    * avg_tokens_per_step (draft-chain effectiveness)
    * decode_tokens_per_sec (engine-measured, decode phase only)

Quality gate (greedy): the harness RECORDS whether fast_think output is
byte-identical to plain (the equivalence the short-window smoke asserts).
Crucially it first runs a BASELINE DETERMINISM CONTROL (two independent
plain runs) so a recorded drift can be attributed correctly:

  * equivalence "held"           — fast_think == baseline (byte-identical).
  * equivalence "drift_spec"     — baseline is deterministic (run A == run
                                   B) but fast_think diverges. The drift is
                                   then SPECULATION-ATTRIBUTABLE and
                                   deterministic — on the portable Metal
                                   backend the batched-verify forward
                                   (`kernel_mul_mm`) rounds differently from
                                   single-token decode (`kernel_mul_mv`),
                                   flipping argmax at a near-tie. This is a
                                   recorded finding, NOT a harness failure
                                   (the ticket: "otherwise record output
                                   drift").
  * equivalence "baseline_nondeterministic" — plain run A != run B; the
                                   comparison is invalid → MEASUREMENT
                                   FAILURE.

Speculation status per fast_think run is classified into:
  * fallback:<reason>        — drafting never engaged (e.g. tool forced)
  * engaged_zero_acceptance  — drafting ran but accepted 0 drafts
  * engaged                  — drafting ran and accepted >0 drafts

Outputs a machine-readable JSON artifact (`$BENCH_OUT`, default
`spec_bench_<model-slug>.json`) and a concise human summary to stdout.

Exit code is NONZERO only for measurement/contract failures (non-200,
missing/inconsistent metrics, baseline nondeterminism, or a greedy
non-tool fast_think run that silently fell back to plain). Recorded
greedy drift and a small/negative speedup do NOT fail the harness.

Requires: built `Vendor/pie/target/release/pie` (Metal portable, via
`make engine-build`), the prebuilt chat-apc wasm + stamp, and a real model
WITH WEIGHTS in `~/.cache/huggingface/hub`.

Usage::

    MODEL=Qwen/Qwen3-0.6B MAX_TOKENS=256 \
      uv run --project Vendor/pie/client/python --with httpx \
        python Inferlets/chat-apc/spec_bench_real.py
"""
from __future__ import annotations

import asyncio
import json
import os
import subprocess
import tempfile
import time
from pathlib import Path

import httpx
from pie_client import PieClient

import e2e_test as h  # boot/teardown helpers + PIE_BIN/WASM_PATH/MANIFEST_PATH

MODEL = os.environ.get("MODEL", "Qwen/Qwen3-0.6B")
MAX_TOKENS = int(os.environ.get("MAX_TOKENS", "256"))
REPS = int(os.environ.get("REPS", "1"))
BENCH_OUT = os.environ.get(
    "BENCH_OUT", f"spec_bench_{MODEL.replace('/', '__')}.json"
)

# Representative greedy scenarios. Kept small to bound real-model runtime;
# each is a self-contained prompt that produces a deterministic continuation
# at temperature=0 so the equivalence contract is meaningful.
SCENARIOS = [
    {
        "id": "primes",
        "prompt": "List the first eight prime numbers, comma separated.",
    },
    {
        "id": "repeat",
        "prompt": (
            "Repeat the following sentence exactly three times on separate "
            "lines: The quick brown fox jumps over the lazy dog."
        ),
    },
    {
        "id": "explain",
        "prompt": "In two sentences, explain what a hash map is.",
    },
]

CONFIG_TOML = f"""
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
name = "{MODEL}"
hf_repo = "{MODEL}"

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

# Speculation block per profile. The baseline sends enabled:false ON
# PURPOSE — that keeps `want_metrics` true so the engine emits decode
# throughput for a non-speculative run, giving a like-for-like comparison.
PROFILES = {
    "baseline": {"enabled": False},
    "fast_think": {"enabled": True},
}


async def _stream_run(
    http_c: httpx.AsyncClient, base: str, prompt: str, spec: dict
) -> dict:
    """Stream one greedy chat completion, measuring client latency and
    capturing the terminal `spec_metrics` frame. Returns a per-run record."""
    body = {
        "model": MODEL,
        "messages": [{"role": "user", "content": prompt}],
        "temperature": 0,
        "max_tokens": MAX_TOKENS,
        "stream": True,
        "speculation": spec,
    }
    content_parts: list[str] = []
    reasoning_parts: list[str] = []
    spec_metrics: dict | None = None
    error_frame: dict | None = None
    status = None

    t0 = time.perf_counter()
    model_ready_s: float | None = None
    ttft_s: float | None = None

    async with http_c.stream("POST", f"{base}/v1/chat/completions", json=body) as resp:
        status = resp.status_code
        if status != 200:
            text = (await resp.aread()).decode("utf-8", "replace")
            return {
                "status": status,
                "error_body": text[:400],
            }
        async for line in resp.aiter_lines():
            if not line.startswith("data: "):
                continue
            payload = line[len("data: "):]
            if payload == "[DONE]":
                break
            try:
                frame = json.loads(payload)
            except json.JSONDecodeError:
                continue
            event = frame.get("event")
            if event == "model_ready":
                model_ready_s = time.perf_counter() - t0
                continue
            if event == "spec_metrics":
                spec_metrics = frame
                continue
            if event == "error":
                error_frame = frame
                continue
            # OpenAI chunk: choices[0].delta.{content,reasoning_content}
            choices = frame.get("choices") or []
            if not choices:
                continue
            delta = choices[0].get("delta") or {}
            c = delta.get("content")
            r = delta.get("reasoning_content")
            if c:
                if ttft_s is None:
                    ttft_s = time.perf_counter() - t0
                content_parts.append(c)
            if r:
                if ttft_s is None:
                    ttft_s = time.perf_counter() - t0
                reasoning_parts.append(r)

    wall_s = time.perf_counter() - t0
    content = "".join(content_parts)
    reasoning = "".join(reasoning_parts)

    record: dict = {
        "status": status,
        "content": content,
        "reasoning": reasoning,
        "model_ready_s": model_ready_s,
        "ttft_s": ttft_s,
        "wall_s": wall_s,
        "spec_metrics": spec_metrics,
        "error_frame": error_frame,
    }
    # Client-side decode throughput over the post-TTFT window, using the
    # engine's own generated-token count when available.
    gen = (spec_metrics or {}).get("generated_tokens")
    if gen and ttft_s is not None and wall_s > ttft_s:
        record["client_decode_tok_per_s"] = gen / (wall_s - ttft_s)
    else:
        record["client_decode_tok_per_s"] = None
    return record


def _log_run(prof: str, rep: int, rec: dict) -> None:
    sm = rec.get("spec_metrics") or {}
    print(
        f"  [{prof}] rep={rep} status={rec.get('status')} "
        f"ttft={rec.get('ttft_s')} wall={rec.get('wall_s')} "
        f"tok/s(engine)={sm.get('decode_tokens_per_sec')} "
        f"acc={sm.get('accepted_draft_tokens')}/{sm.get('proposed_draft_tokens')}"
    )


def _classify(fast: dict) -> str:
    sm = fast.get("spec_metrics") or {}
    if not sm.get("enabled", False):
        return f"fallback:{sm.get('fallback_reason') or 'unknown'}"
    if sm.get("accepted_draft_tokens", 0) <= 0:
        return "engaged_zero_acceptance"
    return "engaged"


def _check_run(label: str, scenario_id: str, rec: dict, failures: list[str]) -> bool:
    """Contract checks common to every run. Returns True if metrics usable."""
    if rec.get("status") != 200:
        failures.append(
            f"[{scenario_id}/{label}] non-200 status={rec.get('status')} "
            f"body={rec.get('error_body')!r}"
        )
        return False
    sm = rec.get("spec_metrics")
    if sm is None:
        failures.append(f"[{scenario_id}/{label}] spec_metrics missing")
        return False
    proposed = sm.get("proposed_draft_tokens", 0)
    accepted = sm.get("accepted_draft_tokens", 0)
    rejected = sm.get("rejected_draft_tokens", 0)
    if accepted + rejected != proposed:
        failures.append(
            f"[{scenario_id}/{label}] draft accounting inconsistent: "
            f"accepted={accepted} rejected={rejected} proposed={proposed}"
        )
    return True


def _agg(records: list[dict], key: str):
    vals = [r[key] for r in records if r.get(key) is not None]
    return min(vals) if vals else None


def _median(records: list[dict], key: str):
    vals = sorted(r[key] for r in records if r.get(key) is not None)
    if not vals:
        return None
    n = len(vals)
    return vals[n // 2] if n % 2 else (vals[n // 2 - 1] + vals[n // 2]) / 2


async def _bench(base: str) -> tuple[dict, list[str]]:
    failures: list[str] = []
    scenario_reports = []

    async with httpx.AsyncClient(timeout=300) as http_c:
        for sc in SCENARIOS:
            sid, prompt = sc["id"], sc["prompt"]
            print(f"\n[bench] scenario={sid!r} prompt={prompt!r}")
            # Baseline gets >=2 runs so we always have a determinism
            # control (run A vs run B), independent of REPS. fast_think
            # repeats REPS times for timing stability.
            base_reps = max(2, REPS)
            base_runs: list[dict] = []
            fast_runs: list[dict] = []
            for rep in range(base_reps):
                rec = await _stream_run(http_c, base, prompt, PROFILES["baseline"])
                base_runs.append(rec)
                _log_run("baseline", rep, rec)
            for rep in range(REPS):
                rec = await _stream_run(http_c, base, prompt, PROFILES["fast_think"])
                fast_runs.append(rec)
                _log_run("fast_think", rep, rec)

            # Contract checks on every run.
            for rec in base_runs:
                _check_run("baseline", sid, rec, failures)
            for rec in fast_runs:
                _check_run("fast_think", sid, rec, failures)

            ok_base = [r for r in base_runs if r.get("status") == 200]
            ok_fast = [r for r in fast_runs if r.get("status") == 200]

            def _out(r: dict) -> tuple[str, str]:
                return (r["content"], r["reasoning"])

            # Determinism control: are the baseline plain runs identical?
            baseline_deterministic = (
                len(ok_base) >= 2
                and all(_out(r) == _out(ok_base[0]) for r in ok_base[1:])
            )

            # Greedy equivalence + drift attribution.
            equivalence = "no_successful_run"
            drift = None
            if ok_base and ok_fast:
                b, f = ok_base[0], ok_fast[0]
                if _out(b) == _out(f):
                    equivalence = "held"
                elif not baseline_deterministic:
                    equivalence = "baseline_nondeterministic"
                    failures.append(
                        f"[{sid}] baseline plain decode is NON-DETERMINISTIC "
                        f"(run A != run B); spec/plain comparison is invalid"
                    )
                else:
                    # Deterministic, speculation-attributable drift —
                    # recorded, NOT a failure.
                    equivalence = "drift_spec"
                    bc, fc = b["content"], f["content"]
                    br, fr = b["reasoning"], f["reasoning"]
                    n = min(len(br), len(fr))
                    off = next((k for k in range(n) if br[k] != fr[k]), n)
                    drift = {
                        "first_reasoning_divergence_char": off,
                        "baseline": {"content": bc[:300], "reasoning": br[:300]},
                        "fast_think": {"content": fc[:300], "reasoning": fr[:300]},
                    }

            status = _classify(ok_fast[0]) if ok_fast else "no_successful_run"
            # A greedy, non-tool fast_think run that silently fell back to
            # plain is a contract failure — speculation should engage.
            if status.startswith("fallback:"):
                failures.append(
                    f"[{sid}] fast_think greedy run did not engage speculation "
                    f"(status={status}); expected drafting to run"
                )

            # Advisory speedup (engine decode tok/s + wall, best-of-reps).
            base_tps = _median(
                [r["spec_metrics"] for r in ok_base if r.get("spec_metrics")],
                "decode_tokens_per_sec",
            )
            fast_tps = _median(
                [r["spec_metrics"] for r in ok_fast if r.get("spec_metrics")],
                "decode_tokens_per_sec",
            )
            base_wall = _agg(ok_base, "wall_s")
            fast_wall = _agg(ok_fast, "wall_s")
            speedup_tps = (fast_tps / base_tps) if (base_tps and fast_tps) else None
            speedup_wall = (base_wall / fast_wall) if (base_wall and fast_wall) else None

            fsm = (ok_fast[0].get("spec_metrics") if ok_fast else None) or {}
            proposed = fsm.get("proposed_draft_tokens", 0)
            accepted = fsm.get("accepted_draft_tokens", 0)
            scenario_reports.append({
                "scenario": sid,
                "prompt": prompt,
                "speculation_status": status,
                "greedy_equivalence": equivalence,
                "baseline_deterministic": baseline_deterministic,
                "output_drift": drift,
                "speculation": {
                    "proposed_draft_tokens": proposed,
                    "accepted_draft_tokens": accepted,
                    "rejected_draft_tokens": fsm.get("rejected_draft_tokens", 0),
                    "accepted_ratio": (accepted / proposed) if proposed else 0.0,
                    "avg_tokens_per_step": fsm.get("avg_tokens_per_step"),
                    "decode_steps": fsm.get("decode_steps"),
                    "generated_tokens": fsm.get("generated_tokens"),
                    "leader_len": fsm.get("leader_len"),
                    "draft_len": fsm.get("draft_len"),
                    # #591: attribute a low accepted_ratio — distinguishes a
                    # cold cache (drafter rarely proposes) from bad followers
                    # (proposes but gets rejected), and shows the chain-length
                    # spread behind avg_tokens_per_step.
                    "cache_hits": fsm.get("cache_hits"),
                    "cache_misses": fsm.get("cache_misses"),
                    "cache_hit_rate": fsm.get("cache_hit_rate"),
                    "cache_size": fsm.get("cache_size"),
                    "accepted_prefix_len_histogram": fsm.get(
                        "accepted_prefix_len_histogram"
                    ),
                },
                "latency": {
                    "baseline": {
                        "ttft_s": _agg(ok_base, "ttft_s"),
                        "wall_s": base_wall,
                        "engine_decode_tok_per_s": base_tps,
                        "model_ready_s": _agg(ok_base, "model_ready_s"),
                    },
                    "fast_think": {
                        "ttft_s": _agg(ok_fast, "ttft_s"),
                        "wall_s": fast_wall,
                        "engine_decode_tok_per_s": fast_tps,
                        "model_ready_s": _agg(ok_fast, "model_ready_s"),
                    },
                },
                "advisory_speedup": {
                    "decode_tok_per_s_ratio": speedup_tps,
                    "wall_ratio": speedup_wall,
                },
                "runs": {"baseline": base_runs, "fast_think": fast_runs},
            })

    artifact = {
        "model": MODEL,
        "driver": "portable/metal",
        "decode_settings": {
            "temperature": 0,
            "max_tokens": MAX_TOKENS,
            "reps": REPS,
        },
        "scenarios": scenario_reports,
    }
    return artifact, failures


def _cache_cell(spc: dict, key: str) -> str:
    """Format one n-gram-cache metric cell for the summary.

    Distinguishes a DROPPED/renamed wire field from a genuinely cold turn:
      * key absent from the dict          -> 'MISSING' (the field never
        arrived — a wire-contract regression to investigate);
      * key present but empty/non-numeric -> '--'      (a real zero-lookup
        or empty-histogram turn).
    Otherwise renders the value: 2-dp for the hit-rate float, comma-joined
    for the histogram, plain int for the counters.
    """
    if key not in spc:
        return "MISSING"
    val = spc[key]
    if key == "cache_hit_rate":
        return f"{val:.2f}" if isinstance(val, (int, float)) else "--"
    if key == "accepted_prefix_len_histogram":
        if isinstance(val, (list, tuple)) and val:
            return ",".join(str(x) for x in val)
        return "--"
    # Integer counters: cache_hits, cache_misses, cache_size. 0 is a valid
    # value (renders "0"), only a non-numeric/None present value is '--'.
    return str(val) if isinstance(val, (int, float)) else "--"


def _print_summary(artifact: dict) -> None:
    print("\n" + "=" * 72)
    print(f"Fast Think measurement — {artifact['model']} ({artifact['driver']})")
    print(f"max_tokens={artifact['decode_settings']['max_tokens']} "
          f"reps={artifact['decode_settings']['reps']}")
    print("=" * 72)
    hdr = (
        f"{'scenario':<10} {'spec status':<20} {'acc/prop':>10} "
        f"{'ratio':>6} {'avg/step':>9} {'tok/s base':>11} {'tok/s fast':>11} "
        f"{'speedup':>8} {'equivalence':>14}"
    )
    print(hdr)
    print("-" * len(hdr))
    for s in artifact["scenarios"]:
        spc = s["speculation"]
        lat = s["latency"]
        adv = s["advisory_speedup"]
        acc_prop = f"{spc['accepted_draft_tokens']}/{spc['proposed_draft_tokens']}"
        ratio = f"{spc['accepted_ratio']:.2f}"
        avg = spc["avg_tokens_per_step"]
        avg_s = f"{avg:.2f}" if isinstance(avg, (int, float)) else "--"
        bt = lat["baseline"]["engine_decode_tok_per_s"]
        ft = lat["fast_think"]["engine_decode_tok_per_s"]
        bt_s = f"{bt:.1f}" if isinstance(bt, (int, float)) else "--"
        ft_s = f"{ft:.1f}" if isinstance(ft, (int, float)) else "--"
        su = adv["decode_tok_per_s_ratio"]
        su_s = f"{su:.2f}x" if isinstance(su, (int, float)) else "--"
        eq = s["greedy_equivalence"]
        print(
            f"{s['scenario']:<10} {s['speculation_status']:<20} {acc_prop:>10} "
            f"{ratio:>6} {avg_s:>9} {bt_s:>11} {ft_s:>11} {su_s:>8} {eq:>14}"
        )
    print("-" * len(hdr))
    print("speedup = fast_think engine decode tok/s ÷ baseline (ADVISORY; "
          "not a pass/fail criterion).")

    # #591: cache effectiveness + chain-length spread, the signal that
    # attributes a low accepted_ratio (cold cache vs bad followers).
    print("\nn-gram cache (fast_think):")
    cache_hdr = (
        f"{'scenario':<10} {'hits':>7} {'misses':>7} {'hit_rate':>9} "
        f"{'cache_sz':>9} {'accepted-prefix-len histogram':>32}"
    )
    print(cache_hdr)
    print("-" * len(cache_hdr))
    for s in artifact["scenarios"]:
        spc = s["speculation"]
        print(
            f"{s['scenario']:<10} {_cache_cell(spc, 'cache_hits'):>7} "
            f"{_cache_cell(spc, 'cache_misses'):>7} "
            f"{_cache_cell(spc, 'cache_hit_rate'):>9} "
            f"{_cache_cell(spc, 'cache_size'):>9} "
            f"{_cache_cell(spc, 'accepted_prefix_len_histogram'):>32}"
        )
    print("-" * len(cache_hdr))
    print("histogram index k = decode steps that committed k accepted draft "
          "tokens (0 = free pick only).")
    drifted = [s["scenario"] for s in artifact["scenarios"]
               if s["greedy_equivalence"] == "drift_spec"]
    if drifted:
        print(
            "\nFINDING: greedy spec != plain on this backend for "
            f"{drifted} (deterministic both ways). The batched-verify forward "
            "(kernel_mul_mm) rounds differently from single-token decode "
            "(kernel_mul_mv), flipping argmax at a near-tie. Recorded, not a "
            "harness failure — the short-window smoke remains the strict "
            "equivalence gate."
        )


async def main() -> int:
    assert h.PIE_BIN.exists(), f"missing pie binary at {h.PIE_BIN}"
    assert h.WASM_PATH.exists(), f"missing wasm at {h.WASM_PATH}"
    h.verify_stamp()

    with tempfile.TemporaryDirectory(prefix="spec-bench-") as tmp:
        tmp = Path(tmp)
        cfg = tmp / "config.toml"
        cfg.write_text(CONFIG_TOML)
        pie_home = tmp / "home"
        pie_home.mkdir()
        env = {
            **os.environ,
            "PIE_HOME": str(pie_home),
            "PIE_SHMEM_NAME": f"/spec_bench_{os.getpid()}",
        }
        proc = subprocess.Popen(
            [str(h.PIE_BIN), "serve", "--config", str(cfg), "--no-auth", "--debug"],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env,
            bufsize=1,
        )
        try:
            ws_addr, token = await h._parse_handshake(proc, timeout=120)
            print(f"[bench] engine ws=ws://{ws_addr}")
            drain = asyncio.create_task(h._drain_stdout(proc))
            try:
                client = PieClient(f"ws://{ws_addr}")
                await client.connect()
                await client.auth_by_token(token)
                await client.install_program(
                    h.WASM_PATH, h.MANIFEST_PATH, force_overwrite=True
                )
                port = h._free_port()
                base = f"http://127.0.0.1:{port}"
                await client.launch_daemon("chat-apc@0.1.0", port)
                if not h._wait_for_port(port, timeout=30):
                    raise RuntimeError(f"daemon never bound port {port}")
                artifact, failures = await _bench(base)
            finally:
                drain.cancel()
        finally:
            h._terminate_subprocess(proc, "engine")

    Path(BENCH_OUT).write_text(json.dumps(artifact, indent=2))
    _print_summary(artifact)
    print(f"\n[bench] machine-readable artifact -> {BENCH_OUT}")

    if failures:
        print("\n[bench] CONTRACT/MEASUREMENT FAILURES:")
        for f in failures:
            print(f"  ✗ {f}")
        return 1
    n = len(artifact["scenarios"])
    held = sum(1 for s in artifact["scenarios"]
               if s["greedy_equivalence"] == "held")
    drifted = sum(1 for s in artifact["scenarios"]
                  if s["greedy_equivalence"] == "drift_spec")
    ratios = [s["advisory_speedup"]["decode_tok_per_s_ratio"]
              for s in artifact["scenarios"]
              if isinstance(s["advisory_speedup"]["decode_tok_per_s_ratio"], (int, float))]
    su = f"{min(ratios):.2f}x–{max(ratios):.2f}x" if ratios else "n/a"
    print(
        f"\n[bench] PASS (measurement contract): {n} scenarios, "
        f"equivalence held={held} drift_spec={drifted}, advisory decode "
        f"speedup {su}. Speedup is advisory — see artifact; drift is recorded."
    )
    return 0


if __name__ == "__main__":
    import sys
    sys.exit(asyncio.run(main()))
