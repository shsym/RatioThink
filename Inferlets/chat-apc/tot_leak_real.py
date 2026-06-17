"""Real-model regression for the ToT KV-context leak (#679).

The tree-of-thought value-search forks many transient KV contexts per
request — `breadth` children per frontier node, plus a *second* fork per
node for the value rating — and drops the throwaway forks (score forks, beam
losers, spent parents) via Rust `Drop`. The host WIT `drop` handler used to
be a no-op for KV pages ("cleanup deferred to instance teardown"), so within
a single ToT request the dropped forks were never reclaimed. The Active
scheduler can mask a slow trickle by evicting droppable pages, but a HEAVY
tree forks contexts faster than eviction frees them: a new fork's allocation
is deferred waiting for pages that only the not-yet-freed leaked contexts
hold, and the request DEADLOCKS — wedging the engine (the
RemoteProtocol->ConnectError / hang with a healthy driver in #679).

This boots `pie serve` with the production **portable Metal** driver, a real
cached model, and a deliberately TIGHT KV budget, then fires several HEAVY
ToT searches (deep + wide tree) on one daemon instance. With the leak the
first heavy tree exhausts the pool mid-search and the request never returns;
with the fix every dropped fork frees its pages immediately so the live
footprint stays bounded to the active beam and every request completes with
a clean tree. The before/after gap is sharp: unfixed → permanent deadlock
(caught here as a read timeout); fixed → every request returns in seconds.

Reuses the boot/teardown helpers from `e2e_test.py`.

Requires: built `Vendor/pie/target/release/pie` (Metal portable, via
`make engine-build`), the prebuilt chat-apc wasm + stamp, and a real model
in `~/.cache/huggingface/hub`.

Usage::

    MODEL=Qwen/Qwen3-0.6B uv run --with ./Vendor/pie/client/python \
        python Inferlets/chat-apc/tot_leak_real.py
"""
from __future__ import annotations

import asyncio
import json
import os
import subprocess
import tempfile
from pathlib import Path

import httpx
from pie_client import PieClient

import e2e_test as h  # boot/teardown helpers + PIE_BIN/WASM_PATH/MANIFEST_PATH

MODEL = os.environ.get("MODEL", "Qwen/Qwen3-0.6B")

# ── Tunables ─────────────────────────────────────────────────────────────
# `total_pages` × 32 tok = KV token slots, no CPU swap pool. Sized so the
# fixed engine's live working set fits comfortably while still exercising
# genuine KV pressure under thinking-ON generation.
MAX_NUM_KV_PAGES = int(os.environ.get("TOT_LEAK_KV_PAGES", "256"))
CPU_PAGES = int(os.environ.get("TOT_LEAK_CPU_PAGES", "0"))
# The #679 repro config: a thinking-ON tree-of-thought request that forks
# `breadth` children plus a per-node value-scoring fork. Depth=1 matches the
# ticket ("NOT a depth>1 issue"): the crash is the per-generation starvation
# spin, not deep-tree fan-out. Without the fixes the daemon wedges within
# 1-2 requests (forward-pass starvation hang on KV eviction; / a fork-alloc
# deadlock on the leak path); with them every request returns a clean tree.
BREADTH, DEPTH, BEAM = (
    int(os.environ.get("TOT_LEAK_BREADTH", "4")),
    int(os.environ.get("TOT_LEAK_DEPTH", "1")),
    int(os.environ.get("TOT_LEAK_BEAM", "1")),
)
# Long enough that each node's reasoning (Qwen3 thinks by default) occupies
# several KV pages of UNIQUE content (so the request pressures the pool).
MAX_TOKENS_PER_NODE = int(os.environ.get("TOT_LEAK_MAX_TOK", "256"))
# A few back-to-back requests — the ticket crashes "after 1-2 requests".
NUM_REQUESTS = int(os.environ.get("TOT_LEAK_REQUESTS", "3"))

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

