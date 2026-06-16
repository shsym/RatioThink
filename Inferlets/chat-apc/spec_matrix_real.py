"""Spec-decode benefit MATRIX: method × workload, PUBLIC pinned datasets (#652).

Extends the #510 single-prompt-set harness (`spec_bench_real.py`) into a
method×workload matrix. Where `spec_bench_real.py` runs three hand-written
scenarios, this harness sweeps the REAL public datasets prepared by
`Scripts/benchmark/prep_*.sh` (one row per dataset) under each speculative-
decoding method (one column per method) and reports, per cell, whether n-gram
drafting actually helps that workload.

Honesty is the whole point. The rows where n-gram is expected to WIN (code,
summarize) and the rows where it is expected to LOSE (open chat, reasoning) are
ALL present; a method that sweeps every row would not be credible. The
columns are:

  * plain      — `speculation:{enabled:false}` (drafting OFF; the spec_metrics
                 surface still emits engine decode tok/s for a like-for-like
                 baseline, exactly as in #510).
  * ngram      — `speculation:{enabled:true}` (the production linear Cacheback
                 n-gram drafter, Inferlets/chat-apc/src/chat/spec/).

A model-based draft column is intentionally ABSENT: it is gated on the #653
feasibility spike (can pie hold two model contexts in one engine?), which has
not landed, so there is nothing real to measure. A tree-draft / stochastic-
verify column is likewise absent — the drafter in `spec/cache.rs` is explicitly
LINEAR, not a tree. Both are recorded as out-of-scope in the artifact rather
than faked.

NO-CHERRYPICK / COVERAGE (the ticket's non-negotiable). The prompt set is the
FULL pinned split emitted by the prep scripts — never sampled or hand-picked.
A split too large to run end-to-end on a single Metal 7-14B target (CNN/DM is
11490 articles) is bounded ONLY at MEASUREMENT time by `MAX_PROMPTS`, applied
deterministically over the canonical-ordered split (a contiguous prefix), and
the per-cell `coverage` field records exactly `measured / total`. The split
emission stays full and reproducible (datasets.lock); only the runtime coverage
is bounded, and it is disclosed, not hidden.

PROTOCOL (greedy, per the ticket):
  * temperature=0 everywhere → plain is deterministic and the spec run must be
    byte-identical to it (else the speed claim is void). Each row runs a
    BASELINE DETERMINISM CONTROL on its first prompt (plain twice); a
    non-deterministic baseline fails that row's comparison as a measurement
    error, exactly as in #510.
  * fixed `MAX_TOKENS` held output cap, same model pair across methods.
  * thinking is per-row: reasoning rows (GSM8K) keep Qwen3 thinking ON; the
    others append the documented `/no_think` soft switch so the matrix is not
    dominated by think tokens on non-reasoning workloads. The think flag is
    carried in each dataset record (datasets.lock `think`).
  * cross-request reuse OFF (no `cache` directive, no `spec.thread_id`) so every
    request decodes cold and the plain-before-ngram ordering stays neutral
    (#596 F4) — enforced at runtime, reused from `spec_bench_real`.

PER-CELL METRICS:
  * acceptance alpha   = Σ accepted_draft_tokens / Σ proposed_draft_tokens
  * accepted-run-length = mean avg_tokens_per_step + summed prefix-len histogram
  * engine decode tok/s (median over prompts), and end-to-end wall tok/s
  * TTFT (s) and TPOT (ms/token = (wall-ttft)/generated_tokens)
  * advisory speedup    = ngram engine tok/s ÷ plain engine tok/s
  * greedy equivalence rate = fraction of prompts where ngram == plain bytes
For n-gram the draft cost c_draft≈0 (a table lookup, no draft forward pass), so
the textbook speedup ≈ 1 + alpha·gamma is realized directly as the measured
tok/s ratio; both are recorded.

Outputs a machine-readable JSON artifact (`$MATRIX_OUT`) and a rendered matrix
to stdout. Exit is NONZERO only for measurement/contract failures (non-200,
missing/inconsistent metrics, baseline non-determinism, a greedy ngram run that
silently fell back to plain); a negative/zero speedup and recorded drift do NOT
fail the run.

Requires: built `Vendor/pie/target/release/pie` (Metal portable), the prebuilt
chat-apc wasm + stamp, a real model WITH WEIGHTS, and the prep scripts run so
`Scripts/benchmark/data/<key>.jsonl` exists.

Usage::

    MODEL=Qwen/Qwen3-8B MAX_TOKENS=256 MAX_PROMPTS=16 \
      uv run --project Vendor/pie/client/python --with httpx \
        python Inferlets/chat-apc/spec_matrix_real.py
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

import e2e_test as h  # boot/teardown + PIE_BIN/WASM_PATH/MANIFEST_PATH
import spec_bench_real as b  # reuse the #510 contract/classify/format helpers

MODEL = os.environ.get("MODEL", "Qwen/Qwen3-8B")
MAX_TOKENS = int(os.environ.get("MAX_TOKENS", "256"))
# 0 → measure the WHOLE split (the opt-in long run). Default bounds the
# in-session matrix; coverage is recorded per cell either way.
MAX_PROMPTS = int(os.environ.get("MAX_PROMPTS", "16"))
MATRIX_OUT = os.environ.get(
    "MATRIX_OUT", f"spec_matrix_{MODEL.replace('/', '__')}.json"
)
_REPO_ROOT = Path(__file__).resolve().parents[2]
DATA_DIR = _REPO_ROOT / "Scripts" / "benchmark" / "data"
LOCK_PATH = _REPO_ROOT / "Scripts" / "benchmark" / "datasets.lock"

# Methods (columns). plain MUST run first so it is the determinism control and
# the equivalence reference for the ngram run on the same prompt.
PROFILES = {
    "plain": {"enabled": False},
    "ngram": {"enabled": True},
}

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
request_timeout_secs = 600
default_endowment_pages = 4
admission_oversubscription_factor = 8.0
restore_pause_at_utilization = 0.85

[model.driver]
type = "portable"
device = ["metal"]
"""


