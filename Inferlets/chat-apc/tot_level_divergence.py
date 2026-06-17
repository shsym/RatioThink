"""Per-level tree-of-thought sibling-divergence evidence (#683) on real
public datasets — MEASUREMENT, not a test.

Answers ticket #683 point 3 ("run gsm8k + humaneval; record per-level
divergence") and cross-checks the in-engine `[chat-apc] tot diversity:`
log line added in `search.rs::log_level_divergence`. Where
`tot_diversity_probe.py` sweeps temperature at level 1 over three synthetic
prompts, this drives the PRODUCTION default search shape (breadth 3, depth 2,
beam 2, thinking on, temp 0.7) over the pinned gsm8k + humaneval prompt sets
and reports divergence at EACH level.

Divergence is measured per sibling group (a parent's forked children — the
`breadth` branches the ticket asks about), then aggregated per (dataset,
level). Higher = more diverse. Metrics per group, mean-aggregated:
  - divergence : 1 - mean pairwise word-set Jaccard (0 = collapsed, 1 = disjoint)
  - max_sim    : max pairwise Jaccard (the closest sibling pair; high = a
                 near-duplicate hiding in the group)
  - identical  : count of byte-identical sibling pairs (hard collapse)
  - distinct   : mean distinct 8-word opening prefixes / group size
                 (1.0 = every sibling opens differently)

Only `status == "ok"` siblings feed the metrics (error/incomplete branches
carry no answer); the answered count is reported so starved groups are
visible. Reuses the pinned `Scripts/benchmark/data/<key>.jsonl` prompt sets
(reproducible, sha256-locked via prep_datasets); fails loud with the exact
prep command when a set is absent.

Gated like the other real-engine tiers (NOT CI). Run via
`Scripts/run-tot-level-divergence.sh`, which stages the GGUF, builds pie +
wasm, and sets the env this reads.
"""
from __future__ import annotations

import asyncio
import itertools
import json
import os
import sys
from pathlib import Path

import httpx

_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))
from _real_engine import real_engine  # noqa: E402

DATA_DIR = _HERE.parent.parent / "Scripts" / "benchmark" / "data"

# gsm8k = numeric word problems (one right answer → content converges, phrasing
# should still diverge); humaneval = code completion (structure converges,
# approach should diverge). Both are the ticket's named datasets.
DEFAULT_DATASETS = "gsm8k,humaneval"
# Per-dataset prompt cap — divergence is a distributional signal, a handful of
# prompts is plenty and keeps the seated Metal run bounded.
MAX_PROMPTS = int(os.environ.get("PIE_TEST_TOT_MAX_PROMPTS", "4"))


def _load_prompts(key: str) -> list[dict]:
    path = DATA_DIR / f"{key}.jsonl"
    if not path.exists():
        raise SystemExit(
            f"missing prompt set {path} — run Scripts/benchmark/prep_{key}.sh first"
        )
    records = [json.loads(line) for line in path.read_text().splitlines() if line]
    return records[:MAX_PROMPTS] if MAX_PROMPTS > 0 else records


def _word_jaccard(a: str, b: str) -> float:
    wa, wb = set(a.lower().split()), set(b.lower().split())
    if not wa and not wb:
        return 1.0
    return len(wa & wb) / max(1, len(wa | wb))


def _group_metrics(answers: list[str]) -> dict | None:
    """Divergence over one sibling group's ok answers. None when < 2 answers
    (no pair to compare)."""
    pairs = list(itertools.combinations(answers, 2))
    if not pairs:
        return None
    sims = [_word_jaccard(a, b) for a, b in pairs]
    mean_sim = sum(sims) / len(sims)
    identical = sum(1 for a, b in pairs if a == b)
    distinct = len({" ".join(a.split()[:8]) for a in answers})
    return {
        "n": len(answers),
        "divergence": 1.0 - mean_sim,
        "max_sim": max(sims),
        "identical": identical,
        "distinct_frac": distinct / len(answers),
    }


def _groups_by_level(root: dict) -> dict[int, list[list[str]]]:
    """Map child-depth → list of sibling groups at that level. A group's level
    is its members' depth (parent.depth + 1)."""
    by_level: dict[int, list[list[str]]] = {}

    def walk(node: dict) -> None:
        children = node.get("children") or []
        ok = [
            (c.get("content") or "").strip()
            for c in children
            if c.get("status") == "ok"
        ]
        if children:
            level = (children[0].get("depth") or (node.get("depth", 0) + 1))
            if ok:
                by_level.setdefault(level, []).append(ok)
        for c in children:
            walk(c)

    walk(root)
    return by_level


