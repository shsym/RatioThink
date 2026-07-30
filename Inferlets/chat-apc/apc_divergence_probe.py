"""Does chat-apc still reuse when the client resends DIFFERENT assistant text?

This is the acceptance test for the boundary-ladder fix, and it is a different
question from `apc_crosskey_probe.py`:

  crosskey    same tokens, DIFFERENT cache key  -> cannot pass without dropping
                                                   the deliberate per-chat
                                                   isolation invariant
  divergence  SAME cache key, DIFFERENT assistant text  <- this file

Why it matters. chat-apc saves its snapshot under
`hash(prompt_no_cue ‖ assistant(<what pie generated>))` and looks up
`hash(messages[..last])`. A hit therefore requires the client to echo pie's own
words back verbatim. Anything else forfeits the whole snapshot, because the name
covers the entire boundary with no partial-prefix fallback:

  * a trace replay, which resends the originally captured assistant turn
  * a UI that strips `<think>` reasoning before resending
  * an edited or regenerated turn
  * a tool result that differs by a byte

Protocol:

  turn 1   history H                                  -> generation G (miss, cold)
  turn 2   history H + [assistant: NOT G] + [user: q] -> ???

Stock chat-apc: `miss`, full re-prefill of the whole history.
With the ladder: `hit_ladder` on the H boundary, appending only the tail.

PASS requires turn 2 to reuse most of the prefix.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import subprocess
import sys
import uuid
from pathlib import Path

_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

from apc_bench_real import _directive, benchmark_tempdir, parse_sse_frames, summarize_stream_frames  # noqa: E402

FILLER = (
    "The scheduler admits requests in bid order, then reserves working pages for "
    "the prefill batch before the forward pass is dispatched to the driver. "
)

CONFIG_TOML = """
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
name = "{model}"
hf_repo = "{model}"

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


def history(turns: int) -> list[dict[str, str]]:
    out = [{"role": "system", "content": "You are a precise engineering assistant."}]
    for i in range(turns):
        out.append({"role": "user", "content": f"Step {i}: summarise. {FILLER}"})
        out.append({"role": "assistant", "content": f"Acknowledged step {i}. {FILLER}"})
    out.append({"role": "user", "content": "Give the one-line summary."})
    return out


async def turn(http_c, base: str, *, model: str, key: str, msgs, max_tokens: int) -> dict:
    payload = {
        "model": model,
        "messages": msgs,
        "max_tokens": max_tokens,
        "temperature": 0.0,
        "stream": True,
        "stream_options": {"include_usage": True},
        "cache": _directive(key, len(msgs)),
    }
    async with http_c.stream("POST", f"{base}/v1/chat/completions", json=payload,
                             timeout=600.0) as response:
        response.raise_for_status()
        chunks = [line async for line in response.aiter_lines()]
    summary = summarize_stream_frames(parse_sse_frames(chunks))
    diag = summary.cache_diag or {}
    return {
        "outcome": diag.get("outcome"),
        "appended": diag.get("appended"),
        "reused": diag.get("base_boundary"),
        "content": summary.content,
    }


async def main_async(args) -> int:
    import httpx
    from pie_client import PieClient

    import e2e_test as E

    assert E.PIE_BIN.exists(), f"missing pie binary at {E.PIE_BIN}"
    assert E.WASM_PATH.exists(), f"missing wasm at {E.WASM_PATH}"
    E.verify_stamp()

    base_history = history(args.turns)
    key = f"divergence-{uuid.uuid4().hex[:8]}"

    with benchmark_tempdir() as tmp:
        cfg = tmp / "config.toml"
        cfg.write_text(CONFIG_TOML.format(model=args.model))
        pie_home = tmp / "home"
        pie_home.mkdir()
        env = {**os.environ, "PIE_HOME": str(pie_home),
               "PIE_SHMEM_NAME": f"/apc_dv_{os.getpid()}"}
        proc = subprocess.Popen(
            [str(E.PIE_BIN), "serve", "--config", str(cfg), "--no-auth", "--debug"],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env, bufsize=1,
        )
        try:
            ws_addr, token = await E._parse_handshake(proc, timeout=args.handshake_timeout)
            drain = asyncio.create_task(E._drain_stdout(proc))
            try:
                client = PieClient(f"ws://{ws_addr}")
                await client.connect()
                await client.auth_by_token(token)
                await client.install_program(E.WASM_PATH, E.MANIFEST_PATH, force_overwrite=True)
                port = E._free_port()
                base = f"http://127.0.0.1:{port}"
                await client.launch_daemon("chat-apc@0.1.0", port)
                if not E._wait_for_port(port, timeout=30):
                    raise RuntimeError(f"daemon never bound port {port}")
                print(f"[divergence] daemon={base} model={args.model}")

                async with httpx.AsyncClient(timeout=httpx.Timeout(600.0)) as http_c:
                    t1 = await turn(http_c, base, model=args.model, key=key,
                                    msgs=base_history, max_tokens=args.max_tokens)
                    # Resend something the engine did NOT say. This is what a
                    # replay, a reasoning-stripping UI, or an edited turn does.
                    diverged = base_history + [
                        {"role": "assistant",
                         "content": "A completely different answer than the model produced."},
                        {"role": "user", "content": "And now the follow-up question."},
                    ]
                    t2 = await turn(http_c, base, model=args.model, key=key,
                                    msgs=diverged, max_tokens=args.max_tokens)
            finally:
                drain.cancel()
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=20)
            except Exception:
                proc.kill()

    print(f"turn 1 (cold):      {json.dumps({k: v for k, v in t1.items() if k != 'content'})}")
    print(f"turn 2 (diverged):  {json.dumps({k: v for k, v in t2.items() if k != 'content'})}")

    appended_1 = t1["appended"] or 0
    appended_2 = t2["appended"] or 0
    if not appended_1:
        print("INDETERMINATE: turn 1 reported no appended-token count.", file=sys.stderr)
        return 2

    reuse = (t2["reused"] or 0) / appended_1 if appended_1 else 0.0
    print(f"\nturn 2 outcome={t2['outcome']!r} reused={t2['reused']} of turn 1's "
          f"{appended_1} tokens ({reuse * 100:.1f}%), appended {appended_2}")
    if reuse >= 0.5:
        print("PASS: divergent assistant text still reused the earlier boundary.")
        return 0
    print("FAIL: divergent assistant text forfeited the whole prefix.", file=sys.stderr)
    print("      chat-apc names its snapshot after the text IT generated, so a client "
          "that resends anything else re-prefills the entire history.", file=sys.stderr)
    return 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", default="Qwen/Qwen3-0.6B")
    parser.add_argument("--turns", type=int, default=24)
    parser.add_argument("--max-tokens", type=int, default=32)
    parser.add_argument("--handshake-timeout", type=float, default=600.0)
    return asyncio.run(main_async(parser.parse_args(argv)))


if __name__ == "__main__":
    raise SystemExit(main())