def _which_datasets() -> list[str]:
    sel = os.environ.get("DATASETS")
    lock = json.loads(LOCK_PATH.read_text()) if LOCK_PATH.exists() else {"datasets": {}}
    locked = list(lock.get("datasets", {}).keys())
    if sel:
        want = [s.strip() for s in sel.split(",") if s.strip()]
        missing = [w for w in want if w not in locked]
        if missing:
            raise SystemExit(
                f"requested datasets not in lock: {missing}; locked: {sorted(locked)}"
            )
        return want
    return sorted(locked)


def _load_prompts(key: str) -> tuple[list[dict], int]:
    """Return (measured prompt records, full split total). Fails loud with the
    exact prep command if the emitted set is absent."""
    path = DATA_DIR / f"{key}.jsonl"
    if not path.exists():
        raise SystemExit(
            f"missing prompt set {path} — run Scripts/benchmark/prep_{key}.sh first"
        )
    records = [json.loads(line) for line in path.read_text().splitlines() if line]
    total = len(records)
    if MAX_PROMPTS > 0:
        records = records[:MAX_PROMPTS]
    return records, total


async def _stream_run(
    http_c: httpx.AsyncClient, base: str, prompt: str, think: bool, spec: dict
) -> dict:
    """Stream one greedy chat completion, measuring client latency and the
    terminal spec_metrics frame. `think=False` appends Qwen3's `/no_think` soft
    switch so non-reasoning rows don't pay for a think block."""
    content = prompt if think else f"{prompt}\n/no_think"
    body = {
        "model": MODEL,
        "messages": [{"role": "user", "content": content}],
        "temperature": 0,
        "max_tokens": MAX_TOKENS,
        "stream": True,
        "speculation": spec,
    }
    # #596 F4: both cross-request reuse channels stay OFF (see module docstring).
    assert "cache" not in body, "harness must not send a `cache` directive (#522)"
    assert "thread_id" not in spec, "harness must not send `speculation.thread_id`"

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
            return {"status": status, "error_body": text[:400]}
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
    rec: dict = {
        "status": status,
        "content": "".join(content_parts),
        "reasoning": "".join(reasoning_parts),
        "model_ready_s": model_ready_s,
        "ttft_s": ttft_s,
        "wall_s": wall_s,
        "spec_metrics": spec_metrics,
        "error_frame": error_frame,
    }
    gen = (spec_metrics or {}).get("generated_tokens")
    if gen and ttft_s is not None and wall_s > ttft_s:
        rec["tpot_ms"] = 1000.0 * (wall_s - ttft_s) / gen
        rec["wall_tok_per_s"] = gen / (wall_s - ttft_s)
    else:
        rec["tpot_ms"] = None
        rec["wall_tok_per_s"] = None
    return rec


