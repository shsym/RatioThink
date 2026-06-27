"""FAITHFUL Tree-of-Thoughts task-accuracy harness (#657, Yao 2023 §3, Alg. 1).

The earlier depth=1 design measured best-of-N + LLM-as-judge rerank, not ToT (a
cited literature review confirmed it diverges from canonical ToT on all four
axes). This is the redesign: the search runs HOST-SIDE (tot_search.bfs), the
engine is a `/v1/chat/completions` DECODE PRIMITIVE, and the shipped wasm
tree-of-thought inferlet is left untouched — so this measures ToT-the-method on
the deterministically-gradable PUBLIC pinned datasets (GSM8K, HumanEval, MBPP,
JSONSchemaBench), reusing the #652 prep/lock/gitignore pin and the `e2e_test`
boot. grade.py stays the final-accuracy ORACLE; the search never sees the gold.

FOUR ARMS per dataset, all graded by grade.py:
  * B0 greedy   — single greedy CoT chain, temperature 0 (canonical baseline).
  * B1 single   — one sample at SINGLE_TEMPERATURE.
  * B2 best-of-k — self-consistency over k whole samples at matched temperature,
                  selected by a TASK-APPROPRIATE rule that never touches the gold:
                  math=majority vote, code=execution agreement vs SELF-GENERATED
                  tests (CodeT-style), json=first schema-valid. The decisive
                  control: ToT must beat B2 to show STRUCTURE helps beyond samples.
  * ToT          — harness-side BFS keep-b over PARTIAL states (tot_search):
                  math = sample step-wise thoughts + value×3 evaluator (Yao §4.1),
                  code = propose plans → execute-rank leaves (NO LLM judging of
                  code), json = N/A (constrained-decoding task, not ToT).

PER-TASK design (Yao §3 axes), tunable by env (MATH_DEPTH/CODE_DEPTH/TOT_WIDTH/
*_TEMPERATURE). Code runs low-T (pass@1 wants the mode; Chen 2021). The matrix
reports B0/B1/B2/ToT accuracy + ToT−B2 (structure vs samples), ToT−B0, B2−B0.

DISCLOSURE & RESILIENCE. Tokens per arm = Σ tokenizer tokens over EVERY engine
call the arm made (B2 pays for k samples, ToT for the whole tree), counted for
GRADED runs only. An ungradable answer or an engine/transport failure is held out
of the denominator and disclosed (n_ungradable / n_error / first_error), never
scored wrong or allowed to abort the matrix. #679 NOTE: this path avoids the ToT
INFERLET, so the #679 daemon trap should not bite; thinking-ON math is still
heavy and degrades gracefully (errored arms disclosed) rather than crashing.

CODE EXECUTION WARNING: code grading + self-test agreement execute model code in
a subprocess (grade.py). Operator-gated, never CI; the CI guard is the engine-
free tot_search_test / baselines_test / tot_arms_test / tot_accuracy_real_test.

Usage::

    MODEL=Qwen/Qwen3-8B MAX_PROMPTS=12 TOT_WIDTH=4 \
      uv run --project Vendor/pie/client/python --with httpx --with jsonschema \
        --with tokenizers --with huggingface_hub \
        python Inferlets/chat-apc/tot_accuracy_real.py
"""
from __future__ import annotations

import asyncio
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

import httpx
from pie_client import PieClient

_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

import e2e_test as h  # noqa: E402  boot/teardown + PIE_BIN/WASM_PATH/MANIFEST_PATH
import tot_arms as ta  # noqa: E402  arm orchestration (B0/B1/B2/ToT)
import tot_search as ts  # noqa: E402  faithful BFS controller

