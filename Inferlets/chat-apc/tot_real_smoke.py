#!/usr/bin/env python3
"""Real-model Tree-of-Thought smoke (#523) — gated, NOT in CI.

Boots `pie serve` with the **portable Metal driver** loading the staged
Qwen3-0.6B-Q8_0 GGUF (a reasoning model, so it exercises the `<think>`
strip on the scorer path), installs chat-apc.wasm, and drives real ToT
searches over the planning/decision prompts from the ticket.

For each prompt it records the raw level-1 sibling branches, their
pairwise word-set Jaccard similarity (the diversity evidence), the
per-node scores (scorer evidence — that fix C makes scores PARSE on a
reasoning model instead of degrading to input-order pruning), the
kept/pruned shape, and the final answer.

Assertions (only on the planning prompts, where diverse strategies exist):
  * branches are NOT all near-duplicates — at least one sibling pair is
    below the duplicate threshold, i.e. the search actually branched;
  * the scorer parsed at least one real integer score across the run, so
    pruning is quality-driven rather than silently input-order.

The homepage-illustration clarification prompt additionally hard-asserts
the post-search synthesis: a non-null final_answer, the `synthesized`
flag true (the synthesizer actually ran — a best-leaf fallback no longer
passes silently), and that the answer addresses the clarification. A null
final_answer is attributed to an upstream search failure, not synthesis.

Usage:
    Scripts/run-tot-real-smoke.sh
    # or directly, with the staged model + built pie/wasm in place:
    uv run --project Vendor/pie/client/python --with httpx \
        python Inferlets/chat-apc/tot_real_smoke.py
"""

from __future__ import annotations

import asyncio
import os
import subprocess
import sys
import tempfile
from pathlib import Path

import httpx

# Reuse the engine-launch + WS-install machinery from the dummy-driver
# harness (importing it does NOT run its main(), which is __main__-gated).
sys.path.insert(0, str(Path(__file__).resolve().parent))
import e2e_test as e2e  # noqa: E402
from pie_client import PieClient  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
MODEL_PATH = Path(
    os.environ.get(
        "TOT_SMOKE_MODEL",
        str(ROOT / "test-models" / "Qwen3-0.6B-Q8_0.gguf"),
    )
)

# Portable Metal driver over the local GGUF (hf_repo accepts a single
# .gguf path — see Vendor/pie/server/src/hf.rs).
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
name = "default"
hf_repo = "{MODEL_PATH}"

[model.scheduler]
batch_policy = "adaptive"
request_timeout_secs = 600
default_endowment_pages = 8
admission_oversubscription_factor = 8.0
restore_pause_at_utilization = 0.85

[model.driver]
type = "portable"
device = ["metal"]