def _out(r: dict) -> tuple[str, str]:
    return (r.get("content", ""), r.get("reasoning", ""))


def _sum_hist(hists: list) -> list[int]:
    acc: list[int] = []
    for hh in hists:
        if not isinstance(hh, (list, tuple)):
            continue
        for i, v in enumerate(hh):
            if i >= len(acc):
                acc.extend([0] * (i + 1 - len(acc)))
            acc[i] += int(v)
    return acc


async def _bench_dataset(http_c, base, key, records, total, failures) -> dict:
    print(f"\n[matrix] dataset={key!r} measuring {len(records)}/{total} prompts")
    plain_runs: list[dict] = []
    ngram_runs: list[dict] = []
    equiv_hold = 0
    equiv_drift = 0
    equiv_invalid = 0
    baseline_nondet_prompts = 0

    for idx, rec in enumerate(records):
        prompt, think = rec["prompt"], bool(rec.get("think"))
        p1 = await _stream_run(http_c, base, prompt, think, PROFILES["plain"])
        # Determinism control on the first prompt only (cost bound): a second
        # plain run proves the baseline is deterministic for this row.
        p2 = await _stream_run(http_c, base, prompt, think, PROFILES["plain"]) if idx == 0 else None
        n1 = await _stream_run(http_c, base, prompt, think, PROFILES["ngram"])

        # Stash each run's contract verdict so cell() aggregates only over
        # HEALTHY runs. A degraded run can still ride a 200 (a mid-stream
        # `event:error` SSE frame, an empty decode, renamed/missing spec keys),
        # so gating the cell on `status==200 and spec_metrics` would fold its
        # zeros into alpha/tok-s/histograms. `_check_run` already made that call
        # — reuse its verdict instead of re-deriving a weaker one.
        p1["_check_ok"] = b._check_run("plain", f"{key}[{idx}]", p1, failures)
        n1["_check_ok"] = b._check_run("ngram", f"{key}[{idx}]", n1, failures)
        plain_runs.append(p1)
        ngram_runs.append(n1)

        if p1.get("status") != 200 or n1.get("status") != 200:
            equiv_invalid += 1
            continue
        if idx == 0 and p2 is not None and p2.get("status") == 200:
            if _out(p1) != _out(p2):
                baseline_nondet_prompts += 1
                failures.append(
                    f"[{key}] baseline plain decode NON-DETERMINISTIC on prompt 0 "
                    f"(run A != run B); spec/plain comparison invalid for this row"
                )
        if _out(p1) == _out(n1):
            equiv_hold += 1
        elif idx == 0 and baseline_nondet_prompts:
            equiv_invalid += 1
        else:
            equiv_drift += 1

        st = b._classify(n1)
        if st.startswith("fallback:"):
            failures.append(
                f"[{key}[{idx}]] ngram greedy run did not engage speculation "
                f"(status={st}); expected drafting to run"
            )

    def cell(runs: list[dict], label: str) -> dict:
        # `_check_ok` is the `_check_run` verdict (set in the loop above): True
        # only for runs that passed every contract check, so a degraded-but-200
        # run never reaches the aggregates. It implies a non-None spec_metrics.
        ok = [r for r in runs if r.get("_check_ok")]
        sms = [r["spec_metrics"] for r in ok]
        proposed = sum(s.get("proposed_draft_tokens", 0) for s in sms)
        accepted = sum(s.get("accepted_draft_tokens", 0) for s in sms)
        rejected = sum(s.get("rejected_draft_tokens", 0) for s in sms)
        avg_steps = [s.get("avg_tokens_per_step") for s in sms
                     if isinstance(s.get("avg_tokens_per_step"), (int, float))]
        return {
            "method": label,
            "runs_ok": len(ok),
            "engine_tok_per_s": b._median(sms, "decode_tokens_per_sec"),
            "wall_tok_per_s": b._median(ok, "wall_tok_per_s"),
            "ttft_s": b._median(ok, "ttft_s"),
            "tpot_ms": b._median(ok, "tpot_ms"),
            "proposed_draft_tokens": proposed,
            "accepted_draft_tokens": accepted,
            "rejected_draft_tokens": rejected,
            "acceptance_alpha": (accepted / proposed) if proposed else 0.0,
            "mean_accepted_run_length": (sum(avg_steps) / len(avg_steps)) if avg_steps else None,
            "accepted_prefix_len_histogram": _sum_hist(
                [s.get("accepted_prefix_len_histogram") for s in sms]
            ),
        }

    plain_cell = cell(plain_runs, "plain")
    ngram_cell = cell(ngram_runs, "ngram")
    pt, nt = plain_cell["engine_tok_per_s"], ngram_cell["engine_tok_per_s"]
    speedup = (nt / pt) if (pt and nt) else None
    measured = len(records)
    equiv_valid = equiv_hold + equiv_drift  # prompts actually compared (both 200)
    return {
        "dataset": key,
        "category": records[0].get("category") if records else None,
        "think": bool(records[0].get("think")) if records else None,
        "coverage": {"measured": measured, "total": total,
                     "fraction": (measured / total) if total else None,
                     "bounded_by": "MAX_PROMPTS" if (MAX_PROMPTS and measured < total) else "full"},
        "greedy_equivalence": {
            "held": equiv_hold, "drift_spec": equiv_drift,
            "invalid": equiv_invalid, "baseline_nondeterministic_prompts": baseline_nondet_prompts,
            # Rate is over the COMPARED population (held + drift), not `measured`:
            # an `invalid` (non-200) prompt was skipped before any byte compare, so
            # including it in the denominator would silently deflate the byte-identity
            # contract. invalid stays reported separately for disclosure.
            "rate": (equiv_hold / equiv_valid) if equiv_valid else None,
        },
        "advisory_speedup_engine_tok_per_s": speedup,
        "cells": {"plain": plain_cell, "ngram": ngram_cell},
    }