MODEL = os.environ.get("MODEL", "Qwen/Qwen3-8B")
MAX_TOKENS = int(os.environ.get("MAX_TOKENS", "512"))
MAX_PROMPTS = int(os.environ.get("MAX_PROMPTS", "12"))  # 0 → whole split
TOT_WIDTH = int(os.environ.get("TOT_WIDTH", "4"))  # k for the ToT column
TOT_TEMPERATURE = float(os.environ.get("TOT_TEMPERATURE", "0.7"))
# Single-chain decode temperature. Default 0.0 = greedy CoT (the canonical
# baseline; keeps the module docstring's "single is deterministic" framing).
# Set it equal to TOT_TEMPERATURE to ISOLATE search width as the only variable
# (single = best-of-1 sample, tot = best-of-k samples, identical temperature) —
# separating "did width help" from "did sampling vs greedy move the number".
# B1's temperature. Unset → MATCH the dataset's family temperature (so B1/B2/ToT
# decode at the same temp and only the search/sampling structure differs; B0
# greedy stays the canonical temp-0 baseline). Set it to pin B1 explicitly.
_SINGLE_T_ENV = os.environ.get("SINGLE_TEMPERATURE")
SINGLE_TEMPERATURE = float(_SINGLE_T_ENV) if _SINGLE_T_ENV is not None else None
ACCURACY_OUT = os.environ.get(
    "ACCURACY_OUT", f"tot_accuracy_{MODEL.replace('/', '__')}.json"
)
_REPO_ROOT = Path(__file__).resolve().parents[2]
DATA_DIR = _REPO_ROOT / "Scripts" / "benchmark" / "data"
LOCK_PATH = _REPO_ROOT / "Scripts" / "benchmark" / "datasets.lock"

MATH_DEPTH = int(os.environ.get("MATH_DEPTH", "6"))
CODE_DEPTH = int(os.environ.get("CODE_DEPTH", "3"))
CODE_TEMPERATURE = float(os.environ.get("CODE_TEMPERATURE", "0.2"))  # low-T for code pass@1


def _task_config(family: str, grader: str) -> ta.DatasetArmsConfig:
    """Per-task ToT design (Yao §3 axes), built from env knobs. math = sample
    step-wise + value×3 + BFS keep-b; code = propose plans → execute-rank leaves
    (NO LLM judging of code) at low temperature; json = no ToT (constrained-
    decoding task), B0/B1/B2-first-valid only."""
    if family == "math":
        spec = ts.TaskSpec(
            name="math", depth=MATH_DEPTH, breadth=TOT_WIDTH, generator="sample",
            intermediate_eval="value", eval_samples=3, temperature=TOT_TEMPERATURE,
            max_tokens=MAX_TOKENS,
            step_cue="Continue with the SINGLE next reasoning step only (one short "
                     "step). Do not state the final answer yet.",
            value_cue="Independently recompute and judge whether the reasoning so "
                      "far is on track to the correct answer. End with exactly: "
                      "SCORE: N  (N=1 impossible … 10 sure).",
            final_cue="Now give the final answer. End with: #### <number>.",
        )
        b1_t = SINGLE_TEMPERATURE if SINGLE_TEMPERATURE is not None else TOT_TEMPERATURE
        return ta.DatasetArmsConfig("math", grader, TOT_WIDTH, TOT_TEMPERATURE,
                                    MAX_TOKENS, spec, single_temperature=b1_t)
    if family == "code":
        spec = ts.TaskSpec(
            name="code", depth=CODE_DEPTH, breadth=TOT_WIDTH, generator="propose",
            intermediate_eval="none", eval_samples=1, temperature=CODE_TEMPERATURE,
            max_tokens=MAX_TOKENS,
            step_cue="Sketch the implementation approach in one line.",
            propose_cue=f"Propose {TOT_WIDTH} DISTINCT one-line implementation "
                        f"approaches. Number them 1..{TOT_WIDTH}.",
            final_cue="Write the complete Python function. Output only the function "
                      "definition.",
        )
        b1_t = SINGLE_TEMPERATURE if SINGLE_TEMPERATURE is not None else CODE_TEMPERATURE
        return ta.DatasetArmsConfig(
            "code", grader, TOT_WIDTH, CODE_TEMPERATURE, MAX_TOKENS, spec,
            selftest_cue="Write up to 5 `assert` statements any correct "
                         "implementation must pass. Output only the assert lines.",
            single_temperature=b1_t)
    if family == "json":
        b1_t = SINGLE_TEMPERATURE if SINGLE_TEMPERATURE is not None else TOT_TEMPERATURE
        return ta.DatasetArmsConfig("json", grader, TOT_WIDTH, TOT_TEMPERATURE,
                                    MAX_TOKENS, spec=None, single_temperature=b1_t)
    raise SystemExit(f"unknown task family {family!r}")


# Dataset → task family (drives decomposition/generator/evaluator/search).
FAMILY = {"gsm8k": "math", "humaneval": "code", "mbpp": "code", "jsonschema": "json"}

