"""Offline mechanism analysis of a ToT tree dump (#657 gap autopsy).

Reads a ToT tree-dump JSONL (one record per prompt: prompt, reference, grader,
selected, final_answer, nodes[]) and answers WHY a run trails its comparison
baseline — without any engine.

Per prompt it grades EVERY node's content with grade.py (the same oracle) and
classifies, for failures:

  SELECTION/SYNTHESIS LOSS — a correct answer EXISTED in the tree but the final
    (selected/synthesized) answer was wrong. The search found it; the scorer or
    the post-search synthesis dropped it. Fixable in the selection/synthesis.
  GENERATION LOSS — no node in the tree was correct. The decomposition / step
    generation never produced the right reasoning. A harder, model-side gap.

Plus the sub-diagnostics: branch variation (distinct vs near-dup siblings under
the same parent), score spread (does value×N discriminate or saturate?), and
synthesis corruption (selected node correct but synthesized final answer wrong).

Run::

    uv run --with jsonschema python Inferlets/chat-apc/analyze_tree_dump.py tot_tree_dump.jsonl
"""
from __future__ import annotations

import json
import sys
from collections import Counter
from typing import Any

import grade as g


def _passed(grader: str, text: str, ref: dict) -> bool | None:
    try:
        return g.grade(grader, text or "", ref).passed
    except Exception:  # noqa: BLE001  a node may carry junk; treat as ungradable
        return None


def _norm(s: str) -> str:
    return " ".join((s or "").split()).lower()


def answer_key(grader: str, text: str) -> str:
    """Small, shared answer bucketing for branch-coverage histograms."""
    if grader in {"gsm8k_numeric", "mcq_numeric"}:
        tail = g._answer_tail(text or "") if hasattr(g, "_answer_tail") else (text or "")
        got = g.last_number(tail)
        return got if got is not None else "<unparseable>"
    return _norm(text) or "<empty>"


def branch_variation_ratios(nodes: list[dict[str, Any]]) -> list[float]:
    by_sibling_group: dict = {}
    for nd in nodes:
        key = (nd.get("depth"), nd.get("parent_id"))
        by_sibling_group.setdefault(key, []).append(_norm(nd.get("content") or ""))
    return [
        len(set(sibs)) / len(sibs)
        for sibs in by_sibling_group.values()
        if len(sibs) > 1
    ]


def analyze_record(record: dict[str, Any]) -> dict[str, Any]:
    grader, ref = record["grader"], record["reference"]
    nodes = record.get("nodes") or []
    graded = [(_passed(grader, nd.get("content"), ref), nd) for nd in nodes]
    correct_nodes = [nd for ok, nd in graded if ok is True]

    answer_hist: Counter = Counter()
    node_answer_grades: dict[str, dict[str, Any]] = {}
    for ok, nd in graded:
        if nd.get("status", "ok") != "ok":
            continue
        answer = answer_key(grader, nd.get("content") or "")
        answer_hist[answer] += 1
        node_id = nd.get("id")
        if node_id:
            node_answer_grades[node_id] = {
                "answer": answer,
                "passed": ok,
            }

    sel_id = record.get("selected")
    sel_node = next((nd for nd in nodes if nd.get("id") == sel_id), None)
    sel_node_ok = _passed(grader, (sel_node or {}).get("content"), ref) if sel_node else None

    verdict = (record.get("final_verdict") or "").lower()
    loss_kind = None
    if verdict == "fail":
        loss_kind = "selection_synthesis" if correct_nodes else "generation"

    return {
        "correct_in_tree": bool(correct_nodes),
        "selected_node_ok": sel_node_ok,
        "n_correct_nodes": len(correct_nodes),
        "n_nodes": len(nodes),
        "answer_histogram": dict(sorted(answer_hist.items())),
        "node_answer_grades": node_answer_grades,
        "branch_variation_ratios": branch_variation_ratios(nodes),
        "loss_kind": loss_kind,
    }