[model.driver.options]
total_pages = {MAX_NUM_KV_PAGES}
cpu_pages = {CPU_PAGES}
"""


def _leaves(body: dict) -> list[dict]:
    """Flatten the tree and return its non-root leaf nodes."""
    out: list[dict] = []

    def walk(n: dict) -> None:
        kids = n.get("children") or []
        if not kids and n.get("id") != "root":
            out.append(n)
        for c in kids:
            walk(c)

    walk(body.get("root") or {})
    return out


def _ok_leaves(body: dict) -> list[dict]:
    """Leaves that produced a scorable answer (`status=="ok"`)."""
    return [n for n in _leaves(body) if n.get("status") == "ok"]


def _survived_leaves(body: dict) -> list[dict]:
    """Leaves that did NOT hard-fail: an `ok` answer or a benign budget-
    truncated `incomplete` (`src/tot/tree.rs:26-31`). A branch that reasoned
    but ran out of answer budget is not a leaked-page victim — only Aborted
    (`status=="error"`) / scorer-collapse branches are."""
    return [n for n in _leaves(body) if n.get("status") in ("ok", "incomplete")]


def _node_failures(body: dict) -> list[str]:
    """Collect every node that died — structurally, not by message text.

    A KV-eviction / forward-pass starvation under the leak surfaces two
    ways in the tree (`src/tot/search.rs::classify`): an Aborted node with
    status=="error" (its generation or pre-gen fork failed, always carrying
    `error`), or a non-null `score_error` (the *value-scoring* fork collapsed
    while the node itself stayed "ok"). Matching on substrings like "fork
    failed" missed the decode-failure wording AND the whole scorer-fork half
    of the surface; flag the structure so wording drift can't false-green it.

    `status=="incomplete"` is deliberately NOT a failure: an Incomplete node
    (budget-truncated `<think>`, or a prompt-echo answer) ALSO carries a
    non-null `error`, but it's a benign token-budget outcome — and this
    harness drives long thinking traces on purpose, so Incomplete leaves are
    expected on a healthy engine. Only flag a non-"ok"/"incomplete" status's
    `error` (a future hard-failure variant), never the incomplete one.
    """
    errs: list[str] = []

    def walk(n: dict) -> None:
        nid = n.get("id")
        if nid != "root":
            if n.get("status") not in ("ok", "incomplete") and isinstance(n.get("error"), str):
                errs.append(f"{nid}: status={n.get('status')!r} error={n['error']!r}")
            if isinstance(n.get("score_error"), str):
                errs.append(f"{nid}: score_error={n['score_error']!r}")
        for c in n.get("children") or []:
            walk(c)

    walk(body.get("root") or {})
    return errs


async def main() -> int:
    assert h.PIE_BIN.exists(), f"missing pie binary at {h.PIE_BIN}"
    assert h.WASM_PATH.exists(), f"missing wasm at {h.WASM_PATH}"
    h.verify_stamp()

    failures: list[str] = []
    with tempfile.TemporaryDirectory(prefix="tot-leak-") as tmp:
        tmp = Path(tmp)
        cfg = tmp / "config.toml"
        cfg.write_text(CONFIG_TOML)
        pie_home = tmp / "home"
        pie_home.mkdir()
        env = {**os.environ, "PIE_HOME": str(pie_home), "PIE_SHMEM_NAME": f"/tot_leak_{os.getpid()}"}
        proc = subprocess.Popen(
            [str(h.PIE_BIN), "serve", "--config", str(cfg), "--no-auth", "--debug"],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env, bufsize=1,
        )
        try:
            ws_addr, token = await h._parse_handshake(proc, timeout=120)
            print(f"[tot-leak] engine ws=ws://{ws_addr}  kv_pages={MAX_NUM_KV_PAGES} cpu_pages={CPU_PAGES}")
            drain = asyncio.create_task(h._drain_stdout(proc))
            try:
                client = PieClient(f"ws://{ws_addr}")
                await client.connect()
                await client.auth_by_token(token)
                await client.install_program(h.WASM_PATH, h.MANIFEST_PATH, force_overwrite=True)
                port = h._free_port()
                base = f"http://127.0.0.1:{port}"
                await client.launch_daemon("chat-apc@0.1.0", port)
                if not h._wait_for_port(port, timeout=30):
                    raise RuntimeError(f"daemon never bound port {port}")

                def _payload(i: int) -> dict:
                    # Distinct, genuinely multi-step word problem per request:
                    # (a) committed KV pages don't hash-dedup across requests,
                    # (b) a thinking model produces a LONG <think> trace that
                    #     truncates at `max_tokens_per_node` with no closing
                    #     </think> — the same truncated-reasoning context the
                    #     value-scoring fork then has to carry (#679 was a
                    #     thinking-ON, gsm8k-style crash).
                    a, b, c = 23 + i, 6 + i, 4 + i
                    return {
                        "inferlet": "tree-of-thought",
                        "stream": False,
                        "input": {
                            "messages": [{
                                "role": "user",
                                "content": (
                                    f"A shop sold {a} boxes of pens on Monday and "
                                    f"{b} times as many on Tuesday. Each box holds "
                                    f"{c} pens. On Wednesday they sold {a + b} fewer "
                                    f"pens than Tuesday. How many pens were sold in "
                                    f"total across the three days? Show every step."
                                ),
                            }],
                            "breadth": BREADTH,
                            "depth": DEPTH,
                            "beam_width": BEAM,
                            "max_tokens_per_node": MAX_TOKENS_PER_NODE,
                        },
                    }

                ok_count = 0
                async with httpx.AsyncClient(timeout=280) as http_c:
                    for i in range(1, NUM_REQUESTS + 1):
                        try:
                            r = await http_c.post(f"{base}/v1/inferlet", json=_payload(i))
                        except (httpx.ConnectError, httpx.ReadError, httpx.RemoteProtocolError) as e:
                            failures.append(f"request {i}: engine connection died ({type(e).__name__}: {e})")
                            break
                        except httpx.TimeoutException as e:
                            # A deferred-allocation deadlock: leaked contexts
                            # hold the pages a new fork is waiting on, and
                            # nothing frees them mid-request.
                            failures.append(f"request {i}: timed out ({type(e).__name__}) — likely fork-alloc deadlock")
                            break
                        if r.status_code != 200:
                            failures.append(f"request {i}: status {r.status_code} (want 200): {r.text[:200]!r}")
                            break
                        body = json.loads(r.text)
                        oks = _ok_leaves(body)
                        survived = _survived_leaves(body)
                        ff = _node_failures(body)
                        sel = body.get("selected_node_id")
                        print(f"[tot-leak] req {i}/{NUM_REQUESTS}: ok_leaves={len(oks)} "
                              f"survived={len(survived)}/{BREADTH} node_failures={len(ff)} selected={sel!r}")
                        if ff:
                            failures.append(f"request {i}: {len(ff)} starved/errored nodes: {ff[:3]!r}")
                            break
                        if sel is None:
                            failures.append(f"request {i}: no selection (tree starved): {body!r}")
                            break
                        # Surviving-branch floor: at DEPTH=1 every one of the
                        # BREADTH children must come back without a HARD
                        # failure (ok or benign budget-truncated incomplete).
                        # A thinned tree (e.g. 1/4 materialized under KV
                        # pressure) is the partial-starvation face of #679 —
                        # fail it, don't pass on a single lucky leaf.
                        if DEPTH == 1 and len(survived) != BREADTH:
                            failures.append(f"request {i}: only {len(survived)}/{BREADTH} branches survived "
                                            f"(thinned tree — partial starvation): {body!r}")
                            break
                        ok_count += 1

                # Engine must still be responsive after the burst.
                async with httpx.AsyncClient(timeout=30) as http_c:
                    try:
                        hz = await http_c.get(f"{base}/healthz")
                        print(f"[tot-leak] post-burst /healthz -> {hz.status_code}")
                        if hz.status_code != 200:
                            failures.append(f"post-burst /healthz status {hz.status_code}")
                    except Exception as e:
                        failures.append(f"post-burst /healthz failed (engine wedged): {e}")

                print(f"[tot-leak] {ok_count}/{NUM_REQUESTS} clean ToT requests")
            finally:
                drain.cancel()
        finally:
            h._terminate_subprocess(proc, "engine")
            # SIGKILL / wedge paths (the exact scenario this test provokes)
            # skip the engine's Drop, leaking the POSIX shm region. Unlink
            # it to match e2e_test.py's cleanup (engine appends `_g0`).
            h._shm_unlink_quiet(f"/tot_leak_{os.getpid()}_g0")

    if failures:
        print("\n[tot-leak] FAILURES:")
        for f in failures:
            print(f"  ✗ {f}")
        return 1
    print(f"\n[tot-leak] PASS: {NUM_REQUESTS} back-to-back ToT searches under a tight KV "
          f"budget all returned clean trees (no fork leak)")
    return 0


if __name__ == "__main__":
    import sys
    sys.exit(asyncio.run(main()))
