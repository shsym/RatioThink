"""Shared portable-Metal `pie serve` bootstrap for the real-engine
tree-of-thought harnesses (#458): the perf benchmark (`tot_bench.py`) and
the batched-path e2e (`tot_real_e2e.py`). One implementation of: render the
production-equivalent portable config, spawn the engine, install chat-apc,
launch its HTTP daemon, yield the base URL, and tear everything down.

Reuses the engine-bootstrap primitives from `e2e_test.py` (handshake parse,
stdout drain, port wait, subprocess teardown) so there is a single copy.
"""
from __future__ import annotations

import asyncio
import contextlib
import os
import subprocess
import sys
import tempfile
from pathlib import Path

from pie_client import PieClient

_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))
from e2e_test import (  # noqa: E402
    PIE_BIN,
    WASM_PATH,
    MANIFEST_PATH,
    _drain_stdout,
    _free_port,
    _parse_handshake,
    _shm_unlink_quiet,
    _terminate_subprocess,
    _wait_for_port,
)


def portable_config(slug: str, model_path: str) -> str:
    """Mirror `PieControlLauncher.renderConfigBody`'s portable-Metal body so
    the harness measures/exercises the production scheduler + driver path
    (`batch_policy = "adaptive"`, portable driver on Metal)."""
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
name = "{slug}"
hf_repo = "{model_path}"

[model.scheduler]
batch_policy = "adaptive"
request_timeout_secs = 60
default_endowment_pages = 4
admission_oversubscription_factor = 8.0
restore_pause_at_utilization = 0.85

[model.driver]
type = "portable"
device = ["metal"]
"""


@contextlib.asynccontextmanager
async def real_engine(slug: str, model_path: str, handshake_timeout: float = 120):
    """Boot a real portable-Metal `pie serve` for `model_path`, install the
    chat-apc inferlet, launch its HTTP daemon, and yield the base URL. Tears
    the engine down (and unlinks its shmem region) on exit. Model load can
    take a while on a cold cache — hence the generous handshake timeout.

    Installs `$PIE_TOT_WASM` when set, else the committed prebuilt wasm. The
    #458 strategy harnesses build a `--features exec-strategies` wasm (so they
    can drive the gated non-default strategies) and point this at it; the
    production prebuilt rejects a non-default `exec`."""
    wasm = Path(os.environ.get("PIE_TOT_WASM", WASM_PATH))
    assert PIE_BIN.exists(), f"missing pie binary at {PIE_BIN} (build PIE_PORTABLE_METAL=1)"
    assert wasm.exists(), f"missing wasm at {wasm}"
    assert Path(model_path).exists(), f"missing GGUF at {model_path}"

    shmem_base = f"/pie_tot_real_{os.getpid()}"
    with tempfile.TemporaryDirectory(prefix="tot-real-") as tmp:
        tmp = Path(tmp)
        cfg = tmp / "config.toml"
        cfg.write_text(portable_config(slug, model_path))
        pie_home = tmp / "home"
        pie_home.mkdir()
        env = {**os.environ, "PIE_HOME": str(pie_home), "PIE_SHMEM_NAME": shmem_base}

        proc = subprocess.Popen(
            [str(PIE_BIN), "serve", "--config", str(cfg), "--no-auth", "--debug"],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            env=env,
            bufsize=1,
        )
        try:
            ws_addr, token = await _parse_handshake(proc, timeout=handshake_timeout)
            drain = asyncio.create_task(_drain_stdout(proc))
            try:
                client = PieClient(f"ws://{ws_addr}")
                await client.connect()
                await client.auth_by_token(token)
                await client.install_program(wasm, MANIFEST_PATH, force_overwrite=True)
                http_port = _free_port()
                base = f"http://127.0.0.1:{http_port}"
                await client.launch_daemon("chat-apc@0.1.0", http_port)
                if not _wait_for_port(http_port, timeout=30):
                    raise RuntimeError(f"daemon never bound port {http_port}")
                yield base
            finally:
                drain.cancel()
        finally:
            _terminate_subprocess(proc, label="real-engine")
            _shm_unlink_quiet(f"{shmem_base}_g0")