def analyze(path: str) -> None:
    with open(path) as fh:
        records = [json.loads(line) for line in fh if line.strip()]
    if not records:
        print("empty dump")
        return

    n = len(records)
    passes = fails = n_error = n_ungradable = n_other = 0
    sel_loss = gen_loss = synth_corrupt = 0
    correct_in_tree_count = 0
    score_hist: Counter = Counter()
    dup_ratios: list[float] = []
    per_prompt = []

    for r in records:
        grader, ref = r["grader"], r["reference"]
        nodes = r.get("nodes") or []
        summary = analyze_record(r)
        verdict_raw = r.get("final_verdict")
        verdict = (verdict_raw or "").lower()
        final_ok = verdict == "pass"
        final_fail = verdict == "fail"
        if final_ok:
            passes += 1
        elif final_fail:
            fails += 1
        elif verdict == "err":
            n_error += 1
        elif verdict == "ungradable":
            n_ungradable += 1
        else:
            n_other += 1
        any_correct = summary["correct_in_tree"]
        if any_correct:
            correct_in_tree_count += 1

        # score distribution (saturation check)
        for nd in nodes:
            sc = nd.get("score")
            score_hist[sc if sc is not None else "none"] += 1

        dup_ratios.extend(summary["branch_variation_ratios"])
        sel_node_ok = summary["selected_node_ok"]

        if final_fail:
            if any_correct:
                sel_loss += 1
            else:
                gen_loss += 1
        # synthesis corruption: the SELECTED node was correct but the final
        # (synthesized) answer scored wrong → synthesis turned right into wrong.
        if sel_node_ok is True and final_fail:
            synth_corrupt += 1

        per_prompt.append({
            "index": r.get("index"), "verdict": verdict_raw, "final_ok": final_ok,
            "final_fail": final_fail, "correct_in_tree": any_correct,
            "selected_node_ok": sel_node_ok,
            "n_correct_nodes": summary["n_correct_nodes"], "n_nodes": summary["n_nodes"],
        })

    print(f"=== ToT tree-dump mechanism analysis ({path}) ===")
    print(f"prompts: {n} | final PASS: {passes} | final FAIL: {fails} | "
          f"ERR: {n_error} | ungradable: {n_ungradable} | other: {n_other}")
    print(f"correct answer present somewhere in the tree: {correct_in_tree_count}/{n}")
    print()
    print("FAILURE DECOMPOSITION:")
    print(f"  SELECTION/SYNTHESIS loss (right answer in tree, not chosen): {sel_loss}/{fails}")
    print(f"  GENERATION loss (no correct node anywhere):                  {gen_loss}/{fails}")
    print(f"  synthesis corruption (selected node correct → final wrong):  {synth_corrupt}")
    print()
    avg_dup = sum(dup_ratios) / len(dup_ratios) if dup_ratios else float("nan")
    print(f"branch variation (distinct-sibling ratio, 1.0=all distinct): {avg_dup:.2f} "
          f"over {len(dup_ratios)} sibling-groups")
    print(f"score distribution: {dict(sorted(score_hist.items(), key=lambda x: str(x[0])))}")
    print()
    print("per-prompt (index: final / correct_in_tree / selected_node_ok / #correct_nodes):")
    for p in per_prompt:
        flag = ""
        if p["final_fail"]:
            flag = "  <- SEL-LOSS" if p["correct_in_tree"] else "  <- GEN-LOSS"
        verdict_label = p.get("verdict") or "other"
        if p["final_ok"]:
            verdict_label = "PASS"
        elif p["final_fail"]:
            verdict_label = "FAIL"
        print(f"  {p['index']:>3}: {verdict_label} / "
              f"in_tree={p['correct_in_tree']} / sel_ok={p['selected_node_ok']} / "
              f"{p['n_correct_nodes']}/{p['n_nodes']}{flag}")


if __name__ == "__main__":
    analyze(sys.argv[1] if len(sys.argv) > 1 else "tot_tree_dump.jsonl")
