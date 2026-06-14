#!/usr/bin/env python3
"""Real-model (Metal) tree-of-thought STREAMING probe (#413).

The dummy-driver e2e exercises the streaming frame order/shape, but per the
project lesson "the dummy masks empty/zero-token generation bugs" a real
forward pass is the only thing that proves the streamed nodes carry real
generated content. This boots `pie serve` with the portable/Metal driver +
a real cached GGUF (Qwen3-0.6B-Q8_0), installs chat-apc, streams ONE
tree-of-thought search, and asserts:

  * Content-Type text/event-stream + a `tree_start` opener echoing bounds.
  * Each `node_complete` identifies its node by id (the #407 invariant) and
    is FLAT (no children).
  * At least one OK node carries NON-EMPTY generated content (the
    real-model signal the dummy can't give).
  * Exactly one terminal frame (`tree_complete`), last before `[DONE]`.

Reuses the boot machinery in e2e_test.py (PieClient install + launch). Run:

  uv run --project Vendor/pie/client/python --with httpx \\
    python Inferlets/chat-apc/probe_tot_stream_real.py
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

_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))
import e2e_test as e2e  # boot helpers + paths (reuses its PieClient import)

# Served id (the request omits `model`, so the engine's single registered
# model is used regardless).
MODEL_SLUG = "Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf"


def _resolve_gguf() -> str:
    """Absolute path to the cached Qwen3-0.6B-Q8_0.gguf weight, symlinks
    followed. pie's portable driver takes a LOCAL FILE PATH in `hf_repo`
    (the App's LaunchSpecResolver resolves the slug to this same path); the
    3-seg HF slug is rejected ("expected owner/name")."""
    import glob
    hub = os.environ.get("HF_HUB_CACHE") or os.path.join(
        os.environ.get("HF_HOME", os.path.expanduser("~/.cache/huggingface")), "hub"
    )
    matches = glob.glob(
        os.path.join(hub, "models--Qwen--Qwen3-0.6B-GGUF", "snapshots", "*", "Qwen3-0.6B-Q8_0.gguf")
    )
    if not matches:
        raise SystemExit(
            "[probe] Qwen3-0.6B-Q8_0.gguf not in HF cache. Fetch it:\n"
            "  uv run --with huggingface_hub python -c "
            "\"from huggingface_hub import hf_hub_download as d; "
            "d('Qwen/Qwen3-0.6B-GGUF','Qwen3-0.6B-Q8_0.gguf')\""
        )
    # The snapshot path keeps the `.gguf` name (a symlink into blobs/);
    # pie requires a `.gguf`-suffixed path, so do NOT realpath to the
    # hash-named blob — pie follows the symlink for the bytes itself.
    return matches[0]


def _config() -> str:
    model_ref = _resolve_gguf()
    print(f"[probe] gguf={model_ref}")
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
name = "{MODEL_SLUG}"
hf_repo = "{model_ref}"

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


async def main() -> int:
    assert e2e.PIE_BIN.exists(), f"missing pie binary at {e2e.PIE_BIN}"
    assert e2e.WASM_PATH.exists(), f"missing wasm at {e2e.WASM_PATH}"
    e2e.verify_stamp()

    shmem_base = f"/pie_tot_probe_{os.getpid()}"
    failures: list[str] = []
    with tempfile.TemporaryDirectory(prefix="tot-stream-probe-") as tmp:
        tmp = Path(tmp)
        cfg = tmp / "config.toml"
        cfg.write_text(_config())
        pie_home = tmp / "home"
        pie_home.mkdir()
        env = {**os.environ, "PIE_HOME": str(pie_home), "PIE_SHMEM_NAME": shmem_base}
        proc = subprocess.Popen(
            [str(e2e.PIE_BIN), "serve", "--config", str(cfg), "--no-auth", "--debug"],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env, bufsize=1,
        )
        try:
            ws_addr, token = await e2e._parse_handshake(proc, timeout=120)
            print(f"[probe] engine ws=ws://{ws_addr} token={token[:8]}…")
            drain = asyncio.create_task(e2e._drain_stdout(proc))
            try:
                client = e2e.PieClient(f"ws://{ws_addr}")
                await client.connect()
                await client.auth_by_token(token)
                await client.install_program(e2e.WASM_PATH, e2e.MANIFEST_PATH, force_overwrite=True)
                http_port = e2e._free_port()
                base = f"http://127.0.0.1:{http_port}"
                await client.launch_daemon("chat-apc@0.1.0", http_port)
                if not e2e._wait_for_port(http_port, timeout=30):
                    raise RuntimeError(f"daemon never bound port {http_port}")
                print(f"[probe] daemon on {base}")

                sbd, sdp, sbw = 2, 2, 1
                async with httpx.AsyncClient(timeout=180) as http:
                    r = await http.post(
                        f"{base}/v1/inferlet",
                        json={
                            "inferlet": "tree-of-thought",
                            "stream": True,
                            "input": {
                                "messages": [{"role": "user", "content": "What is 2+2? Answer briefly."}],
                                "breadth": sbd, "depth": sdp, "beam_width": sbw,
                                "max_tokens_per_node": 24,
                            },
                        },
                    )
                    print(f"[probe] POST tot stream -> {r.status_code} ct={r.headers.get('content-type')!r}")
                    if r.status_code != 200:
                        return _fail([f"status {r.status_code}: {r.text[:400]}"])
                    if r.headers.get("content-type", "").split(";", 1)[0] != "text/event-stream":
                        failures.append(f"content-type {r.headers.get('content-type')!r}")

                    events, saw_done = [], False
                    for line in r.text.splitlines():
                        if not line.startswith("data:"):
                            continue
                        payload = line[len("data:"):].strip()
                        if payload == "[DONE]":
                            saw_done = True
                            continue
                        if saw_done:
                            failures.append("frame after [DONE]")
                        events.append(json.loads(payload))

                    kinds = [e.get("event") for e in events]
                    print(f"[probe] frames: {kinds}")
                    if not saw_done:
                        failures.append("missing [DONE]")
                    if not kinds or kinds[0] != "tree_start":
                        failures.append(f"first frame {kinds[:1]} (want tree_start)")
                    elif (events[0].get("breadth"), events[0].get("depth"), events[0].get("beam_width")) != (sbd, sdp, sbw):
                        failures.append(f"tree_start bounds {events[0]!r}")

                    node_ids, ok_with_content = set(), 0
                    for e in events:
                        if e.get("event") != "node_complete":
                            continue
                        node = e.get("node") or {}
                        nid = node.get("id")
                        if not isinstance(nid, str) or not nid:
                            failures.append(f"node_complete missing id: {e!r}")
                        else:
                            node_ids.add(nid)
                        if "children" in node:
                            failures.append(f"node_complete carries children: {nid}")
                        if node.get("status") == "ok" and (node.get("content") or "").strip():
                            ok_with_content += 1
                    # The real-model signal the dummy cannot give.
                    if ok_with_content == 0:
                        failures.append("no OK node carried non-empty generated content (real-model regression?)")

                    terminals = [i for i, k in enumerate(kinds) if k in ("tree_complete", "error")]
                    if len(terminals) != 1:
                        failures.append(f"terminal frames {[kinds[i] for i in terminals]} (want exactly one)")
                    elif terminals[0] != len(kinds) - 1:
                        failures.append(f"frame(s) after terminal: {kinds[terminals[0]:]!r}")
                    else:
                        term = events[terminals[0]]
                        if term.get("event") == "tree_complete":
                            print(f"[probe] selected={term.get('selected_node_id')!r} "
                                  f"final_answer={(term.get('final_answer') or '')[:80]!r} "
                                  f"ok_nodes_with_content={ok_with_content}")
                            sel = term.get("selected_node_id")
                            if sel is not None and sel not in node_ids:
                                failures.append(f"selected_node_id {sel!r} not streamed")
            finally:
                drain.cancel()
        finally:
            e2e._terminate_subprocess(proc, "pie")
            e2e._shm_unlink_quiet(f"{shmem_base}_g0")

    return _fail(failures) if failures else _ok()


def _fail(failures: list[str]) -> int:
    print("\n[probe] FAIL:")
    for f in failures:
        print(f"  - {f}")
    return 1


def _ok() -> int:
    print("\n[probe] PASS — real-model ToT stream frames valid, nodes carry real content")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