[model.driver.options]
"""


def word_set(text: str) -> set[str]:
    out: set[str] = set()
    cur = []
    for ch in text:
        if ch.isalnum():
            cur.append(ch.lower())
        elif cur:
            out.add("".join(cur))
            cur = []
    if cur:
        out.add("".join(cur))
    return out


def jaccard(a: str, b: str) -> float:
    sa, sb = word_set(a), word_set(b)
    if not sa and not sb:
        return 1.0
    union = sa | sb
    return len(sa & sb) / len(union) if union else 1.0


# Mirrors Rust super::diversity::DUP_THRESHOLD.
DUP_THRESHOLD = 0.8

PLANNING_PROMPTS = [
    ("surprise-party", "Plan a surprise party for a close friend."),
    ("weekend-trip", "Help me decide how to plan a 3-day weekend trip with friends."),
    ("learn-language", "What is the best way to start learning a new language this year?"),
    ("side-project", "I want to choose a software side project to build. Help me decide."),
    ("home-office", "How should I set up a productive home office on a limited budget?"),
]

# Scorer-calibration prompt (recorded, not hard-asserted): the winning
# branch should actually clarify, not be a polished generic acknowledgment.
CLARIFY_PROMPT = (
    "On the landing page we say the chat output is just an illustration, but readers "
    "think it is the real product output. Rewrite the explanation so it is clear the "
    "webpage shows an illustration and the real output is more token-heavy and harder "
    "to grasp at a glance."
)


def level1(tree: dict) -> list[dict]:
    return [c for c in tree.get("root", {}).get("children", []) if c.get("depth") == 1]


def pairwise_sims(nodes: list[dict]) -> list[float]:
    texts = [n.get("content", "") for n in nodes if n.get("status") == "ok"]
    sims = []
    for i in range(len(texts)):
        for j in range(i + 1, len(texts)):
            sims.append(jaccard(texts[i], texts[j]))
    return sims


def report(label: str, prompt: str, body: dict) -> tuple[list[float], list[int]]:
    nodes = level1(body)
    sims = pairwise_sims(nodes)
    scores = [n["score"] for n in nodes if isinstance(n.get("score"), int)]
    print(f"\n===== {label} =====")
    print(f"prompt: {prompt}")
    print(f"breadth={body.get('breadth')} depth={body.get('depth')} beam_width={body.get('beam_width')}")
    for i, n in enumerate(nodes):
        c = (n.get("content") or n.get("error") or "").replace("\n", " ")
        print(f"  branch[{i}] status={n.get('status')} score={n.get('score')} "
              f"score_error={n.get('score_error')}")
        print(f"            {c[:200]}")
    if sims:
        print(f"  pairwise Jaccard: min={min(sims):.2f} mean={sum(sims)/len(sims):.2f} max={max(sims):.2f}")
    print(f"  scores parsed: {scores}")
    fa = (body.get("final_answer") or "").replace("\n", " ")
    print(f"  selected={body.get('selected_node_id')} synthesized={body.get('synthesized')} "
          f"final_answer={fa[:240]}")
    return sims, scores


async def run_tot(http: httpx.AsyncClient, base: str, prompt: str, *, breadth, depth, beam_width):
    r = await http.post(
        f"{base}/v1/inferlet",
        json={
            "inferlet": "tree-of-thought",
            "stream": False,
            "input": {
                "messages": [{"role": "user", "content": prompt}],
                "breadth": breadth,
                "depth": depth,
                "beam_width": beam_width,
                "max_tokens_per_node": 220,
                "temperature": 0.85,
                "top_p": 0.95,
            },
        },
    )
    if r.status_code != 200:
        raise RuntimeError(f"ToT request failed {r.status_code}: {r.text[:400]}")
    return r.json()


async def main() -> int:
    assert e2e.PIE_BIN.exists(), f"missing pie binary at {e2e.PIE_BIN} (build: make engine-build)"
    assert e2e.WASM_PATH.exists(), f"missing wasm at {e2e.WASM_PATH} (build: make build-inferlets)"
    assert MODEL_PATH.exists(), f"missing model at {MODEL_PATH} (stage: Scripts/stage-test-model.sh)"

    failures: list[str] = []
    any_score_parsed = False
    branched_prompts = 0

    shmem_base = f"/pie_tot_{os.getpid()}"
    with tempfile.TemporaryDirectory(prefix="tot-smoke-") as tmp:
        tmp = Path(tmp)
        cfg = tmp / "config.toml"
        cfg.write_text(CONFIG_TOML)
        pie_home = tmp / "home"
        pie_home.mkdir()
        env = {**os.environ, "PIE_HOME": str(pie_home), "PIE_SHMEM_NAME": shmem_base}

        proc = subprocess.Popen(
            [str(e2e.PIE_BIN), "serve", "--config", str(cfg), "--no-auth", "--debug"],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env, bufsize=1,
        )
        try:
            ws_addr, token = await e2e._parse_handshake(proc, timeout=180)
            print(f"[smoke] engine ws={ws_addr} token={token[:8]}…")
            drain = asyncio.create_task(e2e._drain_stdout(proc))
            try:
                client = PieClient(f"ws://{ws_addr}")
                await client.connect()
                await client.auth_by_token(token)
                await client.install_program(e2e.WASM_PATH, e2e.MANIFEST_PATH, force_overwrite=True)
                http_port = e2e._free_port()
                base = f"http://127.0.0.1:{http_port}"
                await client.launch_daemon("chat-apc@0.1.0", http_port)
                if not e2e._wait_for_port(http_port, timeout=30):
                    raise RuntimeError(f"daemon never bound port {http_port}")

                quick = os.environ.get("TOT_SMOKE_QUICK") == "1"
                async with httpx.AsyncClient(timeout=600) as http:
                    prompts = PLANNING_PROMPTS[:1] if quick else PLANNING_PROMPTS
                    for label, prompt in prompts:
                        body = await run_tot(http, base, prompt, breadth=5, depth=1, beam_width=5)
                        sims, scores = report(label, prompt, body)
                        if scores:
                            any_score_parsed = True
                        if sims and min(sims) < DUP_THRESHOLD:
                            branched_prompts += 1
                        else:
                            failures.append(
                                f"{label}: all level-1 siblings are near-duplicates "
                                f"(min pairwise Jaccard >= {DUP_THRESHOLD}); search did not branch"
                            )

                    # Scorer-calibration / refinement + final-answer synthesis
                    # evidence (depth 2). The synthesized final answer must
                    # actually address the clarification request (#523 Part A),
                    # not echo a branch fragment or a generic acknowledgment.
                    if not quick:
                        body = await run_tot(http, base, CLARIFY_PROMPT, breadth=4, depth=2, beam_width=2)
                        _, scores = report("homepage-clarification", CLARIFY_PROMPT, body)
                        if scores:
                            any_score_parsed = True
                        # Branch on null FIRST: a null final_answer means no ok
                        # leaf was selected (an upstream SEARCH failure), not a
                        # synthesis failure — attribute it correctly and skip
                        # the answer-shape checks (which would otherwise blame
                        # synthesis). (#523 F2)
                        raw_fa = body.get("final_answer")
                        if raw_fa is None:
                            failures.append(
                                "homepage-clarification: final_answer is null — no leaf selected / "
                                "synthesis skipped (upstream search failure, not a synthesis failure)"
                            )
                        else:
                            # The post-search synthesizer must have actually run
                            # — a best-leaf fallback (synthesized=false) is
                            # typically substantive and on-topic too, so the
                            # shape checks alone can't catch a dead synthesizer
                            # (#523 F1/F2).
                            if not body.get("synthesized"):
                                failures.append(
                                    "homepage-clarification: synthesized=false — the raw best-leaf "
                                    "content stood; the post-search synthesizer did not run"
                                )
                            fa = raw_fa.lower()
                            # Substantive (synthesis produced a real answer)…
                            if len(fa.split()) < 12:
                                failures.append(
                                    f"homepage-clarification final answer too thin ({len(fa.split())} words); "
                                    "synthesis did not produce a complete answer"
                                )
                            # …and on-topic: it addresses the illustration vs
                            # real output, not a generic 'looks good' ack.
                            if not any(k in fa for k in ("illustrat", "token", "real output", "real product", "example")):
                                failures.append(
                                    "homepage-clarification final answer does not address the requested "
                                    f"clarification (illustration / token-heaviness): {fa[:200]!r}"
                                )
            finally:
                drain.cancel()
                with __import__("contextlib").suppress(asyncio.CancelledError, Exception):
                    await drain
        finally:
            e2e._terminate_subprocess(proc, "pie")

    if not any_score_parsed:
        failures.append(
            "scorer parsed zero integer scores across the whole run — value evaluator "
            "degraded to input-order pruning (reasoning strip / score budget regression)"
        )

    print("\n==================== SMOKE RESULT ====================")
    print(f"planning prompts that branched: {branched_prompts}/{len(PLANNING_PROMPTS)}")
    print(f"scorer produced parsed scores: {any_score_parsed}")
    if failures:
        print("RESULT: FAIL")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("RESULT: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
