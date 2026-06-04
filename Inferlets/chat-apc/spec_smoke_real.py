"""Real-model speculative-decoding smoke for chat-apc (#418).

Unlike `e2e_test.py` (dummy driver — non-deterministic, can't show
acceptance), this boots `pie serve` with the production **portable Metal**
driver against a real cached model, then POSTs the SAME greedy
(temperature=0) chat twice — once with `speculation:{enabled:true}` and
once without — and checks:

  1. spec output is TOKEN-IDENTICAL to plain output (greedy equivalence);
  2. the spec run accepted at least one draft token (proves the linear
     Cacheback drafter actually speeds up decode on real text).

Reuses the boot/teardown helpers from `e2e_test.py`.

Requires: built `Vendor/pie/target/release/pie` (Metal portable, via
`make engine-build`), the prebuilt chat-apc wasm + stamp, and a real model
in `~/.cache/huggingface/hub`.

Usage::

    MODEL=Qwen/Qwen3-0.6B uv run --with ./Vendor/pie/client/python \
        python Inferlets/chat-apc/spec_smoke_real.py
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


async def main() -> int:
    assert h.PIE_BIN.exists(), f"missing pie binary at {h.PIE_BIN}"
    assert h.WASM_PATH.exists(), f"missing wasm at {h.WASM_PATH}"
    h.verify_stamp()

    failures: list[str] = []
    with tempfile.TemporaryDirectory(prefix="spec-real-") as tmp:
        tmp = Path(tmp)
        cfg = tmp / "config.toml"
        cfg.write_text(CONFIG_TOML)
        pie_home = tmp / "home"
        pie_home.mkdir()
        env = {**os.environ, "PIE_HOME": str(pie_home), "PIE_SHMEM_NAME": f"/spec_real_{os.getpid()}"}
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

                msg = [{"role": "user", "content": "List the first six prime numbers, comma separated."}]
                body = {"model": MODEL, "messages": msg, "temperature": 0, "max_tokens": 64}
                forced_body = {
                    "model": MODEL,
                    "messages": [{"role": "user", "content": "What is 2+2?"}],
                    "temperature": 0,
                    "max_tokens": 32,
                    "tools": [{
                        "type": "function",
                        "function": {
                            "name": "calculator",
                            "description": "Evaluate an arithmetic expression.",
                            "parameters": {
                                "type": "object",
                                "properties": {"expr": {"type": "string"}},
                                "required": ["expr"],
                            },
                        },
                    }],
                    "tool_choice": "required",
                    "speculation": {"enabled": True},
                }
                async with httpx.AsyncClient(timeout=180) as http_c:
                    r_plain = await http_c.post(f"{base}/v1/chat/completions", json=body)
                    r_spec = await http_c.post(
                        f"{base}/v1/chat/completions",
                        json={**body, "speculation": {"enabled": True}},
                    )
                    forced = await http_c.post(f"{base}/v1/chat/completions", json=forced_body)
                print(f"[smoke] plain -> {r_plain.status_code}; spec -> {r_spec.status_code}")
                if r_plain.status_code != 200 or r_spec.status_code != 200:
                    failures.append(f"non-200: plain={r_plain.status_code} spec={r_spec.status_code} "
                                    f"plain_body={r_plain.text[:300]!r} spec_body={r_spec.text[:300]!r}")
                else:
                    b_plain = json.loads(r_plain.text)
                    b_spec = json.loads(r_spec.text)

                    def _full(msg: dict) -> tuple[str, str]:
                        # Qwen3 is a thinking model: most/all output lands
                        # in `reasoning_content` (inside <think>), not
                        # `content`. Compare BOTH so the equivalence check
                        # exercises the actually-generated tokens, not an
                        # empty visible string.
                        m = msg["choices"][0]["message"]
                        return (m.get("content") or "", m.get("reasoning_content") or "")

                    full_plain = _full(b_plain)
                    full_spec = _full(b_spec)
                    sm = b_spec.get("spec_metrics")
                    print(f"[smoke] plain content/reasoning lens={tuple(len(x) for x in full_plain)}")
                    print(f"[smoke] spec  content/reasoning lens={tuple(len(x) for x in full_spec)}")
                    print(f"[smoke] spec_metrics={sm}")
                    if full_spec != full_plain:
                        failures.append(
                            "greedy equivalence broken: spec != plain "
                            f"(plain={full_plain!r} spec={full_spec!r})"
                        )
                    if sm is None:
                        failures.append("spec_metrics missing")
                    else:
                        if sm["accepted_draft_tokens"] + sm["rejected_draft_tokens"] != sm["proposed_draft_tokens"]:
                            failures.append(f"accounting inconsistent: {sm}")
                        if sm["accepted_draft_tokens"] <= 0:
                            failures.append(f"no draft tokens accepted on real text: {sm}")
                        else:
                            print(f"[smoke] ACCEPTED {sm['accepted_draft_tokens']}/{sm['proposed_draft_tokens']} "
                                  f"draft tokens, avg {sm['avg_tokens_per_step']:.2f} tok/step")

                # #418 x tool_choice: speculation gates OFF when a tool call
                # is FORCED (sampler constrained to the tool-call grammar).
                # The real model has a native tool grammar, so a forced
                # request 200s and returns a tool call; spec_metrics must
                # report enabled=false + fallback_reason=tool_choice_forced.
                # (The request was issued inside the client block above.)
                print(f"[smoke] forced tool + speculation -> {forced.status_code}")
                if forced.status_code != 200:
                    failures.append(
                        f"forced-tool request status {forced.status_code} "
                        f"(want 200): {forced.text[:200]!r}"
                    )
                else:
                    fb = json.loads(forced.text)
                    fsm = fb.get("spec_metrics")
                    tcs = fb["choices"][0].get("finish_reason")
                    tool_calls = fb["choices"][0]["message"].get("tool_calls")
                    print(f"[smoke] forced-tool finish_reason={tcs} tool_calls={bool(tool_calls)} spec_metrics={fsm}")
                    if fsm is None:
                        failures.append("forced-tool: spec_metrics missing")
                    elif fsm.get("enabled") is not False:
                        failures.append(f"forced-tool: speculation NOT gated off: {fsm}")
                    elif fsm.get("fallback_reason") != "tool_choice_forced":
                        failures.append(
                            f"forced-tool: fallback_reason={fsm.get('fallback_reason')!r} "
                            f"(want tool_choice_forced)"
                        )
                    else:
                        print("[smoke] forced-tool gate OK "
                              "(speculation off, fallback_reason=tool_choice_forced)")
            finally:
                drain.cancel()
        finally:
            h._terminate_subprocess(proc, "engine")

    if failures:
        print("\n[smoke] FAILURES:")
        for f in failures:
            print(f"  ✗ {f}")
        return 1
    print("\n[smoke] PASS: greedy equivalence + real draft acceptance")
    return 0


if __name__ == "__main__":
    import sys
    sys.exit(asyncio.run(main()))