def config_toml(model: str) -> str:
    return f"""
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
name = "{model}"
hf_repo = "{model}"

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


CONFIG_TOML = config_toml(MODEL)


def _load_tokenizer():
    """Real token counter for the SERVED model (so the per-token axis uses the
    model's own tokenization). Falls back to a labeled whitespace proxy if the
    tokenizer can't be fetched, so the report never passes a proxy off as real
    tokens."""
    try:
        from huggingface_hub import hf_hub_download
        from tokenizers import Tokenizer

        path = hf_hub_download(MODEL, "tokenizer.json")
        tok = Tokenizer.from_file(path)
        return (lambda s: len(tok.encode(s).ids), "tokens")
    except Exception as e:  # noqa: BLE001
        print(f"[accuracy] tokenizer unavailable ({e}); using word-count proxy",
              flush=True)
        return (lambda s: len(s.split()), "words(proxy)")


def _which_datasets() -> list[str]:
    """Graded datasets only (those carrying a `grader` in the lock), intersected
    with an optional DATASETS allow-list. An ungraded request is a hard error so
    a typo can't silently drop a row."""
    lock = json.loads(LOCK_PATH.read_text()) if LOCK_PATH.exists() else {"datasets": {}}
    graded = {k: v for k, v in lock.get("datasets", {}).items() if v.get("grader")}
    sel = os.environ.get("DATASETS")
    if sel:
        want = [s.strip() for s in sel.split(",") if s.strip()]
        missing = [w for w in want if w not in graded]
        if missing:
            raise SystemExit(
                f"requested datasets not graded/locked: {missing}; "
                f"graded: {sorted(graded)}"
            )
        return want
    return sorted(graded)


def _grader_for(key: str) -> str:
    lock = json.loads(LOCK_PATH.read_text())
    return lock["datasets"][key]["grader"]


def _load_prompts(key: str) -> tuple[list[dict], int]:
    path = DATA_DIR / f"{key}.jsonl"
    if not path.exists():
        raise SystemExit(
            f"missing prompt set {path} — run Scripts/benchmark/prep_{key}.sh first"
        )
    records = [json.loads(line) for line in path.read_text().splitlines() if line]
    total = len(records)
    if MAX_PROMPTS > 0:
        records = records[:MAX_PROMPTS]
    missing_ref = [r["id"] for r in records if "reference" not in r]
    if missing_ref:
        raise SystemExit(
            f"{key}: {len(missing_ref)} records lack a `reference` — re-run "
            f"prep_{key}.sh after the #657 prep change (e.g. {missing_ref[:3]})"
        )
    return records, total


def _with_no_think(messages: list[dict]) -> list[dict]:
    """Append Qwen3's `/no_think` soft switch to the last user message for non-
    reasoning datasets (so a code/JSON arm doesn't pay for a think block). The
    math family leaves thinking ON."""
    if not messages or messages[-1].get("role") != "user":
        return messages
    out = [dict(m) for m in messages]
    out[-1]["content"] = f"{out[-1]['content']}\n/no_think"
    return out


# Bounded retry for a transient `forward_pass_starved` 500 (the engine
# momentarily produced no tokens under GPU/memory pressure) or a transient
# transport blip. Backoff is short and CAPPED: if the engine is persistently
# memory-walled, the arm errors after RETRY_BACKOFFS rather than retrying for
# hours (operator's stop condition). A 400 (bad request) is NOT retried.
RETRY_BACKOFFS = (1.0, 3.0, 6.0, 10.0)


def _make_complete(http_c, base: str, think: bool):
    """A dataset-scoped decode primitive over /v1/chat/completions (engine as a
    plain token producer; the ToT search is host-side, the shipped inferlet is
    untouched). Raises after bounded retries so the arm records it errored
    (tot_arms._arm catches) rather than scoring a wrong answer or aborting."""
    async def complete(messages, temperature, max_tokens):
        msgs = messages if think else _with_no_think(messages)
        body = {
            "model": MODEL, "messages": msgs, "temperature": temperature,
            "max_tokens": max_tokens, "stream": False,
            "top_p": 1.0 if temperature == 0.0 else 0.95,
        }
        last = "unknown"
        for attempt in range(len(RETRY_BACKOFFS) + 1):
            try:
                r = await http_c.post(f"{base}/v1/chat/completions", json=body)
            except httpx.HTTPError as e:
                last = f"transport {type(e).__name__}: {e}"
            else:
                if r.status_code == 200:
                    msg = (r.json().get("choices") or [{}])[0].get("message") or {}
                    # Thinking-ON answers can spend the whole budget in the
                    # <think> block and return empty content (#600/#434) — fall
                    # back to reasoning_content (a bare empty assistant turn also
                    # 400s the next request). No-op for /no_think rows.
                    return ((msg.get("content") or "").strip()
                            or (msg.get("reasoning_content") or "").strip())
                last = f"chat/completions {r.status_code}: {r.text[:160]}"
                # Only retry transient engine starvation; a 4xx is the caller's bug.
                if r.status_code < 500 and "forward_pass_starved" not in r.text:
                    raise RuntimeError(last)
            if attempt < len(RETRY_BACKOFFS):
                await asyncio.sleep(RETRY_BACKOFFS[attempt])
        raise RuntimeError(f"{last} (after {len(RETRY_BACKOFFS)} retries)")
    return complete


async def _run(base: str, count) -> tuple[dict, list[str]]:
    failures: list[str] = []
    rows = []
    async with httpx.AsyncClient(timeout=600) as http_c:
        for key in _which_datasets():
            grader = _grader_for(key)
            family = FAMILY.get(key)
            if family is None:
                failures.append(f"[{key}] no task family mapping")
                continue
            records, total = _load_prompts(key)
            if not records:
                failures.append(f"[{key}] no prompts after cap")
                continue
            think = bool(records[0].get("think"))
            cfg = _task_config(family, grader)
            complete = _make_complete(http_c, base, think)
            print(f"\n[accuracy] dataset={key!r} family={family} grader={grader!r} "
                  f"measuring {len(records)}/{total} prompts "
                  f"(arms: {'B0,B1,B2' if cfg.spec is None else 'B0,B1,B2,ToT'})")
            row = await ta.run_dataset(records, cfg, complete, count)
            row.update({
                "dataset": key,
                "coverage": {"measured": len(records), "total": total,
                             "fraction": (len(records) / total) if total else None,
                             "bounded_by": "MAX_PROMPTS"
                             if (MAX_PROMPTS and len(records) < total) else "full"},
            })
            rows.append(row)
            for arm, c in row["cells"].items():
                if c["n_error"] and c.get("first_error") and "N/A" not in c["first_error"]:
                    failures.append(
                        f"[{key} {arm}] {c['n_error']} errored: "
                        f"{c['first_error'][:160]}"
                    )
    artifact = {
        "model": MODEL,
        "driver": "portable/metal",
        "framing": "Harness-side FAITHFUL Tree-of-Thoughts (Yao 2023 §3, BFS keep-b "
                   "Alg.1): engine is a /v1/chat/completions decode primitive; the "
                   "shipped wasm tree-of-thought inferlet is untouched. Measures "
                   "ToT-the-method.",
        "decode_settings": {
            "max_tokens": MAX_TOKENS, "max_prompts": MAX_PROMPTS, "breadth_k": TOT_WIDTH,
            "tot_temperature": TOT_TEMPERATURE,
            "single_temperature": (
                SINGLE_TEMPERATURE if SINGLE_TEMPERATURE is not None else "match-family"
            ),
            "code_temperature": CODE_TEMPERATURE, "math_depth": MATH_DEPTH,
            "code_depth": CODE_DEPTH,
        },
        "arms": {
            "B0_greedy": "greedy CoT, single chain, temperature 0 (canonical baseline)",
            "B1_single": f"single sample at SINGLE_TEMPERATURE={SINGLE_TEMPERATURE}",
            "B2_bestofk": f"self-consistency best-of-{TOT_WIDTH} at matched temp; select "
                          "math=majority-vote, code=execution-agreement (self-gen tests, "
                          "NOT grading tests), json=first-valid",
            "ToT": "harness-side BFS keep-b over PARTIAL states; math=sample steps+value×3, "
                   "code=propose plans→execute-rank leaves (no LLM judging of code), "
                   "json=N/A (constrained-decoding task)",
        },
        "headline": "ToT−B2 isolates SEARCH STRUCTURE from MORE SAMPLES; ToT−B0 vs greedy.",
        "token_accounting_caveat": "tokens per arm = Σ tokenizer tokens over EVERY engine "
        "call the arm made (B2 pays for k samples, ToT for the whole tree), counted for "
        "GRADED runs only (same population as accuracy).",
        "rows": rows,
    }
    return artifact, failures


def _print_matrix(artifact: dict, unit: str) -> None:
    print("\n" + "=" * 110)
    print(f"FAITHFUL ToT accuracy matrix — {artifact['model']} ({artifact['driver']})")
    ds = artifact["decode_settings"]
    print(f"k={ds['breadth_k']}  math depth={ds['math_depth']} (think-ON)  code depth="
          f"{ds['code_depth']} @T={ds['code_temperature']}  tot_T={ds['tot_temperature']}  "
          f"B1_T={ds['single_temperature']}  max_tokens={ds['max_tokens']}  "
          f"max_prompts={ds['max_prompts']}")
    print("=" * 110)
    hdr = (
        f"{'dataset':<11} {'family':<6} {'cover':>8} "
        f"{'B0':>6} {'B1':>6} {'B2':>6} {'ToT':>6} "
        f"{'ToT-B2':>7} {'ToT-B0':>7} {'B2-B0':>7}"
    )
    print(hdr)
    print("-" * len(hdr))

    def f(x, fmt="{:.3f}"):
        return fmt.format(x) if isinstance(x, (int, float)) else "--"

    for r in artifact["rows"]:
        c = r["cells"]
        cov = r["coverage"]
        print(
            f"{r['dataset']:<11} {r['family']:<6} {cov['measured']}/{cov['total']:<6} "
            f"{f(c['B0_greedy']['accuracy']):>6} {f(c['B1_single']['accuracy']):>6} "
            f"{f(c['B2_bestofk']['accuracy']):>6} {f(c['ToT']['accuracy']):>6} "
            f"{f(r['tot_minus_b2'],'{:+.3f}'):>7} {f(r['tot_minus_b0'],'{:+.3f}'):>7} "
            f"{f(r['b2_minus_b0'],'{:+.3f}'):>7}"
        )
    print("-" * len(hdr))
    print("acc = correct/graded (ungradable+errored held out). ToT-B2 = does SEARCH "
          "STRUCTURE beat more samples; ToT-B0 = vs greedy CoT; B2-B0 = samples vs greedy.")
    for arm, desc in artifact["arms"].items():
        print(f"  • {arm}: {desc}")
    print(f"\nFraming: {artifact['framing']}")
    print(f"Token accounting: {artifact['token_accounting_caveat']}")


async def main() -> int:
    assert h.PIE_BIN.exists(), f"missing pie binary at {h.PIE_BIN}"
    assert h.WASM_PATH.exists(), f"missing wasm at {h.WASM_PATH}"
    h.verify_stamp()
    if not LOCK_PATH.exists():
        raise SystemExit("no datasets.lock — run Scripts/benchmark/prep_all.sh first")

    count, unit = _load_tokenizer()

    # PIE_HOME under a SHORT /tmp dir, not the per-user $TMPDIR
    # (/var/folders/…, ~50 chars): the portable driver opens an aux_server unix
    # socket at $PIE_HOME/standalone/<pid>/g0/aux.sock, and the macOS sun_path
    # limit is 104 bytes — a $TMPDIR-nested home overflows it before the engine
    # can serve a single request.
    with tempfile.TemporaryDirectory(prefix="ta-", dir="/tmp") as tmp:
        tmp = Path(tmp)
        cfg = tmp / "config.toml"
        cfg.write_text(CONFIG_TOML)
        pie_home = tmp / "home"
        pie_home.mkdir()
        env = {
            **os.environ,
            "PIE_HOME": str(pie_home),
            "PIE_SHMEM_NAME": f"/tot_accuracy_{os.getpid()}",
        }
        proc = subprocess.Popen(
            [str(h.PIE_BIN), "serve", "--config", str(cfg), "--no-auth", "--debug"],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env,
            bufsize=1,
        )
        try:
            ws_addr, token = await h._parse_handshake(proc, timeout=300)
            print(f"[accuracy] engine ws=ws://{ws_addr}")
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
                artifact, failures = await _run(base, count)
            finally:
                drain.cancel()
        finally:
            h._terminate_subprocess(proc, "engine")

    Path(ACCURACY_OUT).write_text(json.dumps(artifact, indent=2))
    _print_matrix(artifact, unit)
    print(f"\n[accuracy] machine-readable artifact -> {ACCURACY_OUT}")

    if failures:
        print("\n[accuracy] CONTRACT/MEASUREMENT FAILURES:")
        for fl in failures:
            print(f"  ✗ {fl}")
        return 1
    structure_helped = [r["dataset"] for r in artifact["rows"]
                        if isinstance(r["tot_minus_b2"], (int, float)) and r["tot_minus_b2"] > 0]
    print(
        f"\n[accuracy] PASS (measurement contract): {len(artifact['rows'])} rows. "
        f"ToT search structure beat best-of-{TOT_WIDTH} (ToT−B2 > 0) on: "
        f"{structure_helped or 'none'}. Stochastic (temp>0); deltas advisory."
    )
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
