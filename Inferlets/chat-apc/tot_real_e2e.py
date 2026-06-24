"""Real-engine concurrent/phased tree-of-thought e2e (#458).

Asserts that a multi-level `exec:"phased_concurrent"` ToT search — sibling
branches generated concurrently + scoring run as a concurrent phase, the
non-default #458 execution path — completes against a real portable-Metal
`pie serve` loading a real GGUF and returns a well-formed tree with valid
per-node status. This is the correctness proof for the concurrent code path
on real hardware (so the `tot_bench.py` numbers it shares the apparatus with
are trustworthy); dummy-driver coverage (`e2e_test.py`) fabricates outputs
and cannot exercise real decoding.

NOTE: the concurrent/phased path is NOT the production default — measurement
(`make bench-tot`) showed it never beats coupled-sequential and can regress
under KV pressure, so production runs `coupled_sequential`. This test proves
the apparatus is correct, not that it is faster. The production path is
covered by the streaming app-path guard (`run-tot-e2e.sh`) and the dummy e2e.

Complements the streaming app-path guard (sequential generation): this drives
the non-streaming, concurrently-generated path the streaming one can't.

Run via `Scripts/run-tot-batched-e2e.sh` (stages the GGUF, builds pie+wasm,
sets the env this reads).
"""
from __future__ import annotations

import asyncio
import os
import sys
from pathlib import Path

import httpx

_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))
from _real_engine import real_engine  # noqa: E402


def _walk(node: dict) -> list:
    out = [node]
    for c in node.get("children", []) or []:
        out.extend(_walk(c))
    return out


async def main() -> int:
    slug = os.environ["PIE_BENCH_SLUG"]
    model_path = os.environ["PIE_BENCH_MODEL_PATH"]
    bd = int(os.environ.get("PIE_TEST_TOT_BREADTH", "3"))
    dp = int(os.environ.get("PIE_TEST_TOT_DEPTH", "2"))
    bw = int(os.environ.get("PIE_TEST_TOT_BEAM", "2"))
    maxtok = int(os.environ.get("PIE_TEST_TOT_MAXTOK", "96"))

    failures: list[str] = []
    async with real_engine(slug, model_path) as base:
        print(f"[tot-real] engine ready at {base}; running batched ToT "
              f"(b{bd}·d{dp}·m{bw}, exec=phased_concurrent)")
        async with httpx.AsyncClient(timeout=300) as http:
            r = await http.post(
                f"{base}/v1/chat/completions",
                json={
                    "inferlet": "tree-of-thought",
                    "stream": False,
                    "input": {
                        "messages": [{
                            "role": "user",
                            "content": "What is the best way to learn a new programming language? "
                                       "Give a concise, concrete answer.",
                        }],
                        "breadth": bd,
                        "depth": dp,
                        "beam_width": bw,
                        "max_tokens_per_node": maxtok,
                        "temperature": 0.7,
                        "top_p": 0.95,
                        "thinking": False,
                        "exec": "phased_concurrent",
                    },
                },
            )
            print(f"[tot-real] POST /v1/chat/completions -> {r.status_code}")
            if r.status_code != 200:
                # A total failure (every branch failed) returns 500 — that is
                # NOT acceptable for a healthy real engine on this prompt.
                print(f"[tot-real] body: {r.text[:400]}")
                failures.append(f"status {r.status_code} (want 200)")
            else:
                body = r.json()
                if body.get("object") != "tree_of_thought":
                    failures.append(f"object {body.get('object')!r}")
                root = body.get("root") or {}
                if root.get("id") != "root" or root.get("depth") != 0:
                    failures.append(f"root shape {root!r}")
                if (body.get("breadth"), body.get("depth"), body.get("beam_width")) != (bd, dp, bw):
                    failures.append(f"echoed params {body!r}")

                non_root = [n for n in _walk(root) if n.get("id") != "root"]
                # Level 1 forks `breadth`; each kept node forks `breadth` at the
                # next level. With real generation some branches may fail, so
                # the count is bounded above by the full attempt and below by
                # at least the first level.
                want_max = bd + (dp - 1) * bw * bd
                if not (bd <= len(non_root) <= want_max):
                    failures.append(f"node count {len(non_root)} not in [{bd}, {want_max}]")

                ids = {n.get("id") for n in non_root}
                ok_nodes = 0
                for n in non_root:
                    missing = [k for k in ("id", "parent_id", "depth", "branch_index",
                                           "content", "score", "status") if k not in n]
                    if missing:
                        failures.append(f"node missing {missing}: {n!r}")
                    st = n.get("status")
                    if st not in ("ok", "error", "incomplete"):
                        failures.append(f"node status {st!r}")
                    if st == "ok":
                        ok_nodes += 1
                    if not (isinstance(n.get("depth"), int) and 1 <= n["depth"] <= dp):
                        failures.append(f"node depth {n.get('depth')!r}")
                    sc = n.get("score")
                    if sc is not None and not (isinstance(sc, int) and 1 <= sc <= 10):
                        failures.append(f"node score {sc!r}")

                # The batched search must have produced at least one real
                # answer and a coherent terminal selection.
                if ok_nodes == 0:
                    failures.append("no ok nodes — batched search produced no answer")
                sel = body.get("selected_node_id")
                if sel is None or sel not in ids:
                    failures.append(f"selected_node_id {sel!r} not a generated node")
                if not (body.get("final_answer") or "").strip():
                    failures.append("final_answer empty on a successful search")
                if not failures:
                    print(f"[tot-real] OK: {len(non_root)} nodes ({ok_nodes} ok), "
                          f"selected={sel!r}, answer={body.get('final_answer','')[:80]!r}")

    if failures:
        print("\n[tot-real] FAILURES:")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("\n[tot-real] batched real-engine ToT e2e passed.")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