async def main() -> int:
    slug = os.environ["PIE_BENCH_SLUG"]
    model_path = os.environ["PIE_BENCH_MODEL_PATH"]
    datasets = [d.strip() for d in
                os.environ.get("DATASETS", DEFAULT_DATASETS).split(",") if d.strip()]
    breadth = int(os.environ.get("PIE_TEST_TOT_BREADTH", "3"))
    depth = int(os.environ.get("PIE_TEST_TOT_DEPTH", "2"))
    beam = int(os.environ.get("PIE_TEST_TOT_BEAM", "2"))
    temp = float(os.environ.get("PIE_TEST_TOT_TEMP", "0.7"))
    maxtok = int(os.environ.get("PIE_TEST_TOT_MAXTOK", "96"))
    maxreason = int(os.environ.get("PIE_TEST_TOT_MAXREASON", "1024"))
    # #693c cross-sibling logit penalty (0 = off). When > 0 the group generates
    # sequentially so each explorer down-biases earlier siblings' tokens.
    sibling_penalty = float(os.environ.get("PIE_TEST_TOT_SIBLING_PENALTY", "0"))

    # (dataset, level) -> list of per-group metric dicts.
    agg: dict[tuple[str, int], list[dict]] = {}
    errors: list[str] = []

    async with real_engine(slug, model_path) as base:
        print(f"[tot-lvl] engine ready at {base}; datasets={datasets} "
              f"breadth={breadth} depth={depth} beam={beam} temp={temp} "
              f"maxtok={maxtok} maxreason={maxreason} "
              f"sibling_penalty={sibling_penalty} max_prompts={MAX_PROMPTS}")
        async with httpx.AsyncClient(timeout=900) as http:
            for ds in datasets:
                records = _load_prompts(ds)
                print(f"[tot-lvl] {ds}: {len(records)} prompts")
                for rec in records:
                    prompt = rec["prompt"]
                    rid = rec.get("id", "?")
                    r = await http.post(
                        f"{base}/v1/inferlet",
                        json={
                            "inferlet": "tree-of-thought",
                            "stream": False,
                            "input": {
                                "messages": [{"role": "user", "content": prompt}],
                                "breadth": breadth,
                                "depth": depth,
                                "beam_width": beam,
                                "max_tokens_per_node": maxtok,
                                "max_reasoning_tokens": maxreason,
                                "temperature": temp,
                                "top_p": 0.95,
                                "thinking": True,
                                "sibling_penalty": sibling_penalty,
                            },
                        },
                    )
                    if r.status_code != 200:
                        errors.append(f"{ds} id={rid}: status {r.status_code} "
                                      f"body {r.text[:200]}")
                        continue
                    root = r.json().get("root") or {}
                    by_level = _groups_by_level(root)
                    for level, groups in sorted(by_level.items()):
                        for g in groups:
                            m = _group_metrics(g)
                            if m is not None:
                                agg.setdefault((ds, level), []).append(m)
                        n_groups = len(groups)
                        scored = [m for g in groups if (m := _group_metrics(g))]
                        if scored:
                            div = sum(m["divergence"] for m in scored) / len(scored)
                            print(f"[tot-lvl]   {ds} id={rid} level={level}: "
                                  f"groups={n_groups} mean_divergence={div:.3f}")

    print("\n[tot-lvl] ===== summary (mean over groups; HIGHER divergence = more diverse) =====")
    print(f"[tot-lvl] {'dataset':<10} {'level':>5} {'groups':>6} {'divergence':>10} "
          f"{'max_sim':>8} {'identical':>9} {'distinct':>8}")
    for (ds, level) in sorted(agg.keys()):
        cell = agg[(ds, level)]
        mean = lambda k: sum(c[k] for c in cell) / len(cell)  # noqa: E731
        print(f"[tot-lvl] {ds:<10} {level:>5} {len(cell):>6} {mean('divergence'):>10.3f} "
              f"{mean('max_sim'):>8.3f} {mean('identical'):>9.2f} {mean('distinct_frac'):>8.2f}")

    if errors:
        print("\n[tot-lvl] ERRORS:")
        for e in errors:
            print(f"[tot-lvl]   {e}")
        return 1
    if not agg:
        print("[tot-lvl] FATAL: no scored sibling groups — every branch failed?")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
