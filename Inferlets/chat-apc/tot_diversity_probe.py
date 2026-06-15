"""Level-1 sibling-diversity probe for the tree-of-thought default
temperature — MEASUREMENT, not a test.

Sibling diversity has two sources — per-branch strategy directives
(`search.rs` `strategy_directive`) and sampling temperature; this probe
isolates and measures the TEMPERATURE contribution on a real
portable-Metal engine, instead of assuming it: for each candidate
temperature it runs depth-1 ToT searches (breadth = the production
DEFAULT_BREADTH) over three representative prompts — short factual,
math, open-ended — and reports pairwise similarity metrics across the
sibling answers.

Metrics per (prompt, temperature), computed over all sibling pairs:
  - seqratio  : mean difflib.SequenceMatcher ratio (char-level)
  - jaccard   : mean word-set Jaccard
  - identical : count of byte-identical sibling pairs
  - prefixes  : number of DISTINCT 8-word answer prefixes (breadth
                distinct prefixes = healthy divergence from token one)

Interpretation note baked into the design: factual/math prompts are
EXPECTED to converge on content (one right answer) — what matters there
is phrasing divergence, not contradiction. The open-ended prompt is the
diversity-sensitive case.

Runs `thinking:true` like the production default (the reasoning phase
samples at the same temperature and feeds answer diversity) with the
production reasoning budget — a reduced budget starves Qwen3's
`<think>` phase and fails whole branches (observed: 256 → "every
branch failed to generate" on math/open-ended cells).

Gated like the other real-engine tiers (NOT CI). Run via
`Scripts/run-tot-diversity-probe.sh`, which stages the GGUF, builds
pie + wasm, and sets the env this reads. Each (prompt, temperature)
cell is one engine round-trip; per-repo convention the wrapper tees
output to a `test-YYYYMMDD-HHMMSS-…log`.
"""
from __future__ import annotations

import asyncio
import difflib
import itertools
import os
import sys
from pathlib import Path

import httpx

_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))
from _real_engine import real_engine  # noqa: E402

PROMPTS = {
    "factual": "What is the capital of Australia, and what is it best known for? Answer in two sentences.",
    "math": "A train travels 180 km in 2.5 hours. What is its average speed in km/h? Show your work briefly.",
    "open-ended": "Suggest a name and one-line tagline for a small coffee shop run entirely by robots.",
}

# Production default first, then the candidate raises under evaluation.
DEFAULT_TEMPS = "0.7,1.0,1.3"


def _level1_answers(root: dict) -> list[str]:
    # Wire statuses are "ok" | "incomplete" | "error" (tree.rs). Only
    # clean "ok" answers feed the similarity metrics; the caller logs the
    # answered count so starved branches are visible.
    return [
        (c.get("content") or "").strip()
        for c in (root.get("children") or [])
        if c.get("status") == "ok"
    ]


def _word_jaccard(a: str, b: str) -> float:
    wa, wb = set(a.lower().split()), set(b.lower().split())
    if not wa and not wb:
        return 1.0
    return len(wa & wb) / max(1, len(wa | wb))


def _metrics(answers: list[str]) -> dict:
    pairs = list(itertools.combinations(answers, 2))
    if not pairs:
        return {"seqratio": None, "jaccard": None, "identical": None, "prefixes": None}
    seq = [difflib.SequenceMatcher(None, a, b).ratio() for a, b in pairs]
    jac = [_word_jaccard(a, b) for a, b in pairs]
    identical = sum(1 for a, b in pairs if a == b)
    prefixes = len({" ".join(a.split()[:8]) for a in answers})
    return {
        "seqratio": sum(seq) / len(seq),
        "jaccard": sum(jac) / len(jac),
        "identical": identical,
        "prefixes": prefixes,
    }


async def main() -> int:
    slug = os.environ["PIE_BENCH_SLUG"]
    model_path = os.environ["PIE_BENCH_MODEL_PATH"]
    temps = [float(t) for t in
             os.environ.get("PIE_TEST_TOT_TEMPS", DEFAULT_TEMPS).split(",")]
    breadth = int(os.environ.get("PIE_TEST_TOT_BREADTH", "3"))   # DEFAULT_BREADTH
    maxtok = int(os.environ.get("PIE_TEST_TOT_MAXTOK", "96"))
    maxreason = int(os.environ.get("PIE_TEST_TOT_MAXREASON", "1024"))
    repeats = int(os.environ.get("PIE_TEST_TOT_REPEATS", "2"))

    rows: list[tuple] = []
    errors: list[str] = []
    async with real_engine(slug, model_path) as base:
        print(f"[tot-div] engine ready at {base}; breadth={breadth} "
              f"maxtok={maxtok} maxreason={maxreason} repeats={repeats} temps={temps}")
        async with httpx.AsyncClient(timeout=600) as http:
            for temp in temps:
                for name, prompt in PROMPTS.items():
                    for rep in range(repeats):
                        r = await http.post(
                            f"{base}/v1/inferlet",
                            json={
                                "inferlet": "tree-of-thought",
                                "stream": False,
                                "input": {
                                    "messages": [{"role": "user", "content": prompt}],
                                    "breadth": breadth,
                                    "depth": 1,
                                    "beam_width": 1,
                                    "max_tokens_per_node": maxtok,
                                    "max_reasoning_tokens": maxreason,
                                    "temperature": temp,
                                    "top_p": 0.95,
                                    "thinking": True,
                                },
                            },
                        )
                        if r.status_code != 200:
                            errors.append(f"T={temp} {name}#{rep}: status {r.status_code} "
                                          f"body {r.text[:200]}")
                            continue
                        answers = _level1_answers(r.json().get("root") or {})
                        m = _metrics(answers)
                        rows.append((temp, name, rep, len(answers), m))
                        print(f"[tot-div] T={temp} {name}#{rep}: "
                              f"answered={len(answers)}/{breadth} "
                              f"seqratio={m['seqratio'] and round(m['seqratio'], 3)} "
                              f"jaccard={m['jaccard'] and round(m['jaccard'], 3)} "
                              f"identical={m['identical']} prefixes={m['prefixes']}")
                        for i, a in enumerate(answers):
                            one_line = " ".join(a.split())
                            print(f"[tot-div]   sibling[{i}]: {one_line[:220]}")

    print("\n[tot-div] ===== summary (mean over repeats; lower similarity = more diverse) =====")
    print(f"[tot-div] {'temp':>5} {'prompt':<12} {'seqratio':>9} {'jaccard':>8} "
          f"{'identical':>9} {'prefixes':>9}")
    for temp in temps:
        for name in PROMPTS:
            cell = [m for (t, n, _, _, m) in rows
                    if t == temp and n == name and m["seqratio"] is not None]
            if not cell:
                print(f"[tot-div] {temp:>5} {name:<12} (no scored repeats)")
                continue
            mean = lambda k: sum(c[k] for c in cell) / len(cell)  # noqa: E731
            print(f"[tot-div] {temp:>5} {name:<12} {mean('seqratio'):>9.3f} "
                  f"{mean('jaccard'):>8.3f} {mean('identical'):>9.1f} {mean('prefixes'):>9.1f}")

    if errors:
        print("\n[tot-div] ERRORS:")
        for e in errors:
            print(f"[tot-div]   {e}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