async def _run(base: str) -> tuple[dict, list[str]]:
    failures: list[str] = []
    rows = []
    async with httpx.AsyncClient(timeout=600) as http_c:
        for key in _which_datasets():
            records, total = _load_prompts(key)
            if not records:
                failures.append(f"[{key}] no prompts after cap")
                continue
            rows.append(await _bench_dataset(http_c, base, key, records, total, failures))
    artifact = {
        "model": MODEL,
        "driver": "portable/metal",
        "decode_settings": {"temperature": 0, "max_tokens": MAX_TOKENS,
                            "max_prompts": MAX_PROMPTS},
        "methods": list(PROFILES),
        "excluded_methods": {
            "model_based_draft": "gated on #653 feasibility spike (two model "
            "contexts in one engine) — not landed, nothing real to measure",
            "tree_draft_stochastic_verify": "drafter in spec/cache.rs is linear, "
            "not a tree — no implementation to measure",
        },
        "rows": rows,
    }
    return artifact, failures


def _print_matrix(artifact: dict) -> None:
    print("\n" + "=" * 96)
    print(f"Spec-decode benefit matrix — {artifact['model']} ({artifact['driver']})")
    print(f"max_tokens={artifact['decode_settings']['max_tokens']} "
          f"max_prompts={artifact['decode_settings']['max_prompts']} "
          f"(0=full split)  methods={artifact['methods']}")
    print("=" * 96)
    hdr = (
        f"{'dataset':<11} {'cat':<10} {'cover':>9} {'alpha':>6} {'run-len':>7} "
        f"{'tok/s plain':>11} {'tok/s ngram':>11} {'speedup':>8} "
        f"{'TTFT p/n':>14} {'TPOT p/n ms':>14} {'equiv':>10}"
    )
    print(hdr)
    print("-" * len(hdr))
    for r in artifact["rows"]:
        pc, nc = r["cells"]["plain"], r["cells"]["ngram"]
        cov = r["coverage"]
        cover = f"{cov['measured']}/{cov['total']}"
        alpha = f"{nc['acceptance_alpha']:.2f}"
        rl = nc["mean_accepted_run_length"]
        rl_s = f"{rl:.2f}" if isinstance(rl, (int, float)) else "--"

        def f1(x, fmt="{:.1f}"):
            return fmt.format(x) if isinstance(x, (int, float)) else "--"

        su = r["advisory_speedup_engine_tok_per_s"]
        su_s = f"{su:.2f}x" if isinstance(su, (int, float)) else "--"
        eq = r["greedy_equivalence"]
        eq_s = f"{eq['held']}/{cov['measured']}"
        ttft = f"{f1(pc['ttft_s'],'{:.2f}')}/{f1(nc['ttft_s'],'{:.2f}')}"
        tpot = f"{f1(pc['tpot_ms'])}/{f1(nc['tpot_ms'])}"
        print(
            f"{r['dataset']:<11} {str(r['category']):<10} {cover:>9} {alpha:>6} "
            f"{rl_s:>7} {f1(pc['engine_tok_per_s']):>11} {f1(nc['engine_tok_per_s']):>11} "
            f"{su_s:>8} {ttft:>14} {tpot:>14} {eq_s:>10}"
        )
    print("-" * len(hdr))
    print("alpha = Σaccepted/Σproposed draft tokens; run-len = mean accepted "
          "tokens/decode-step; speedup = ngram engine tok/s ÷ plain (ADVISORY).")
    print("equiv = #prompts where ngram output == plain output (greedy "
          "byte-identity); coverage = measured/total of the FULL pinned split.")
    print("\nExcluded columns:")
    for k, v in artifact["excluded_methods"].items():
        print(f"  • {k}: {v}")


