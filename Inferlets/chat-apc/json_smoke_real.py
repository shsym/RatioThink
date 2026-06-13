"""Real-model JSON Think smoke for chat-apc (#572).

Unlike `e2e_test.py` (dummy driver — random-within-mask sampling can only
prove grammar ENGAGEMENT, not parse-validity of a complete value), this
boots `pie serve` with the production **portable Metal** driver against a
real cached model, sends a `response_format: {"type":"json_object"}`
request, and proves the FAITHFUL end-to-end contract:

  * the visible `content` is a COMPLETE, parseable JSON value,
  * a thinking model's reasoning lands in `reasoning_content`, never in
    `content` (no `<think>`/`</think>` leak),
  * the same holds on the streaming path.

Requires: built `Vendor/pie/target/release/pie` (Metal portable, via
`make engine-build`), the prebuilt chat-apc wasm + stamp, and a real model
in the HF cache (default Qwen/Qwen3-0.6B — a thinking model).

Usage::

    uv run --project Vendor/pie/client/python --with httpx \\
        python Inferlets/chat-apc/json_smoke_real.py

Opt-in (NOT in CI): needs real weights + Metal. This is the final
verification the dummy tier cannot give.
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

PROMPT = (
    "Return a JSON object describing the first three prime numbers. "
    "Use the key \"primes\" with an array of integers."
)


_JSON_START = set('{["-0123456789tfn')


def _check_json_content(label: str, content: str, reasoning: str, failures: list[str],
                        require_parse: bool = True) -> None:
    print(f"[smoke] {label}: content={content!r}")
    print(f"[smoke] {label}: reasoning_len={len(reasoning)}")
    if "<think>" in content or "</think>" in content:
        failures.append(f"{label}: reasoning delimiter leaked into content: {content!r}")
    stripped = content.lstrip()
    if not stripped:
        failures.append(f"{label}: empty content (expected a JSON value)")
        return
    if stripped[0] not in _JSON_START:
        failures.append(f"{label}: content does not begin with a JSON value: {content!r}")
    if not require_parse:
        return
    try:
        parsed = json.loads(content)
        print(f"[smoke] {label}: parsed JSON OK -> {parsed!r}")
    except json.JSONDecodeError as e:
        failures.append(f"{label}: content is not valid JSON: {content!r} ({e})")


async def main() -> int:
    assert h.PIE_BIN.exists(), f"missing pie binary at {h.PIE_BIN}"
    assert h.WASM_PATH.exists(), f"missing wasm at {h.WASM_PATH}"
    h.verify_stamp()

    failures: list[str] = []
    with tempfile.TemporaryDirectory(prefix="json-real-") as tmp:
        tmp = Path(tmp)
        cfg = tmp / "config.toml"
        cfg.write_text(CONFIG_TOML)
        pie_home = tmp / "home"
        pie_home.mkdir()
        env = {**os.environ, "PIE_HOME": str(pie_home), "PIE_SHMEM_NAME": f"/json_real_{os.getpid()}"}
        proc = subprocess.Popen(
            [str(h.PIE_BIN), "serve", "--config", str(cfg), "--no-auth", "--debug"],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env, bufsize=1,
        )
        try:
            ws_addr, token = await h._parse_handshake(proc, timeout=120)
            print(f"[smoke] engine ws=ws://{ws_addr}")
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

                body = {
                    "model": MODEL,
                    "messages": [{"role": "user", "content": PROMPT}],
                    "max_tokens": 512,
                    "response_format": {"type": "json_object"},
                }
                async with httpx.AsyncClient(timeout=300) as http_c:
                    # Non-streaming.
                    r = await http_c.post(f"{base}/v1/chat/completions", json={**body, "stream": False})
                    print(f"[smoke] non-stream -> {r.status_code}")
                    if r.status_code != 200:
                        failures.append(f"non-stream status {r.status_code}: {r.text[:300]!r}")
                    else:
                        b = json.loads(r.text)
                        m = b["choices"][0]["message"]
                        _check_json_content(
                            "non-stream", m.get("content") or "", m.get("reasoning_content") or "", failures)

                    # Streaming: concatenate content deltas; reasoning deltas
                    # ride `reasoning_content` and must never appear as content.
                    r = await http_c.post(f"{base}/v1/chat/completions", json={**body, "stream": True})
                    print(f"[smoke] stream -> {r.status_code}")
                    if r.status_code != 200:
                        failures.append(f"stream status {r.status_code}: {r.text[:300]!r}")
                    else:
                        content = ""
                        reasoning = ""
                        for line in r.text.splitlines():
                            if not line.startswith("data: "):
                                continue
                            payload = line[len("data: "):]
                            if payload == "[DONE]":
                                continue
                            obj = json.loads(payload)
                            if obj.get("object") != "chat.completion.chunk":
                                continue
                            delta = obj["choices"][0].get("delta", {})
                            if delta.get("content"):
                                content += delta["content"]
                            if delta.get("reasoning_content"):
                                reasoning += delta["reasoning_content"]
                        _check_json_content("stream", content, reasoning, failures)

                    # Phase-1 mid-<think> truncation regression (#572): a tiny
                    # token budget means a thinking model NEVER reaches </think>
                    # in phase 1 — it hits the cap mid-block, so the reasoning
                    # gate is still latched entering phase 2. Phase 2 must STILL
                    # emit JSON content (raw_content), not silently swallow it as
                    # reasoning. Content is expected to truncate (finish=length),
                    # so we assert non-empty + begins-with-JSON-value, not parse.
                    r = await http_c.post(f"{base}/v1/chat/completions", json={
                        "model": MODEL,
                        "messages": [{"role": "user", "content": PROMPT}],
                        "max_tokens": 16,
                        "response_format": {"type": "json_object"},
                        "stream": False,
                    })
                    print(f"[smoke] tiny-budget non-stream -> {r.status_code}")
                    if r.status_code != 200:
                        failures.append(f"tiny-budget status {r.status_code}: {r.text[:300]!r}")
                    else:
                        m = json.loads(r.text)["choices"][0]["message"]
                        _check_json_content(
                            "tiny-budget", m.get("content") or "", m.get("reasoning_content") or "",
                            failures, require_parse=False)
            finally:
                drain.cancel()
        finally:
            h._terminate_subprocess(proc, "engine")

    if failures:
        print("\n[smoke] FAILURES:")
        for f in failures:
            print(f"  ✗ {f}")
        return 1
    print("\n[smoke] PASS: real-model JSON Think content parses + reasoning stays out of content")
    return 0


if __name__ == "__main__":
    import sys

    sys.exit(asyncio.run(main()))
