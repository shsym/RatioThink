"""Best-of-N regenerate probe: run a round, then re-send the SAME round.

Reported symptom: the first Best-of-N send succeeds, and hitting regenerate
("Retry from here") fails with `ToTStreamError` after generating for a while,
sometimes preceded by "candidate KV could not be saved for resume".

Regenerate re-sends the identical messages under the identical cache key, which
is the one shape none of the existing harnesses cover: `bestofn_real_smoke.py`
goes round1 -> think-more (a *different*, deeper request), never round1 twice.
It also means every snapshot the first attempt saved already exists when the
second attempt tries to save it -- an "already exists" path that only a repeat
of the same request can reach.

Exit 0 = both attempts produced N saved candidates.
Exit 1 = the second attempt lost candidates or failed. That is the bug.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import subprocess
import sys
from pathlib import Path

_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

import bestofn_real_smoke as S  # noqa: E402  (path shim above is deliberate)
from apc_bench_real import benchmark_tempdir  # noqa: E402


async def one_round(http, base: str, payload: dict, label: str) -> dict:
    """Run a round; return {ok, candidates, saved, error}."""
    try:
        r = await S.run_round(http, base, payload)
    except Exception as exc:  # noqa: BLE001 - the failure text is the finding
        return {"ok": False, "candidates": 0, "saved": 0, "error": f"{type(exc).__name__}: {exc}"}
    cands = r.candidates or []
    saved = [c for c in cands if c.get("snapshot_name")]
    errs = list(r.errors.values())
    statuses = sorted(set(r.statuses.values()))
    print(f"  [{label}] candidates={len(cands)} saved={len(saved)} "
          f"statuses={statuses} errors={errs or None} stream_error={r.error}")
    return {"ok": not errs and r.error is None and len(saved) > 0,
            "candidates": len(cands), "saved": len(saved),
            "error": (errs[0] if errs else (json.dumps(r.error) if r.error else None))}


async def main_async(args) -> int:
    import httpx
    from pie_client import PieClient

    import e2e_test as E

    assert E.PIE_BIN.exists(), f"missing pie binary at {E.PIE_BIN}"
    assert E.WASM_PATH.exists(), f"missing wasm at {E.WASM_PATH}"
    E.verify_stamp()

    with benchmark_tempdir() as tmp:
        cfg = tmp / "config.toml"
        cfg.write_text(S.CONFIG_TOML)
        pie_home = tmp / "home"
        pie_home.mkdir()
        env = {**os.environ, "PIE_HOME": str(pie_home),
               "PIE_SHMEM_NAME": f"/bon_regen_{os.getpid()}"}
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
                print(f"[bon-regen] daemon={base}")

                payload = S.round1_payload()
                async with httpx.AsyncClient(timeout=httpx.Timeout(600.0)) as http:
                    first = await one_round(http, base, payload, "first send")
                    # The regenerate: byte-identical request, same cache key.
                    second = await one_round(http, base, payload, "regenerate")
                    third = await one_round(http, base, payload, "regenerate #2")
            finally:
                drain.cancel()
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=20)
            except Exception:
                proc.kill()

    print("\n" + json.dumps({"first": first, "regenerate": second, "regenerate2": third}, indent=2))
    if first["ok"] and second["ok"] and third["ok"]:
        print("PASS: regenerate reproduced no failure.")
        return 0
    print("FAIL: a repeat of the identical Best-of-N request lost candidates.", file=sys.stderr)
    return 1


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--handshake-timeout", type=float, default=600.0)
    return asyncio.run(main_async(p.parse_args(argv)))


if __name__ == "__main__":
    raise SystemExit(main())
