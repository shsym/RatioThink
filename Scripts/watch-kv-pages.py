"""Watch KV page usage on a RUNNING pie engine while you reproduce a failure.

Why this exists: a Best-of-N round that generates for a while and then fails
mid-stream looks like KV exhaustion, but nothing in the app surfaces page usage,
so the theory stays a theory. This polls pie's own `model_status` query — the
same source `apc_bench_real.py` reads — and prints used/total pages over time.

If used climbs to total right before the turn fails, KV exhaustion is confirmed.
If it does not, KV is exonerated and the cause is elsewhere. Either way it turns
an argument into a measurement.

Get the two values from the engine log lines pie prints at startup:

    ✓ Server ready at ws://127.0.0.1:PORT
    internal token: <token>

    uv run --project Vendor/pie/client/python \\
      python Scripts/watch-kv-pages.py --engine ws://127.0.0.1:PORT --token <token>

Leave it running, reproduce the failure, then read the last lines. Ctrl-C to stop.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
import time


def kv_for_models(status: dict) -> list[tuple[str, int | None, int | None]]:
    """(model, used, total) for every model that reports page counts."""
    models: dict[str, dict[str, int]] = {}
    for key, value in (status or {}).items():
        if "." not in key:
            continue
        model, field = key.rsplit(".", 1)
        if field in ("kv_pages_used", "kv_pages_total"):
            try:
                models.setdefault(model, {})[field] = int(value)
            except (TypeError, ValueError):
                pass
    return [
        (m, f.get("kv_pages_used"), f.get("kv_pages_total"))
        for m, f in sorted(models.items())
    ]


async def main_async(args) -> int:
    try:
        from pie_client import PieClient
    except ImportError:
        print("pie_client missing — run under: uv run --project Vendor/pie/client/python",
              file=sys.stderr)
        return 2

    async with PieClient(args.engine) as client:
        if args.token:
            await client.auth_by_token(args.token)
        print(f"{'time':10s} {'model':28s} {'used':>8s} {'total':>8s} {'used%':>7s}")
        prev: dict[str, int] = {}
        while True:
            ok, payload = await client.query("model_status", "")
            if not ok:
                print(f"{time.strftime('%H:%M:%S')}  model_status refused: {payload}",
                      file=sys.stderr)
                await asyncio.sleep(args.interval)
                continue
            for model, used, total in kv_for_models(json.loads(payload)):
                if used is None or not total:
                    continue
                pct = 100 * used // total
                # A jump is the moment pressure spikes — that is what to line up
                # against the failure timestamp.
                mark = ""
                if model in prev and used - prev[model] >= args.jump:
                    mark = f"   <-- +{used - prev[model]} pages"
                if pct >= args.warn:
                    mark += f"   [{pct}% FULL]"
                prev[model] = used
                print(f"{time.strftime('%H:%M:%S')} {model:28s} {used:8d} {total:8d} "
                      f"{pct:6d}%{mark}", flush=True)
            await asyncio.sleep(args.interval)


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--engine", required=True, help="ws://127.0.0.1:PORT from the engine log")
    p.add_argument("--token", default=None, help="the engine's 'internal token:' line")
    p.add_argument("--interval", type=float, default=2.0)
    p.add_argument("--jump", type=int, default=16, help="flag increases of at least this many pages")
    p.add_argument("--warn", type=int, default=85, help="flag when used%% reaches this")
    try:
        return asyncio.run(main_async(p.parse_args(argv)))
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