async def main() -> int:
    assert h.PIE_BIN.exists(), f"missing pie binary at {h.PIE_BIN}"
    assert h.WASM_PATH.exists(), f"missing wasm at {h.WASM_PATH}"
    h.verify_stamp()
    if not LOCK_PATH.exists():
        raise SystemExit(
            "no datasets.lock — run Scripts/benchmark/prep_all.sh first"
        )

    with tempfile.TemporaryDirectory(prefix="spec-matrix-") as tmp:
        tmp = Path(tmp)
        cfg = tmp / "config.toml"
        cfg.write_text(CONFIG_TOML)
        pie_home = tmp / "home"
        pie_home.mkdir()
        env = {
            **os.environ,
            "PIE_HOME": str(pie_home),
            "PIE_SHMEM_NAME": f"/spec_matrix_{os.getpid()}",
        }
        proc = subprocess.Popen(
            [str(h.PIE_BIN), "serve", "--config", str(cfg), "--no-auth", "--debug"],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env,
            bufsize=1,
        )
        try:
            ws_addr, token = await h._parse_handshake(proc, timeout=300)
            print(f"[matrix] engine ws=ws://{ws_addr}")
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
                artifact, failures = await _run(base)
            finally:
                drain.cancel()
        finally:
            h._terminate_subprocess(proc, "engine")

    Path(MATRIX_OUT).write_text(json.dumps(artifact, indent=2))
    _print_matrix(artifact)
    print(f"\n[matrix] machine-readable artifact -> {MATRIX_OUT}")

    if failures:
        print("\n[matrix] CONTRACT/MEASUREMENT FAILURES:")
        for f in failures:
            print(f"  ✗ {f}")
        return 1
    wins = [r["dataset"] for r in artifact["rows"]
            if isinstance(r["advisory_speedup_engine_tok_per_s"], (int, float))
            and r["advisory_speedup_engine_tok_per_s"] > 1.0]
    print(
        f"\n[matrix] PASS (measurement contract): {len(artifact['rows'])} rows. "
        f"n-gram net-faster rows (engine tok/s): {wins or 'none'}. "
        "Speedup is advisory; equivalence + coverage are recorded per cell."
    )
    return 0


if __name__ == "__main__":
    import sys
    sys.exit(asyncio.run(main()))
