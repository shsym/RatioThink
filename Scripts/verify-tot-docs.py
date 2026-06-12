#!/usr/bin/env python3
"""Verify the Tree-of-Thought web/docs example describes beam search truthfully."""
from __future__ import annotations

from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
EXAMPLE = ROOT / "Vendor/pie/inferlets/tree-of-thought/src/lib.rs"
DOCS = ROOT / "Vendor/pie/website/docs/guide/examples/reasoning.mdx"
LANDING = ROOT / "docs/landing.html"


def require(text: str, pattern: str, label: str, *, flags: int = 0) -> None:
    if re.search(pattern, text, flags) is None:
        raise AssertionError(f"missing {label}: /{pattern}/")


def forbid(text: str, pattern: str, label: str, *, flags: int = 0) -> None:
    if re.search(pattern, text, flags) is not None:
        raise AssertionError(f"forbidden {label}: /{pattern}/")


def main() -> int:
    example = EXAMPLE.read_text()
    docs = DOCS.read_text()
    landing = LANDING.read_text()
    combined = f"{example}\n\n{docs}\n\n{landing}"

    require(example, r"fn default_breadth\(\) -> usize\s*\{\s*3\s*\}", "default breadth=3")
    require(example, r"fn default_beam_width\(\) -> usize\s*\{\s*2\s*\}", "default beam_width=2")
    require(example, r"score_candidate", "explicit candidate scoring helper")
    require(example, r"select_beam", "global beam selection helper")
    require(example, r"frontier = keep", "next frontier committed from kept candidates")
    require(example, r"Ok\(best\.content\.trim\(\)\.to_string\(\)\)", "direct final answer return")

    require(docs, r"level-wise beam search", "docs say level-wise beam search", flags=re.I)
    require(docs, r"generate 3 candidates", "docs say generate 3 candidates", flags=re.I)
    require(docs, r"score all 3", "docs say score all first-level candidates", flags=re.I)
    require(docs, r"keep(?:s)? the top 2", "docs say keep top 2", flags=re.I)
    require(docs, r"provisional", "docs explain provisional live selection", flags=re.I)
    require(docs, r"commits? the next frontier only after all candidates", "docs explain delayed frontier commit", flags=re.I)
    require(docs, r"direct answer", "docs say final answer is direct", flags=re.I)
    require(docs, r"optional inspection|debug context", "docs put search details behind optional inspection/debug", flags=re.I)

    require(landing, r"bounds:\s*'· 3×2, beam 2 ·'", "landing ToT breadth/top-2 label")
    require(
        landing,
        r"provisionalLoser[\s\S]+setBeam\(provisionalLoser,\s*'pruned'\)[\s\S]+setBeam\(kids\[c2\],\s*'kept'\)",
        "landing ToT animation demotes provisional loser before later top-2 check",
    )
    require(
        landing,
        r"Backyard cookout, ~15 friends',\s*s:\s*7,\s*beam:\s*'pruned'",
        "landing ToT score-7 leaf is finally pruned",
    )
    require(
        landing,
        r"Evening garden theme, ~12 friends',\s*s:\s*9,\s*beam:\s*'star'",
        "landing ToT winning score-9 leaf",
    )
    require(
        landing,
        r"A free Saturday evening',\s*s:\s*8,\s*beam:\s*'kept'",
        "landing ToT score-8 leaf remains in final frontier",
    )
    leaf_beams = [
        (int(score), beam)
        for score, beam in re.findall(r"\{ t: '[^']+',\s*s:\s*(\d+),\s*beam:\s*'(star|kept|pruned)'\s*\}", landing)
    ]
    kept_leaf_scores = sorted(score for score, beam in leaf_beams if beam in {"star", "kept"})
    if kept_leaf_scores != [8, 9]:
        raise AssertionError(f"landing ToT final leaf frontier must be global top-2 [8, 9], got {kept_leaf_scores}")

    forbid(combined, r"All branches are explored", "exhaustive all-branches wording", flags=re.I)
    forbid(combined, r"Leaves=", "leaf-count-first demo framing")
    forbid(combined, r"total_leaves", "exhaustive leaf count variable")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as exc:
        print(exc, file=sys.stderr)
        raise SystemExit(1)
