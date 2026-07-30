"""Does pie reuse KV for identical tokens under a DIFFERENT cache key?

This is the executable statement of the page-level APC gap.

`apc_bench_real.py` measures chat-apc's designed path: seed a key, then send the
same continuation under the SAME key. That hits, and hits well -- 1,655 of 1,688
tokens reused, 6.4x TTFT.

This probe changes exactly one thing: the second request carries a DIFFERENT
`cache.key`, with byte-identical messages. The tokens are the same, so the KV is
the same, so a cache keyed on CONTENT should serve it.

    turn A   key=k1   messages M   -> miss expected (nothing cached yet)
    turn B   key=k2   messages M   -> ???

Today turn B is a full re-prefill, because pie's only prefill-side reuse is
chat-apc's snapshot, and snapshot names are scoped by `directive.key`. pie's
runtime *does* hold a Patricia trie of content-hashed pages
(`runtime/src/context/pagestore.rs`) with `common_prefix_len` matching and
path-inclusive refcounting -- but `prefix_len` and `prefix_match_len` have zero
non-test callers, and `compute_page_hashes` is only called at commit
(`context.rs:1785`), after the forward pass. The trie is never consulted before
prefill.

PASS means turn B reused most of its prefix, i.e. page-level reuse is live.
FAIL means turn B re-prefilled, i.e. reuse is still snapshot-only and any client
that does not reproduce the exact boundary pays full price.

Run against an already-serving pie:

    uv run --project Vendor/pie/client/python --with httpx \\
      python Inferlets/chat-apc/apc_crosskey_probe.py --base-url http://127.0.0.1:PORT
"""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
import uuid
from pathlib import Path

_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

from apc_bench_real import (  # noqa: E402  (path shim above is deliberate)
    _directive,
    parse_sse_frames,
    summarize_stream_frames,
)

# Long enough that a full re-prefill is unmistakable against a reuse, and shaped
# like the agent histories this benchmark exists to measure.
FILLER = (
    "The build system compiles each crate in dependency order, then links the "
    "resulting static archives into a single binary. Incremental rebuilds reuse "
    "the fingerprint cache keyed on the resolved feature set. "
)


def messages(turns: int = 24) -> list[dict[str, str]]:
    out = [{"role": "system", "content": "You are a precise engineering assistant."}]
    for i in range(turns):
        out.append({"role": "user", "content": f"Step {i}: summarise. {FILLER}"})
        out.append({"role": "assistant", "content": f"Acknowledged step {i}. {FILLER}"})
    out.append({"role": "user", "content": "Now give the one-line summary."})
    return out


async def one_turn(http_c, base: str, *, model: str, key: str, msgs: list[dict[str, str]],
                   max_tokens: int) -> dict:
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
        # chat-apc's own names: `appended` is what this turn had to prefill,
        # `base_boundary` is how much of the prefix it reused.
        "appended": diag.get("appended"),
        "reused": diag.get("base_boundary"),
        "output_tokens": summary.output_tokens,
    }


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


async def main_async(args) -> int:
    import os
    import subprocess

    import httpx
    from pie_client import PieClient

    import e2e_test as E
    from apc_bench_real import benchmark_tempdir

    assert E.PIE_BIN.exists(), f"missing pie binary at {E.PIE_BIN}"
    assert E.WASM_PATH.exists(), f"missing wasm at {E.WASM_PATH}"
    E.verify_stamp()

    msgs = messages(args.turns)
    with benchmark_tempdir() as tmp:
        cfg = tmp / "config.toml"
        cfg.write_text(CONFIG_TOML.format(model=args.model))
        pie_home = tmp / "home"
        pie_home.mkdir()
        env = {**os.environ, "PIE_HOME": str(pie_home),
               "PIE_SHMEM_NAME": f"/apc_ck_{os.getpid()}"}
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
                print(f"[crosskey] daemon={base} model={args.model}")

                async with httpx.AsyncClient(timeout=httpx.Timeout(600.0)) as http_c:
                    key_a = f"crosskey-a-{uuid.uuid4().hex[:8]}"
                    key_b = f"crosskey-b-{uuid.uuid4().hex[:8]}"
                    a = await one_turn(http_c, base, model=args.model, key=key_a,
                                       msgs=msgs, max_tokens=args.max_tokens)
                    b = await one_turn(http_c, base, model=args.model, key=key_b,
                                       msgs=msgs, max_tokens=args.max_tokens)
            finally:
                drain.cancel()
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=20)
            except Exception:
                proc.kill()

    print(f"turn A (key={key_a}): {json.dumps(a)}")
    print(f"turn B (key={key_b}): {json.dumps(b)}")

    appended_a = a["appended"] or 0
    appended_b = b["appended"] or 0
    if not appended_a:
        print("INDETERMINATE: turn A reported no appended-token count; nothing is proven.",
              file=sys.stderr)
        return 2

    saved = 1.0 - (appended_b / appended_a) if appended_a else 0.0
    print(f"\nturn B appended {appended_b} of turn A's {appended_a} tokens "
          f"({saved * 100:.1f}% avoided)")
    if saved >= 0.5:
        print("PASS: identical tokens under a different key reused their prefix — "
              "page-level reuse is live.")
        return 0
    print("FAIL: identical tokens under a different key were re-prefilled in full.",
          file=sys.stderr)
    print("      Reuse is snapshot-only: pie's page trie is populated at commit and "
          "never queried before prefill, so any client that does not reproduce the "
          "exact snapshot boundary pays the whole prompt again.", file=sys.stderr)
    return 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--handshake-timeout", type=float, default=600.0)
    parser.add_argument("--model", default="Qwen/Qwen3-0.6B")
    parser.add_argument("--turns", type=int, default=24)
    parser.add_argument("--max-tokens", type=int, default=32)
    return asyncio.run(main_async(parser.parse_args(argv)))


if __name__ == "__main__":
    raise SystemExit(main())
