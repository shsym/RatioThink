"""Tree-of-thought batched-vs-sequential benchmark (#458).

Measures the two #458 execution axes — sibling-generation concurrency
(engine-batched) and scoring phase (phased batch vs coupled overlap) — on
ONE warm portable-Metal `pie serve` loading a real GGUF, so the comparison
is apples-to-apples (same engine, same model, same KV state warmth). It
drives the **non-streaming** `/v1/inferlet` path, where generation can run
concurrently (the streaming path forces sequential generation — a single
SSE emitter can't be shared across concurrent branch futures, #413).

For each (search-shape, strategy) it records wall-clock latency and decode
throughput (tokens/s), reported as the median over N trials.

Two regimes:

  * **greedy** (temperature 0): every strategy generates a byte-identical
    tree (deterministic), so wall-clock is directly comparable and isolates
    scheduling overhead + best-case (perfect-lockstep) batching.
  * **sampled** (temperature 0.7): siblings diverge in length and desync, so
    wall-clock is not comparable across trials — tokens/s is the metric, and
    the phased-vs-coupled gap here is exactly the "does the phase barrier
    cost the gen/score overlap" question (#458 operator concern).

The chosen strategy NEVER changes the returned tree shape/status; only how
it is computed. So a regression in the emitted tree across strategies is a
bug and the bench asserts the deterministic trees match.

Run via `Scripts/run-tot-bench.sh` (stages the GGUF, builds pie+wasm, sets
the env this reads). Requires a portable-Metal `pie` build + the chat-apc
wasm + a staged GGUF (PIE_BENCH_MODEL_PATH / PIE_BENCH_SLUG).
"""
from __future__ import annotations

import asyncio
import os
import statistics
import sys
import time
from pathlib import Path

import httpx

# Shared portable-Metal engine bootstrap (one implementation; #458).
_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))
from _real_engine import real_engine  # noqa: E402

STRATEGIES = [
    "coupled_sequential",   # production default (measured fastest-or-tied)
    "coupled_concurrent",   # isolate generation concurrency
    "phased_sequential",    # isolate the phase barrier + batched scoring
    "phased_concurrent",    # #458 fully-batched target (measured no win)
]

# Representative search shapes. b*d1 is a single wide level (max sibling
# batching, no refine); b3d2 is the default multi-level (exercises the
# concurrent refine-flush + a second batched level).
SHAPES = [
    {"breadth": 4, "depth": 1, "beam_width": 4, "label": "b4·d1·m4 single wide level"},
    {"breadth": 3, "depth": 2, "beam_width": 2, "label": "b3·d2·m2 default multi-level"},
]

TRIALS = int(os.environ.get("PIE_BENCH_TRIALS", "3"))
MAX_TOKENS = int(os.environ.get("PIE_BENCH_MAX_TOKENS", "128"))
QUESTION = os.environ.get(
    "PIE_BENCH_QUESTION",
    "A train leaves city A at 60 mph and another leaves city B at 40 mph "
    "toward each other; the cities are 300 miles apart. Reason step by step, "
    "then give the time until they meet.",
)


def _load_tokenizer():
    """Best-effort real token counter (Qwen3 tokenizer). Falls back to a
    whitespace word proxy if `tokenizers` / the tokenizer.json are absent —
    labeled so the report never passes a proxy off as real tokens."""
    try:
        from huggingface_hub import hf_hub_download
        from tokenizers import Tokenizer

        path = hf_hub_download("Qwen/Qwen3-0.6B", "tokenizer.json")
        tok = Tokenizer.from_file(path)
        return (lambda s: len(tok.encode(s).ids), "tokens")
    except Exception as e:  # noqa: BLE001
        print(f"[bench] tokenizer unavailable ({e}); using word-count proxy", flush=True)
        return (lambda s: len(s.split()), "words(proxy)")


def _count_output(tree: dict, count: "callable") -> int:
    """Total decoded units across every generated node (content + reasoning)."""
    total = 0
    stack = [tree.get("root", {})]
    while stack:
        n = stack.pop()
        if n.get("id") != "root":
            total += count(n.get("content", "")) + count(n.get("reasoning", ""))
        stack.extend(n.get("children", []) or [])
    return total


