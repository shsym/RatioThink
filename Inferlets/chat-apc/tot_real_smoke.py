"""Real-model tree-of-thought #437 smoke for chat-apc.

Unlike `e2e_test.py` (dummy driver — fabricated tokens, no real reasoning),
this boots `pie serve` with the production **portable Metal** driver against a
real cached reasoning model (Qwen3), then dispatches a `tree-of-thought`
search (the ticket's breadth 3 / depth 2 / beam_width 2) with thinking ON —
the regression scenario — and checks that the SELECTED answer is a clean
answer, never a `<think>` reasoning trace:

  1. final_answer is non-empty and contains no `<think>`/`</think>` tag;
  2. the selected node is `status:"ok"` with non-empty `content` (an answer),
     and no un-demuxed `<think>` tag in any node's `content` (#437 — the
     `<think>` trace must ride on `reasoning`, demuxed apart from the answer);
  3. no `incomplete` (think-only) node was selected.

Before the fix, the value scorer rated a longer `<think>` trace higher, so
the beam kept a thinking node and final_answer was a (often truncated)
reasoning trace. Verified against Qwen3-0.6B (safetensors + GGUF).

Reuses the boot/teardown helpers from `e2e_test.py`.

Requires: built `Vendor/pie/target/release/pie` (Metal portable, via
`make engine-build`), the prebuilt chat-apc wasm + stamp, and the model in
`~/.cache/huggingface/hub`.

Usage::

    MODEL=Qwen/Qwen3-0.6B uv run --project Vendor/pie/client/python \
        --with httpx python Inferlets/chat-apc/tot_real_smoke.py
"""

import asyncio
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
import e2e_test as h  # boot/teardown helpers + PIE_BIN/WASM_PATH/MANIFEST_PATH

MODEL = os.environ.get("MODEL", "Qwen/Qwen3-0.6B")

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
"""


def _walk(node):
    yield node
    for c in node.get("children", []) or []:
        yield from _walk(c)


async def main() -> int:
    assert h.PIE_BIN.exists(), f"missing pie binary at {h.PIE_BIN}"
    assert h.WASM_PATH.exists(), f"missing wasm at {h.WASM_PATH}"

    with tempfile.TemporaryDirectory(prefix="tot-437-") as tmp:
        tmp = Path(tmp)
        cfg = tmp / "config.toml"
        cfg.write_text(CONFIG_TOML)
        pie_home = tmp / "home"
        pie_home.mkdir()
        env = {**os.environ, "PIE_HOME": str(pie_home), "PIE_SHMEM_NAME": f"/pie_437_{os.getpid()}"}
        proc = subprocess.Popen(
            [str(h.PIE_BIN), "serve", "--config", str(cfg), "--no-auth", "--debug"],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env, bufsize=1,
        )
        try:
            ws_addr, token = await h._parse_handshake(proc, timeout=180)
            print(f"[smoke] engine ws=ws://{ws_addr} token={token[:8]}… model={MODEL}")
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

                payload = {
                    "inferlet": "tree-of-thought",
                    "stream": False,
                    "input": {
                        "messages": [
                            {"role": "user", "content": "How do I learn a new programming language?"}
                        ],
                        "breadth": 3,
                        "depth": 2,
                        "beam_width": 2,
                        "max_tokens_per_node": 256,
                        # thinking defaults true — exercises the reasoning-aware path (#437)
                    },
                }
                async with httpx.AsyncClient(timeout=300) as http:
                    r = await http.post(f"{base}/v1/inferlet", json=payload)
                    print(f"[smoke] POST /v1/inferlet(tree-of-thought) -> {r.status_code}")
                    if r.status_code != 200:
                        print(f"[smoke] body: {r.text[:2000]}")
                        return 1
                    tree = r.json()

                final = tree.get("final_answer")
                sel_id = tree.get("selected_node_id")
                nodes = list(_walk(tree["root"]))
                by_id = {n["id"]: n for n in nodes}

                print("\n[smoke] === node summary ===")
                for n in nodes:
                    if n["status"] == "root":
                        continue
                    has_r = bool(n.get("reasoning"))
                    print(
                        f"  {n['id']} d{n['depth']} status={n['status']} score={n.get('score')} "
                        f"reasoning={'Y' if has_r else '-'} content[:60]={n.get('content','')[:60]!r}"
                    )
                print(f"\n[smoke] selected={sel_id}")
                print(f"[smoke] final_answer[:200]={(final or '')[:200]!r}\n")

                failures = []
                if not final or not final.strip():
                    failures.append("final_answer is empty/null")
                elif "<think>" in final or "</think>" in final:
                    failures.append("final_answer contains a <think> reasoning trace (#437 regression)")
                if sel_id is None:
                    failures.append("selected_node_id is null")
                else:
                    sel = by_id.get(sel_id, {})
                    if sel.get("status") != "ok":
                        failures.append(f"selected node status={sel.get('status')} (expected ok)")
                    if not (sel.get("content") or "").strip():
                        failures.append("selected node has empty content (answer)")
                # Any reasoning the model emitted must live on `reasoning`, not `content`.
                for n in nodes:
                    if "<think>" in (n.get("content") or ""):
                        failures.append(f"node {n['id']} content carries an un-demuxed <think> tag")

                if failures:
                    print("[smoke] FAIL:")
                    for f in failures:
                        print(f"  - {f}")
                    return 1
                print("[smoke] PASS: selected answer is clean (no <think>), think/incomplete nodes pruned.")
                return 0
            finally:
                drain.cancel()
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