def _tree_signature(tree: dict) -> list:
    """Order-stable (id, status, content, score) list — identical across
    strategies for a deterministic (greedy) run."""
    out = []
    stack = [tree.get("root", {})]
    while stack:
        n = stack.pop()
        if n.get("id") != "root":
            out.append((n.get("depth"), n.get("branch_index"), n.get("status"),
                        n.get("content"), n.get("score")))
        stack.extend(n.get("children", []) or [])
    out.sort(key=lambda t: (t[0] or 0, t[1] or 0))
    return out


async def _run_one(http: httpx.AsyncClient, base: str, shape: dict,
                   strategy: str, temperature: float) -> dict:
    payload = {
        "inferlet": "tree-of-thought",
        "stream": False,
        "input": {
            "messages": [{"role": "user", "content": QUESTION}],
            "breadth": shape["breadth"],
            "depth": shape["depth"],
            "beam_width": shape["beam_width"],
            "max_tokens_per_node": MAX_TOKENS,
            "temperature": temperature,
            "top_p": 1.0 if temperature == 0.0 else 0.95,
            "thinking": False,
            "exec": strategy,
        },
    }
    t0 = time.monotonic()
    r = await http.post(f"{base}/v1/inferlet", json=payload)
    elapsed = time.monotonic() - t0
    if r.status_code != 200:
        raise RuntimeError(f"{strategy} {shape['label']} -> {r.status_code}: {r.text[:200]}")
    return {"elapsed": elapsed, "tree": r.json()}


async def main() -> int:
    slug = os.environ["PIE_BENCH_SLUG"]
    model_path = os.environ["PIE_BENCH_MODEL_PATH"]
    count, unit = _load_tokenizer()

    async with real_engine(slug, model_path) as base:
        print(f"[bench] engine ready at {base}")
        async with httpx.AsyncClient(timeout=300) as http:
            # Warm-up: one request so the first batched pass / page
            # allocation cost isn't charged to a measured trial.
            await _run_one(http, base, SHAPES[0], "phased_concurrent", 0.0)

            failures: list[str] = []
            for temperature in (0.0, 0.7):
                regime = "greedy(deterministic)" if temperature == 0.0 else "sampled(t=0.7)"
                print(f"\n{'='*70}\nREGIME: {regime}\n{'='*70}")
                for shape in SHAPES:
                    nodes = shape["breadth"] + (shape["depth"] - 1) * shape["beam_width"] * shape["breadth"]
                    print(f"\n-- shape {shape['label']} (nodes≈{nodes}) --")
                    print(f"  {'strategy':22} {'median wall (s)':>16} {f'median {unit}/s':>18} {'speedup':>9}")
                    baseline_wall = None
                    sigs = {}
                    for strat in STRATEGIES:
                        walls, rates = [], []
                        last_tree = None
                        for _ in range(TRIALS):
                            res = await _run_one(http, base, shape, strat, temperature)
                            toks = _count_output(res["tree"], count)
                            walls.append(res["elapsed"])
                            rates.append(toks / res["elapsed"] if res["elapsed"] else 0.0)
                            last_tree = res["tree"]
                        mw = statistics.median(walls)
                        mr = statistics.median(rates)
                        if strat == "coupled_sequential":
                            baseline_wall = mw
                        speedup = (baseline_wall / mw) if baseline_wall and mw else float("nan")
                        print(f"  {strat:22} {mw:16.3f} {mr:18.1f} {speedup:8.2f}x")
                        if temperature == 0.0:
                            sigs[strat] = _tree_signature(last_tree)
                    # Deterministic regime: every strategy must emit the SAME
                    # tree (the knob changes only HOW, never WHAT). A drift is
                    # a correctness bug.
                    if temperature == 0.0 and len(set(map(repr, sigs.values()))) > 1:
                        failures.append(
                            f"tree drift across strategies for {shape['label']}: "
                            f"the exec knob must not change the tree")
            if failures:
                print("\n[bench] FAILURES:")
                for f in failures:
                    print(f"  - {f}")
                return 1
            print("\n[bench] done — deterministic trees identical across all strategies.")
            return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
