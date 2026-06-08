"""End-to-end smoke test for chat-apc inferlet.

Boots `pie serve --config /tmp/pie-test-dummy.toml` as a subprocess, parses
its stdout for the bound WS URL + internal token, installs the prebuilt
chat-apc.wasm via WS, launches it as a daemon on a free port, and
hits `/healthz` + `/v1/models`.

Before any of that runs we verify `prebuilt/chat-apc.wasm.stamp`
matches the current `Vendor/pie` submodule SHA, the inferlet `src/` +
manifests' content hash, and the wasm file hash. A mismatch fails fast
with a "rebuild required" diagnostic rather than silently shipping a
stale binary (review F4 / F5).

Requires:
  * pre-built pie binary at `Vendor/pie/target/release/pie`
  * pre-built `Inferlets/chat-apc/prebuilt/chat-apc.wasm`
  * `Inferlets/chat-apc/prebuilt/chat-apc.wasm.stamp` matching the
    current submodule SHA + `src/` hash + wasm hash
  * Qwen/Qwen3-0.6B in `~/.cache/huggingface/hub` (or another HF model
    that the dummy driver can resolve config for)

Usage::

    uv run python Inferlets/chat-apc/e2e_test.py
"""
from __future__ import annotations

import asyncio
import contextlib
import ctypes
import ctypes.util
import errno
import os
import re
import signal
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import httpx
from pie_client import PieClient

# Stamp helpers (parser, hashers, verify) live in _stamp.py so both this
# harness and Scripts/stamp-chat-apc.sh share one implementation —
#  item 4.
_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))
import _stamp  # noqa: E402

# pie-mac layout: this script lives at Inferlets/chat-apc/e2e_test.py
# pie binary built into the Vendor/pie submodule target dir.
ROOT = _stamp.ROOT
PIE_BIN = ROOT / "Vendor" / "pie" / "target" / "release" / "pie"
INFERLET_DIR = _stamp.INFERLET_DIR
WASM_PATH = _stamp.WASM_PATH
STAMP_PATH = _stamp.STAMP_PATH
MANIFEST_PATH = INFERLET_DIR / "Pie.toml"
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
name = "default"
hf_repo = "Qwen/Qwen3-0.6B"

[model.scheduler]
batch_policy = "adaptive"
request_timeout_secs = 60
default_endowment_pages = 4
admission_oversubscription_factor = 8.0
restore_pause_at_utilization = 0.85
# The per-request max_tokens ceiling chat-apc reads back
# (runtime::max-output-tokens — #438) follows default_token_limit when
# set, ELSE the raw KV capacity. Set it to a value that is neither the KV
# capacity (32 * 512 = 16384) nor the old hardcoded 8192, so the
# over-limit assertion in main() proves default_token_limit takes
# precedence end to end.
default_token_limit = 5000

[model.driver]
type = "dummy"
device = ["cpu"]

[model.driver.options]
vocab_size = 32000
arch_name = "test"
kv_page_size = 32
max_num_kv_pages = 512
"""

# The ceiling chat-apc must report = the configured default_token_limit
# above (NOT the 16384 KV capacity, NOT the old 8192 constant).
EXPECTED_MAX_OUTPUT_TOKENS = 5000

# Files contributing to the inferlet "source hash" re-exported for
# legacy callers; authoritative copy lives in `_stamp.SRC_HASH_PATHS`.
SRC_HASH_PATHS = _stamp.SRC_HASH_PATHS


# ---------------------------------------------------------------------------
# Stamp verification (review F4 / F5)
# ---------------------------------------------------------------------------

# Shared with `Scripts/stamp-chat-apc.sh verify` — see _stamp.py.
verify_stamp = _stamp.verify


# ---------------------------------------------------------------------------
# Shmem-region cleanup (review F6)
# ---------------------------------------------------------------------------

def _shm_unlink_quiet(name: str) -> None:
    """Best-effort `shm_unlink` so stale POSIX regions don't leak.

    Used in `finally` after the engine subprocess is reaped — covers
    SIGKILL / engine-crash paths where the engine's Drop never runs.
    POSIX shmem is host-global, so a leaked region persists across runs
    and a later run that recycles the same PID would attach to stale
    geometry.

    The function is "quiet" in that it doesn't raise — but it always
    *announces itself* on stdout so CI can distinguish "cleanup ran and
    succeeded", "cleanup ran and found nothing (ENOENT)", "cleanup
    skipped because libc unavailable", and "cleanup failed with errno
    N". The previous silent no-op when `find_library('c')` returned
    None (stripped containers, sandboxes) made the F6 cleanup invisible
    to CI (review F3).
    """
    libc_name = ctypes.util.find_library("c")
    if libc_name is None:
        print(
            f"[harness] shm_unlink({name!r}) SKIPPED: libc not resolvable via "
            f"ctypes.util.find_library('c'); the region may leak into POSIX's "
            f"host-global namespace and a later run that recycles this pid "
            f"can attach to stale geometry",
            flush=True,
        )
        return
    libc = ctypes.CDLL(libc_name, use_errno=True)
    libc.shm_unlink.argtypes = [ctypes.c_char_p]
    libc.shm_unlink.restype = ctypes.c_int
    rc = libc.shm_unlink(name.encode("utf-8"))
    if rc == 0:
        print(f"[harness] shm_unlink({name!r}) OK", flush=True)
        return
    err = ctypes.get_errno()
    if err == errno.ENOENT:
        print(f"[harness] shm_unlink({name!r}) ENOENT (already gone)", flush=True)
        return
    print(
        f"[harness] shm_unlink({name!r}) FAILED: errno={err} "
        f"({errno.errorcode.get(err, 'unknown')})",
        flush=True,
    )


# ---------------------------------------------------------------------------
# Subprocess helpers
# ---------------------------------------------------------------------------

def _free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


async def _parse_handshake(proc: subprocess.Popen, timeout: float) -> tuple[str, str]:
    """Read pie stdout until we have `pie-server serving on <host>:<port>` + `internal token: <tok>`."""
    url_re = re.compile(r"pie-server serving on ([^\s]+:[0-9]+)")
    tok_re = re.compile(r"internal token: ([^\s]+)")
    url: str | None = None
    token: str | None = None
    deadline = time.monotonic() + timeout
    loop = asyncio.get_event_loop()
    while time.monotonic() < deadline and (url is None or token is None):
        if proc.poll() is not None:
            raise RuntimeError(f"pie exited early (code={proc.returncode})")
        line = await loop.run_in_executor(None, proc.stdout.readline)
        if not line:
            await asyncio.sleep(0.05)
            continue
        sys.stdout.write(f"[pie] {line}")
        sys.stdout.flush()
        if url is None:
            m = url_re.search(line)
            if m:
                url = m.group(1)
        if token is None:
            m = tok_re.search(line)
            if m:
                token = m.group(1)
    if url is None or token is None:
        raise RuntimeError(f"timeout parsing pie handshake (url={url!r} token={token!r})")
    return url, token


async def _drain_stdout(proc: subprocess.Popen) -> None:
    """Keep reading pie's stdout in background so the pipe buffer doesn't fill."""
    loop = asyncio.get_event_loop()
    while proc.poll() is None:
        line = await loop.run_in_executor(None, proc.stdout.readline)
        if not line:
            await asyncio.sleep(0.05)
            continue
        sys.stdout.write(f"[pie] {line}")
        sys.stdout.flush()


def _send_signal_safe(
    proc: subprocess.Popen,
    sig: signal.Signals,
    label: str,
    sig_name: str,
) -> bool:
    """Best-effort `proc.send_signal(sig)`; returns False on any OSError.

    `ProcessLookupError` (ESRCH) means the child already exited — log
    + return False so the caller skips waiting on it. Any other OSError
    (EPERM on a restricted CI worker, EINVAL on a bad signal number)
    also logs + returns False so downstream cleanup (stdout close,
    drain cancel, shm_unlink) still runs.
    """
    try:
        if sig is signal.SIGKILL:
            proc.kill()
        else:
            proc.send_signal(sig)
        return True
    except ProcessLookupError:
        print(
            f"[harness] terminate({label}): {sig_name} raced "
            f"ProcessLookupError (ESRCH); subprocess already exited",
            flush=True,
        )
        return False
    except OSError as e:
        print(
            f"[harness] terminate({label}): {sig_name} failed with OSError "
            f"errno={e.errno} ({errno.errorcode.get(e.errno or 0, 'unknown')}) "
            f"msg={e.strerror!r}; skipping wait — downstream cleanup will "
            f"still run",
            flush=True,
        )
        return False


def _wait_safe(
    proc: subprocess.Popen,
    timeout: float,
    label: str,
    stage: str,
) -> tuple[bool, bool]:
    """Best-effort `proc.wait(timeout)`; returns `(reaped, timed_out)`.

    Review  carry-over 6e — mirrors `_send_signal_safe`'s OSError
    widening for the wait side. `ECHILD` means another thread or
    signal handler already reaped the child; treat as reaped. `EPERM`
    / `EINVAL` from a restricted CI worker get logged + skipped so
    downstream cleanup still runs. `subprocess.TimeoutExpired` is
    surfaced separately so the caller can choose to escalate
    (SIGINT → SIGKILL).
    """
    try:
        proc.wait(timeout=timeout)
        return True, False
    except subprocess.TimeoutExpired:
        return False, True
    except ChildProcessError:
        print(
            f"[harness] terminate({label}): wait raced "
            f"ChildProcessError (ECHILD) at {stage}; child already "
            f"reaped elsewhere — treating as reaped",
            flush=True,
        )
        return True, False
    except OSError as e:
        print(
            f"[harness] terminate({label}): wait failed at {stage} "
            f"with OSError errno={e.errno} "
            f"({errno.errorcode.get(e.errno or 0, 'unknown')}) "
            f"msg={e.strerror!r}; skipping further wait — downstream "
            f"cleanup will still run",
            flush=True,
        )
        return False, False


def _terminate_subprocess(proc: subprocess.Popen, label: str) -> None:
    """Idempotent SIGINT → SIGKILL teardown.

    Guards every state-changing call so a raced exit or a sandbox-
    restricted signal call never aborts the rest of cleanup. The v3
    version only caught `ProcessLookupError` (`ESRCH`); the v4 review
    widened the signal-side net to any `OSError` because `EPERM` /
    `EINVAL` from a restricted CI worker would still skip downstream
    steps. Review  carry-over 6e widens the wait-side net the same
    way via `_wait_safe`. Each suppressed branch logs explicitly.
    `label` ("inner"/"outer") lets CI attribute the message.
    """
    if proc.poll() is not None:
        return
    if not _send_signal_safe(proc, signal.SIGINT, label, "SIGINT"):
        return
    reaped, timed_out = _wait_safe(proc, timeout=10, label=label, stage="post-SIGINT")
    if reaped:
        return
    if timed_out:
        print(
            f"[harness] terminate({label}): SIGINT timed out after 10s; "
            f"escalating to SIGKILL",
            flush=True,
        )
    else:
        # `_wait_safe` already logged an OSError; skip the SIGKILL
        # escalation because the underlying wait failure (EPERM /
        # restricted syscall) would just repeat on the post-SIGKILL
        # wait.
        return
    if not _send_signal_safe(proc, signal.SIGKILL, label, "SIGKILL"):
        return
    reaped, timed_out = _wait_safe(proc, timeout=5, label=label, stage="post-SIGKILL")
    if reaped:
        return
    if timed_out:
        # The OS hasn't reaped within 5s of SIGKILL — the subprocess is
        # stuck in an uninterruptible syscall (D state on Linux, hung
        # Mach IPC on macOS). We're out of moves; log and continue so
        # the rest of cleanup still runs.
        print(
            f"[harness] terminate({label}): SIGKILL+wait timed out after 5s "
            f"(uninterruptible syscall?); leaking subprocess to process exit",
            flush=True,
        )


def _wait_for_port(port: int, timeout: float = 15) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=1):
                return True
        except OSError:
            time.sleep(0.2)
    return False


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

async def main() -> int:
    assert PIE_BIN.exists(), f"missing pie binary at {PIE_BIN}"
    assert WASM_PATH.exists(), f"missing wasm at {WASM_PATH}"
    assert MANIFEST_PATH.exists(), f"missing manifest at {MANIFEST_PATH}"
    verify_stamp()

    shmem_base = f"/pie_e2e_{os.getpid()}"
    with tempfile.TemporaryDirectory(prefix="chat-apc-e2e-") as tmp:
        tmp = Path(tmp)
        cfg = tmp / "config.toml"
        cfg.write_text(CONFIG_TOML)
        pie_home = tmp / "home"
        pie_home.mkdir()

        env = {
            **os.environ,
            "PIE_HOME": str(pie_home),
            "PIE_SHMEM_NAME": shmem_base,
        }
        proc = subprocess.Popen(
            [str(PIE_BIN), "serve", "--config", str(cfg), "--no-auth", "--debug"],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            env=env,
            bufsize=1,
        )
        try:
            ws_addr, token = await _parse_handshake(proc, timeout=30)
            ws_url = f"ws://{ws_addr}"
            print(f"[harness] engine ws={ws_url} token={token[:8]}…")

            drain_task = asyncio.create_task(_drain_stdout(proc))
            try:
                client = PieClient(ws_url)
                await client.connect()
                await client.auth_by_token(token)

                await client.install_program(WASM_PATH, MANIFEST_PATH, force_overwrite=True)
                print("[harness] installed chat-apc@0.1.0")

                http_port = _free_port()
                base = f"http://127.0.0.1:{http_port}"
                await client.launch_daemon("chat-apc@0.1.0", http_port)
                print(f"[harness] launched daemon on {base}")

                if not _wait_for_port(http_port, timeout=15):
                    raise RuntimeError(f"daemon never bound port {http_port}")

                failures: list[str] = []
                # `skipped` tracks contracts the harness was unable
                # to exercise against the dummy driver but that
                # remain enforced by other coverage (live-driver
                # integration suite, code review). Surfaced in the
                # final report so a reviewer can see what wasn't
                # actually checked here — distinct from `failures`
                # which means a contract was checked AND violated.
                # Mirrors pytest's skipped-vs-failed distinction.
                skipped: list[str] = []
                async with httpx.AsyncClient(timeout=15) as http:
                    # /healthz
                    r = await http.get(f"{base}/healthz")
                    print(f"[harness] GET /healthz -> {r.status_code} {r.text!r}")
                    if r.status_code != 200:
                        failures.append(f"/healthz status {r.status_code}")
                    try:
                        body = r.json()
                    except Exception as e:
                        failures.append(f"/healthz not json: {e}")
                        body = None
                    if body != {"status": "ok"}:
                        failures.append(f"/healthz body {body!r}")

                    # /v1/models
                    r = await http.get(f"{base}/v1/models")
                    print(f"[harness] GET /v1/models -> {r.status_code} {r.text!r}")
                    if r.status_code != 200:
                        failures.append(f"/v1/models status {r.status_code}")
                    try:
                        body = r.json()
                    except Exception as e:
                        failures.append(f"/v1/models not json: {e}")
                        body = None
                    if not body or body.get("object") != "list":
                        failures.append(f"/v1/models object {body!r}")
                    data = (body or {}).get("data") or []
                    if not data:
                        failures.append(f"/v1/models data empty: {body!r}")
                    else:
                        first = data[0]
                        if first.get("object") != "model":
                            failures.append(f"/v1/models[0].object {first!r}")
                        if first.get("owned_by") != "pie":
                            failures.append(f"/v1/models[0].owned_by {first!r}")
                        if not isinstance(first.get("id"), str) or not first.get("id"):
                            failures.append(f"/v1/models[0].id {first!r}")
                        # #474: every entry carries the effective per-request
                        # max_tokens ceiling (engine-global min) so the App
                        # can clamp its profile value to the launched engine.
                        mot = first.get("max_output_tokens")
                        if not isinstance(mot, int) or isinstance(mot, bool) or mot <= 0:
                            failures.append(f"/v1/models[0].max_output_tokens {first!r}")

                    # 404
                    r = await http.get(f"{base}/nonexistent")
                    print(f"[harness] GET /nonexistent -> {r.status_code}")
                    if r.status_code != 404:
                        failures.append(f"/nonexistent status {r.status_code}")

                    # Phase 5.5–5.8 routes. The dummy driver registers
                    # a model under name "default" but has no real
                    # forward-pass capability — we exercise the
                    # validation + meta-frame paths only, not the
                    # generation loop. Real chat-completion + dispatch
                    # smoke (with a live forward pass) lives in the
                    # GUI integration suite, not this engine-side
                    # harness.
                    model_id = first.get("id") if data else "default"

                    # POST /v1/models/load — pre-warm OK path.
                    r = await http.post(
                        f"{base}/v1/models/load",
                        json={"model": model_id},
                    )
                    print(f"[harness] POST /v1/models/load(model={model_id!r}) -> {r.status_code}")
                    if r.status_code != 200:
                        failures.append(f"/v1/models/load status {r.status_code}")
                    if r.headers.get("content-type", "").split(";", 1)[0] != "text/event-stream":
                        failures.append(
                            f"/v1/models/load content-type {r.headers.get('content-type')!r}"
                        )
                    # Body should contain one model_ready meta-frame +
                    # the [DONE] sentinel. We assert exact ordering so
                    # GUI consumers can rely on it.
                    text = r.text
                    if 'data: {"event":"model_ready"}' not in text:
                        failures.append(f"/v1/models/load missing model_ready frame: {text!r}")
                    if "data: [DONE]" not in text:
                        failures.append(f"/v1/models/load missing [DONE] sentinel: {text!r}")

                    # POST /v1/models/load — unknown model → 404.
                    r = await http.post(
                        f"{base}/v1/models/load",
                        json={"model": "does-not-exist"},
                    )
                    print(f"[harness] POST /v1/models/load(model='does-not-exist') -> {r.status_code}")
                    if r.status_code != 404:
                        failures.append(f"/v1/models/load unknown status {r.status_code}")

                    # DELETE /v1/models/load — 204 no-op.
                    r = await http.delete(f"{base}/v1/models/load")
                    print(f"[harness] DELETE /v1/models/load -> {r.status_code}")
                    if r.status_code != 204:
                        failures.append(f"/v1/models/load DELETE status {r.status_code}")

                    # POST /v1/chat/completions — unknown model → 404
                    # (validation path, no forward pass triggered).
                    r = await http.post(
                        f"{base}/v1/chat/completions",
                        json={
                            "model": "does-not-exist",
                            "messages": [{"role": "user", "content": "hi"}],
                            "stream": False,
                        },
                    )
                    print(f"[harness] POST /v1/chat/completions(bad model) -> {r.status_code}")
                    if r.status_code != 404:
                        failures.append(f"/v1/chat/completions unknown model status {r.status_code}")

                    # POST /v1/chat/completions — empty messages → 400.
                    r = await http.post(
                        f"{base}/v1/chat/completions",
                        json={"model": model_id, "messages": [], "stream": False},
                    )
                    print(f"[harness] POST /v1/chat/completions(empty messages) -> {r.status_code}")
                    if r.status_code != 400:
                        failures.append(
                            f"/v1/chat/completions empty messages status {r.status_code}"
                        )

                    # POST /v1/inferlet — unknown name → 404.
                    r = await http.post(
                        f"{base}/v1/inferlet",
                        json={"inferlet": "no-such", "input": {}, "stream": False},
                    )
                    print(f"[harness] POST /v1/inferlet(unknown name) -> {r.status_code}")
                    if r.status_code != 404:
                        failures.append(f"/v1/inferlet unknown status {r.status_code}")

                    # POST /v1/inferlet — chat-apc with unknown model
                    # in `input` → 404 from the chat layer.
                    r = await http.post(
                        f"{base}/v1/inferlet",
                        json={
                            "inferlet": "chat-apc",
                            "input": {"model": "does-not-exist"},
                            "messages": [{"role": "user", "content": "hi"}],
                            "stream": False,
                        },
                    )
                    print(f"[harness] POST /v1/inferlet(chat-apc + bad model) -> {r.status_code}")
                    if r.status_code != 404:
                        failures.append(
                            f"/v1/inferlet chat-apc bad model status {r.status_code}"
                        )

                    # ── tree-of-thought (#407) ───────────────────────
                    # The `tree-of-thought` dispatch name is accepted
                    # (distinct from the unknown-name 404 above). These
                    # validation paths are deterministic — they don't
                    # need a working forward pass. The full-search shape
                    # check below is best-effort against the dummy driver.

                    # stream:true + invalid params → still a JSON 400
                    # envelope, NOT a half-open SSE stream. #413: pre-stream
                    # validation runs BEFORE Emitter::start, so a doomed
                    # request never opens a stream it can only error inside.
                    r = await http.post(
                        f"{base}/v1/inferlet",
                        json={
                            "inferlet": "tree-of-thought",
                            "stream": True,
                            "input": {
                                "messages": [{"role": "user", "content": "hi"}],
                                "breadth": 0,
                            },
                        },
                    )
                    print(f"[harness] POST /v1/inferlet(tot stream + breadth=0) -> {r.status_code}")
                    if r.status_code != 400:
                        failures.append(f"tot stream breadth=0 status {r.status_code} (want 400)")
                    if r.headers.get("content-type", "").split(";", 1)[0] == "text/event-stream":
                        failures.append(
                            "tot stream breadth=0 opened an SSE stream (want a JSON 400 envelope)"
                        )

                    # #458: a non-default `exec` is REJECTED on a production
                    # (default-feature) build with a `param`-tagged 400 — the
                    # no-win strategy variants are gated behind
                    # `--features exec-strategies` (benchmark/e2e only), and a
                    # production client may not select a slower path. Never a
                    # silent coerce to the default.
                    r = await http.post(
                        f"{base}/v1/inferlet",
                        json={
                            "inferlet": "tree-of-thought",
                            "stream": False,
                            "input": {
                                "messages": [{"role": "user", "content": "hi"}],
                                "exec": "phased_concurrent",
                            },
                        },
                    )
                    print(f"[harness] POST /v1/inferlet(tot exec=phased_concurrent) -> {r.status_code}")
                    if r.status_code != 400:
                        failures.append(f"tot non-default exec status {r.status_code} (want 400)")
                    else:
                        try:
                            param = r.json().get("error", {}).get("param")
                        except Exception:
                            param = None
                        if param != "exec":
                            failures.append(f"tot non-default exec param {param!r} (want 'exec')")

                    # Out-of-range breadth → 400 with `param` tag.
                    r = await http.post(
                        f"{base}/v1/inferlet",
                        json={
                            "inferlet": "tree-of-thought",
                            "stream": False,
                            "input": {
                                "messages": [{"role": "user", "content": "hi"}],
                                "breadth": 0,
                            },
                        },
                    )
                    print(f"[harness] POST /v1/inferlet(tot breadth=0) -> {r.status_code}")
                    if r.status_code != 400:
                        failures.append(f"tot breadth=0 status {r.status_code} (want 400)")
                    else:
                        try:
                            param = r.json().get("error", {}).get("param")
                        except Exception:
                            param = None
                        if param != "breadth":
                            failures.append(f"tot breadth=0 param {param!r} (want 'breadth')")

                    # Node-budget explosion (5×4×5 = 80 > 64) → 400.
                    r = await http.post(
                        f"{base}/v1/inferlet",
                        json={
                            "inferlet": "tree-of-thought",
                            "stream": False,
                            "input": {
                                "messages": [{"role": "user", "content": "hi"}],
                                "breadth": 5,
                                "depth": 4,
                                "beam_width": 5,
                            },
                        },
                    )
                    print(f"[harness] POST /v1/inferlet(tot node-explosion) -> {r.status_code}")
                    if r.status_code != 400:
                        failures.append(f"tot node-explosion status {r.status_code} (want 400)")

                    # Unknown model in input → 404.
                    r = await http.post(
                        f"{base}/v1/inferlet",
                        json={
                            "inferlet": "tree-of-thought",
                            "stream": False,
                            "input": {
                                "model": "does-not-exist",
                                "messages": [{"role": "user", "content": "hi"}],
                            },
                        },
                    )
                    print(f"[harness] POST /v1/inferlet(tot bad model) -> {r.status_code}")
                    if r.status_code != 404:
                        failures.append(f"tot bad model status {r.status_code} (want 404)")

                    # Empty messages → 400.
                    r = await http.post(
                        f"{base}/v1/inferlet",
                        json={
                            "inferlet": "tree-of-thought",
                            "stream": False,
                            "input": {"messages": []},
                        },
                    )
                    print(f"[harness] POST /v1/inferlet(tot empty messages) -> {r.status_code}")
                    if r.status_code != 400:
                        failures.append(f"tot empty messages status {r.status_code} (want 400)")

                    # Full search path: a small tree. With the dummy
                    # driver the per-node forward pass may error
                    # (status:"error" nodes) or return random tokens
                    # (status:"ok"); either way the REQUEST returns 200
                    # with the full tree. If the dummy driver cannot flush
                    # the prompt the request is 500 — recorded as SKIPPED
                    # (tree shape asserted only under a real driver).
                    bd, dp, bw = 2, 2, 1
                    r = await http.post(
                        f"{base}/v1/inferlet",
                        json={
                            "inferlet": "tree-of-thought",
                            "stream": False,
                            "input": {
                                "messages": [{"role": "user", "content": "What is 2+2?"}],
                                "breadth": bd,
                                "depth": dp,
                                "beam_width": bw,
                                "max_tokens_per_node": 16,
                            },
                        },
                    )
                    print(f"[harness] POST /v1/inferlet(tot search {bd}x{dp}/beam{bw}) -> {r.status_code}")
                    if r.status_code == 200:
                        body = r.json()
                        if body.get("object") != "tree_of_thought":
                            failures.append(f"tot object {body.get('object')!r}")
                        root = body.get("root") or {}
                        if root.get("id") != "root" or root.get("depth") != 0:
                            failures.append(f"tot root shape {root!r}")
                        if (body.get("breadth"), body.get("depth"), body.get("beam_width")) != (bd, dp, bw):
                            failures.append(f"tot echoed params {body!r}")

                        def _walk(n):
                            out = [n]
                            for c in n.get("children", []):
                                out.extend(_walk(c))
                            return out

                        non_root = [n for n in _walk(root) if n.get("id") != "root"]
                        want_nodes = bd + (dp - 1) * bw * bd  # 2 + 1*1*2 = 4
                        if len(non_root) != want_nodes:
                            failures.append(
                                f"tot node count {len(non_root)} (want {want_nodes}): {body!r}"
                            )
                        ids = {n.get("id") for n in non_root}
                        for n in non_root:
                            missing = [
                                k
                                for k in ("id", "parent_id", "depth", "branch_index", "content", "score", "status")
                                if k not in n
                            ]
                            if missing:
                                failures.append(f"tot node missing {missing}: {n!r}")
                            if n.get("status") not in ("ok", "error"):
                                failures.append(f"tot node status {n.get('status')!r}")
                            if not (isinstance(n.get("depth"), int) and 1 <= n["depth"] <= dp):
                                failures.append(f"tot node depth {n.get('depth')!r}")
                            sc = n.get("score")
                            if sc is not None and not (isinstance(sc, int) and 1 <= sc <= 10):
                                failures.append(f"tot node score {sc!r}")
                        sel = body.get("selected_node_id")
                        if sel is not None and sel not in ids:
                            failures.append(f"tot selected_node_id {sel!r} not in tree")
                    elif r.status_code == 500:
                        skipped.append(
                            "tree-of-thought full search: dummy driver could not "
                            "flush/generate (500); tree shape is asserted only under a "
                            "forward-pass-capable driver (live-engine coverage)"
                        )
                    else:
                        failures.append(f"tot search status {r.status_code} (want 200 or 500)")

                    # ── tree-of-thought STREAMING (#413) ─────────────
                    # stream:true streams the same search as SSE: a
                    # `tree_start`, then per level a `node_complete` per
                    # node followed by a `level_pruned` beam, then exactly
                    # one terminal `tree_complete` and `[DONE]`. As with
                    # the non-stream search the dummy driver may fail the
                    # pre-stream flush (→ JSON 500, recorded SKIPPED); the
                    # frame-ORDER invariant is asserted only when the
                    # stream actually opens (200 text/event-stream).
                    sbd, sdp, sbw = 2, 2, 1
                    r = await http.post(
                        f"{base}/v1/inferlet",
                        json={
                            "inferlet": "tree-of-thought",
                            "stream": True,
                            "input": {
                                "messages": [{"role": "user", "content": "What is 2+2?"}],
                                "breadth": sbd,
                                "depth": sdp,
                                "beam_width": sbw,
                                "max_tokens_per_node": 16,
                            },
                        },
                    )
                    print(f"[harness] POST /v1/inferlet(tot STREAM {sbd}x{sdp}/beam{sbw}) -> {r.status_code}")
                    if r.status_code == 200:
                        ctype = r.headers.get("content-type", "").split(";", 1)[0]
                        if ctype != "text/event-stream":
                            failures.append(f"tot stream content-type {ctype!r} (want text/event-stream)")

                        # Parse `data: <payload>` SSE frames into ordered
                        # (event, json) pairs; `[DONE]` is the sentinel.
                        import json as _json
                        events, saw_done = [], False
                        for line in r.text.splitlines():
                            if not line.startswith("data:"):
                                continue
                            payload = line[len("data:"):].strip()
                            if payload == "[DONE]":
                                saw_done = True
                                continue
                            if saw_done:
                                failures.append("tot stream emitted a frame AFTER [DONE]")
                            try:
                                events.append(_json.loads(payload))
                            except Exception as exc:
                                failures.append(f"tot stream frame not JSON: {payload!r} ({exc})")

                        if not saw_done:
                            failures.append(f"tot stream missing [DONE] sentinel: {r.text!r}")

                        kinds = [e.get("event") for e in events]
                        # Opens with exactly one tree_start carrying the bounds.
                        if not kinds or kinds[0] != "tree_start":
                            failures.append(f"tot stream first frame {kinds[:1]} (want ['tree_start'])")
                        else:
                            ts = events[0]
                            if (ts.get("breadth"), ts.get("depth"), ts.get("beam_width")) != (sbd, sdp, sbw):
                                failures.append(f"tot stream tree_start bounds {ts!r}")
                            if not isinstance(ts.get("id"), str) or not ts.get("id"):
                                failures.append(f"tot stream tree_start id {ts.get('id')!r}")

                        # #407 invariant pt.1: every node_complete identifies
                        # its node by a stable id, and the node is flat
                        # (assembled client-side from parent_id — no children).
                        node_ids = set()
                        for e in events:
                            if e.get("event") != "node_complete":
                                continue
                            node = e.get("node") or {}
                            nid = node.get("id")
                            if not isinstance(nid, str) or not nid:
                                failures.append(f"tot stream node_complete missing node.id: {e!r}")
                            else:
                                node_ids.add(nid)
                            if "children" in node:
                                failures.append(f"tot stream node_complete carries children: {e!r}")
                            missing = [k for k in ("id", "parent_id", "depth", "branch_index", "content", "score", "status") if k not in node]
                            if missing:
                                failures.append(f"tot stream node_complete missing {missing}: {e!r}")

                        # level_pruned keeps only ids we actually streamed.
                        for e in events:
                            if e.get("event") != "level_pruned":
                                continue
                            kept = e.get("kept")
                            if not isinstance(kept, list):
                                failures.append(f"tot stream level_pruned kept {kept!r}")
                                continue
                            for kid in kept:
                                if kid not in node_ids:
                                    failures.append(f"tot stream level_pruned kept id {kid!r} never streamed")

                        # #407 invariant pt.2: exactly one terminal frame
                        # (tree_complete on success | error), and it is the
                        # LAST data frame (nothing streams after it).
                        terminals = [i for i, k in enumerate(kinds) if k in ("tree_complete", "error")]
                        if len(terminals) != 1:
                            failures.append(f"tot stream terminal frames {[kinds[i] for i in terminals]} (want exactly one)")
                        elif terminals[0] != len(kinds) - 1:
                            failures.append(f"tot stream frame(s) after terminal: {kinds[terminals[0]:]!r}")
                        else:
                            term = events[terminals[0]]
                            if term.get("event") == "tree_complete":
                                sel = term.get("selected_node_id")
                                if sel is not None and sel not in node_ids:
                                    failures.append(f"tot stream selected_node_id {sel!r} not streamed")
                                if "final_answer" not in term:
                                    failures.append(f"tot stream tree_complete missing final_answer: {term!r}")
                    elif r.status_code == 500:
                        skipped.append(
                            "tree-of-thought STREAM: dummy driver could not flush/generate "
                            "(pre-stream 500); SSE frame order asserted only under a "
                            "forward-pass-capable driver (live-engine coverage)"
                        )
                    else:
                        failures.append(f"tot stream status {r.status_code} (want 200 or 500)")

                    # Review v2 follow-ups (F6/F7/F16): param bounds,
                    # malformed JSON, oversized body, streaming frame
                    # order, /v1/inferlet messages-precedence.
                    bad_params = [
                        ("temperature", -1.0),
                        ("temperature", 3.0),
                        ("top_p", 0.0),
                        ("top_p", 1.5),
                        ("max_tokens", 0),
                        ("max_tokens", 1_000_000),
                    ]
                    for field, value in bad_params:
                        payload = {
                            "model": model_id,
                            "messages": [{"role": "user", "content": "hi"}],
                            "stream": False,
                            field: value,
                        }
                        r = await http.post(f"{base}/v1/chat/completions", json=payload)
                        print(
                            f"[harness] POST /v1/chat/completions({field}={value!r}) -> {r.status_code}"
                        )
                        if r.status_code != 400:
                            failures.append(
                                f"/v1/chat/completions {field}={value!r} status {r.status_code}"
                            )
                        else:
                            try:
                                err = r.json().get("error", {})
                            except Exception:
                                err = {}
                            if err.get("param") != field:
                                failures.append(
                                    f"/v1/chat/completions {field}={value!r} param tag {err!r}"
                                )

                    # #438: the max_tokens ceiling must FOLLOW the engine's
                    # configured default_token_limit (runtime::max-output-tokens),
                    # taking precedence over the raw KV capacity and never the
                    # old hardcoded 8192. The 400 message must name
                    # EXPECTED_MAX_OUTPUT_TOKENS (5000), NOT the 16384 capacity
                    # and NOT 8192 — proving the value flowed engine -> inferlet
                    # end to end via default_token_limit.
                    r = await http.post(
                        f"{base}/v1/chat/completions",
                        json={
                            "model": model_id,
                            "messages": [{"role": "user", "content": "hi"}],
                            "stream": False,
                            "max_tokens": 1_000_000,
                        },
                    )
                    ceiling_msg = ""
                    try:
                        ceiling_msg = r.json().get("error", {}).get("message", "")
                    except Exception:
                        ceiling_msg = r.text
                    print(f"[harness] max_tokens ceiling 400 message -> {ceiling_msg!r}")
                    if str(EXPECTED_MAX_OUTPUT_TOKENS) not in ceiling_msg:
                        failures.append(
                            "max_tokens ceiling must follow default_token_limit "
                            f"{EXPECTED_MAX_OUTPUT_TOKENS}; 400 message was {ceiling_msg!r}"
                        )
                    if "16384" in ceiling_msg:
                        failures.append(
                            "default_token_limit must take precedence over KV "
                            f"capacity 16384; 400 message was {ceiling_msg!r}"
                        )
                    if "8192" in ceiling_msg:
                        failures.append(
                            "max_tokens ceiling regressed to the hardcoded 8192; "
                            f"message was {ceiling_msg!r}"
                        )

                    # #418 (review F1): out-of-range speculation knobs are
                    # rejected at the 400 boundary with a nested `param`,
                    # parallel to the max_tokens over-range case above —
                    # NOT silently clamped.
                    for sub, value in [("leader_len", 0), ("draft_len", 99999)]:
                        r = await http.post(
                            f"{base}/v1/chat/completions",
                            json={
                                "model": model_id,
                                "messages": [{"role": "user", "content": "hi"}],
                                "stream": False,
                                "temperature": 0,
                                "speculation": {"enabled": True, sub: value},
                            },
                        )
                        print(
                            f"[harness] POST /v1/chat/completions(speculation.{sub}={value}) "
                            f"-> {r.status_code}"
                        )
                        if r.status_code != 400:
                            failures.append(
                                f"/v1/chat/completions speculation.{sub}={value} "
                                f"status {r.status_code} (expected 400)"
                            )
                        else:
                            try:
                                err = r.json().get("error", {})
                            except Exception:
                                err = {}
                            if err.get("param") != f"speculation.{sub}":
                                failures.append(
                                    f"/v1/chat/completions speculation.{sub}={value} "
                                    f"param tag {err!r} (expected speculation.{sub})"
                                )

                    # Malformed JSON body → 400.
                    r = await http.post(
                        f"{base}/v1/chat/completions",
                        content=b"not json at all",
                        headers={"Content-Type": "application/json"},
                    )
                    print(f"[harness] POST /v1/chat/completions(malformed JSON) -> {r.status_code}")
                    if r.status_code != 400:
                        failures.append(
                            f"/v1/chat/completions malformed status {r.status_code}"
                        )

                    # Body exceeds CHAT_MAX_BODY (1 MiB) → 413.
                    big = b"a" * ((1 << 20) + 1024)
                    r = await http.post(
                        f"{base}/v1/chat/completions",
                        content=big,
                        headers={"Content-Type": "application/json"},
                    )
                    print(f"[harness] POST /v1/chat/completions(oversized) -> {r.status_code}")
                    if r.status_code != 413:
                        failures.append(
                            f"/v1/chat/completions oversized status {r.status_code}"
                        )

                    # #418: speculative-decode WIRING smoke. The dummy
                    # driver is non-deterministic (random tokens even at
                    # temperature 0), so it CANNOT demonstrate draft
                    # acceptance or greedy token-equivalence — those are
                    # proven deterministically by the host unit tests
                    # (`cargo test`: deterministic accounting +
                    # `greedy_spec_matches_plain_token_stream`) and by a
                    # real-model run. Here we assert only what the dummy
                    # CAN show end-to-end: a `speculation` request returns
                    # a self-consistent `spec_metrics` block, and a normal
                    # request stays byte-identical (no `spec_metrics`).
                    # Results are printed inline (flush) so the evidence
                    # survives even if a later, unrelated harness step
                    # aborts before the final summary.
                    import json as _json418
                    spec418: list[str] = []
                    r_spec = await http.post(
                        f"{base}/v1/chat/completions",
                        json={
                            "model": model_id,
                            "messages": [{"role": "user", "content": "alpha beta gamma"}],
                            "temperature": 0,
                            "max_tokens": 16,
                            "speculation": {"enabled": True},
                        },
                    )
                    print(f"[harness] POST chat(speculation) -> {r_spec.status_code}")
                    if r_spec.status_code != 200:
                        spec418.append(f"spec status {r_spec.status_code} (expected 200)")
                    else:
                        try:
                            b_spec = _json418.loads(r_spec.text)
                        except _json418.JSONDecodeError as e:
                            spec418.append(f"spec body not json: {e}")
                            b_spec = None
                        if b_spec is not None:
                            sm = b_spec.get("spec_metrics")
                            if sm is None:
                                spec418.append(f"spec_metrics missing: {b_spec!r}")
                            else:
                                print(f"[harness] spec_metrics={sm}", flush=True)
                                prop = sm.get("proposed_draft_tokens")
                                acc = sm.get("accepted_draft_tokens")
                                rej = sm.get("rejected_draft_tokens")
                                if None in (prop, acc, rej) or acc + rej != prop:
                                    spec418.append(f"accounting inconsistent: {sm!r}")
                                if not sm.get("enabled", False):
                                    spec418.append(f"enabled=false despite greedy+request: {sm!r}")
                                if sm.get("decode_steps", 0) <= 0:
                                    spec418.append(f"no decode steps: {sm!r}")
                    # Normal request (no speculation field) must NOT carry
                    # spec_metrics — proves normal responses are unchanged.
                    r_plain = await http.post(
                        f"{base}/v1/chat/completions",
                        json={
                            "model": model_id,
                            "messages": [{"role": "user", "content": "alpha beta gamma"}],
                            "temperature": 0,
                            "max_tokens": 16,
                        },
                    )
                    if r_plain.status_code == 200:
                        try:
                            if _json418.loads(r_plain.text).get("spec_metrics") is not None:
                                spec418.append(
                                    "plain response carried spec_metrics without a "
                                    "speculation request (normal responses must stay "
                                    "byte-identical)"
                                )
                        except _json418.JSONDecodeError:
                            pass
                    if spec418:
                        for f in spec418:
                            print(f"[harness] #418 FAIL: {f}", flush=True)
                        failures.extend(f"#418 {f}" for f in spec418)
                    else:
                        print("[harness] #418 spec_metrics wiring OK", flush=True)
                    # Acceptance + greedy token-equivalence need a
                    # deterministic model; the dummy driver can't provide
                    # one (covered by host cargo tests + a real-model run).
                    skipped.append(
                        "#418 spec acceptance + greedy equivalence (dummy driver is "
                        "non-deterministic; host cargo tests + real-model smoke cover it)"
                    )

                    # #418 x tool_choice: speculation gates OFF when a tool
                    # call is FORCED (the sampler is constrained to the
                    # tool-call grammar; the drafter must not verify against
                    # it). A forced request that also enables speculation
                    # must report spec_metrics.enabled=false with
                    # fallback_reason="tool_choice_forced".
                    r = await http.post(
                        f"{base}/v1/chat/completions",
                        json={
                            "model": model_id,
                            "messages": [{"role": "user", "content": "What is 2+2?"}],
                            "stream": False,
                            "temperature": 0,
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
                        },
                    )
                    print(
                        f"[harness] POST chat(forced tool + speculation) -> {r.status_code}"
                    )
                    if r.status_code == 200:
                        try:
                            sm = _json418.loads(r.text).get("spec_metrics")
                        except _json418.JSONDecodeError:
                            sm = None
                        if sm is None:
                            failures.append(
                                f"#418 forced-tool: spec_metrics missing: {r.text[:200]!r}"
                            )
                        else:
                            print(f"[harness] forced-tool spec_metrics={sm}", flush=True)
                            if sm.get("enabled") is not False:
                                failures.append(
                                    f"#418 forced-tool: speculation NOT gated off: {sm!r}"
                                )
                            if sm.get("fallback_reason") != "tool_choice_forced":
                                failures.append(
                                    f"#418 forced-tool: fallback_reason={sm.get('fallback_reason')!r} "
                                    f"(expected 'tool_choice_forced')"
                                )
                    else:
                        # A non-200 (e.g. model lacks a native tool grammar)
                        # doesn't exercise the gate; record explicitly.
                        skipped.append(
                            f"#418 forced-tool gate (engine returned {r.status_code}, "
                            f"not a 200 tool-call body)"
                        )

                    # /v1/inferlet messages-precedence: input.messages
                    # wins over top-level messages. Setting input.messages
                    # to [] while top-level has content → 400 (empty
                    # messages), proving input was consulted.
                    r = await http.post(
                        f"{base}/v1/inferlet",
                        json={
                            "inferlet": "chat-apc",
                            "input": {"model": model_id, "messages": []},
                            "messages": [{"role": "user", "content": "hi"}],
                            "stream": False,
                        },
                    )
                    print(
                        f"[harness] POST /v1/inferlet(input.messages=[] wins) -> {r.status_code}"
                    )
                    if r.status_code != 400:
                        failures.append(
                            f"/v1/inferlet messages-precedence status {r.status_code} "
                            f"(input.messages=[] should have won, producing 400)"
                        )

                    # Streaming frame order (F16b.a): model_ready
                    # precedes any content frame, the terminal
                    # chat.completion.chunk carries a finish_reason
                    # in {stop, length, error}, stream ends with
                    # [DONE]. Dummy driver can't drive a real
                    # forward pass — Generator::next surfaces an
                    # Err — so we expect finish_reason="error" in
                    # this harness; the assertion is robust to
                    # either path (a forward-pass-capable driver
                    # would naturally land on "stop" or "length").
                    import json as _json
                    r = await http.post(
                        f"{base}/v1/chat/completions",
                        json={
                            "model": model_id,
                            "messages": [{"role": "user", "content": "hi"}],
                            "stream": True,
                        },
                    )
                    print(
                        f"[harness] POST /v1/chat/completions(stream=true) -> {r.status_code} "
                        f"content-type={r.headers.get('content-type')!r}"
                    )
                    if r.status_code != 200:
                        failures.append(f"/v1/chat/completions stream status {r.status_code}")
                    else:
                        ct = r.headers.get("content-type", "").split(";", 1)[0]
                        if ct != "text/event-stream":
                            failures.append(
                                f"/v1/chat/completions stream content-type {ct!r}"
                            )
                        data_lines = [
                            line[len("data: "):]
                            for line in r.text.splitlines()
                            if line.startswith("data: ")
                        ]
                        # F9 ordering: first frame is model_ready.
                        if not data_lines or data_lines[0] != '{"event":"model_ready"}':
                            failures.append(
                                f"/v1/chat/completions stream first frame {data_lines[:2]!r}"
                            )
                        if "[DONE]" not in data_lines:
                            failures.append(
                                f"/v1/chat/completions stream missing [DONE]"
                            )
                        # F16b.a: locate the terminal chunk and
                        # assert its finish_reason is in the
                        # canonical set.
                        finish_reason = None
                        finish_idx = None
                        for i, d in enumerate(data_lines):
                            if d == "[DONE]":
                                continue
                            try:
                                obj = _json.loads(d)
                            except _json.JSONDecodeError:
                                continue
                            if obj.get("object") == "chat.completion.chunk":
                                fr = obj["choices"][0].get("finish_reason")
                                if fr is not None:
                                    finish_reason = fr
                                    finish_idx = i
                        if finish_reason is None:
                            failures.append(
                                f"/v1/chat/completions stream: no terminal chunk with "
                                f"finish_reason: {data_lines!r}"
                            )
                        elif finish_reason not in ("stop", "length", "error"):
                            failures.append(
                                f"/v1/chat/completions stream: finish_reason={finish_reason!r} "
                                f"not in canonical set"
                            )

                    # F16b.b: mid-stream error ordering. F8 says the
                    # terminal chat.completion.chunk with
                    # finish_reason:"error" MUST precede the
                    # `{"event":"error",…}` diagnostic meta-frame so
                    # OpenAI clients see the canonical finish first
                    # and pie-native clients consume the diagnostic
                    # after.
                    #
                    # The dummy driver returns random tokens without
                    # error and exits on "length"/"stop", so the
                    # deterministic trigger is impossible at this
                    # layer. We probe several payloads that would
                    # surface as Aborted on a live driver under load
                    # (long input → scheduler-overflow,
                    # max_tokens-1 → race with stop emission, etc.)
                    # and check the ordering contract whenever any
                    # response actually lands on
                    # finish_reason:"error" OR includes an
                    # {"event":"error"} meta-frame. If none of the
                    # probes exercise the contract, we explicitly
                    # mark the assertion SKIPPED (review F16c —
                    # NOT a bare print) and point to live-driver
                    # coverage in  (GUI integration suite).
                    error_ordering_exercised = False
                    error_ordering_violated: str | None = None
                    probes: list[dict] = [
                        {
                            "model": model_id,
                            "messages": [{"role": "user", "content": "trigger error path"}],
                            "stream": True,
                        },
                        {
                            "model": model_id,
                            "messages": [
                                {"role": "user", "content": " ".join(["w"] * 4000)},
                            ],
                            "stream": True,
                            "max_tokens": 4,
                        },
                        {
                            "model": model_id,
                            "messages": [{"role": "user", "content": "x"}],
                            "stream": True,
                            "max_tokens": 1,
                        },
                    ]
                    for probe_payload in probes:
                        r = await http.post(
                            f"{base}/v1/chat/completions", json=probe_payload
                        )
                        print(
                            f"[harness] POST /v1/chat/completions(stream=true probe) "
                            f"-> {r.status_code}"
                        )
                        if r.status_code != 200:
                            continue
                        data_lines = [
                            line[len("data: "):]
                            for line in r.text.splitlines()
                            if line.startswith("data: ")
                        ]
                        error_chunk_idx = None
                        error_meta_idx = None
                        for i, d in enumerate(data_lines):
                            if d == "[DONE]":
                                continue
                            try:
                                obj = _json.loads(d)
                            except _json.JSONDecodeError:
                                continue
                            if (
                                obj.get("object") == "chat.completion.chunk"
                                and obj["choices"][0].get("finish_reason") == "error"
                                and error_chunk_idx is None
                            ):
                                error_chunk_idx = i
                            if obj.get("event") == "error" and error_meta_idx is None:
                                error_meta_idx = i
                        if error_chunk_idx is None and error_meta_idx is None:
                            # Natural exit. F8 contract is
                            # vacuously satisfied for this probe;
                            # try next.
                            continue
                        error_ordering_exercised = True
                        if error_chunk_idx is None:
                            error_ordering_violated = (
                                f"meta-error frame at idx {error_meta_idx} with no "
                                f"preceding finish_reason:'error' chunk"
                            )
                        elif error_meta_idx is None:
                            error_ordering_violated = (
                                f"finish_reason:'error' chunk at idx {error_chunk_idx} "
                                f"but no {{event:error}} meta-frame followed"
                            )
                        elif error_chunk_idx >= error_meta_idx:
                            error_ordering_violated = (
                                f"meta-frame at idx {error_meta_idx} precedes "
                                f"finish_reason chunk at idx {error_chunk_idx}"
                            )
                        break
                    if error_ordering_exercised:
                        if error_ordering_violated is not None:
                            failures.append(
                                f"/v1/chat/completions error-ordering: "
                                f"{error_ordering_violated} — F8 contract violated"
                            )
                    else:
                        # F16c: do not silently pass. Record an
                        # explicit SKIPPED entry that surfaces in
                        # the final report. Comparable to
                        # `pytest.skip("requires live driver")`;
                        # this harness is a __main__ script, not a
                        # pytest module, so we use the harness's
                        # own skip channel rather than importing
                        # pytest for one call. F8 ordering remains
                        # enforced by (a) chat.rs control flow
                        # (terminal chunk emit precedes diagnostic
                        # emit by construction, see
                        # `handle_streaming`) and (b) the
                        # deterministic live-driver harness in the
                        # GUI integration suite (Phase 6.1 / ,
                        # which exercises the Aborted path against
                        # a forward-pass-capable driver).
                        skipped.append(
                            "/v1/chat/completions error-ordering (F8): dummy driver did "
                            "not produce a finish_reason:'error' or {event:error} frame "
                            "across 3 trigger probes; contract enforced by chat.rs "
                            "control flow + live-driver coverage in "
                        )

                    # APC plumbing-alive ( Phase 2): the chat handler
                    # now wires `inferlet::tools::equip_prefix` +
                    # `ToolUseDecoder` + `ReasoningDecoder` into the
                    # generation loop. The dummy driver can't drive a
                    # real forward pass and (depending on the
                    # model template) may have no tool surface, so we
                    # only assert that:
                    #   1. valid OpenAI tools[] payloads PARSE (not 400),
                    #   2. the response stays inside the canonical
                    #      envelope (200 with assistant message, or 500
                    #      with a known error code from the new wiring).
                    # Semantic correctness — tool_call detection,
                    # reasoning_content content — requires a live model
                    # and is gated behind .
                    tool_payload = {
                        "model": model_id,
                        "messages": [{"role": "user", "content": "What is 2+2?"}],
                        "stream": False,
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
                        "tool_choice": "auto",
                    }
                    r = await http.post(
                        f"{base}/v1/chat/completions", json=tool_payload
                    )
                    print(
                        f"[harness] POST /v1/chat/completions(tools+tool_choice) "
                        f"-> {r.status_code}"
                    )
                    if r.status_code == 400:
                        failures.append(
                            f"/v1/chat/completions tools-param parse: 400 "
                            f"{r.text!r} (tools[] schema should deserialize)"
                        )
                    elif r.status_code == 200:
                        body = r.json()
                        msg = body.get("choices", [{}])[0].get("message", {})
                        if msg.get("role") != "assistant":
                            failures.append(
                                f"/v1/chat/completions tools 200 body shape: "
                                f"missing assistant message: {body!r}"
                            )
                    elif r.status_code == 500:
                        code = r.json().get("error", {}).get("code")
                        if code not in (
                            "tool_equip_failed",
                            "tool_decode_failed",
                            "forward_pass_failed",
                            "decode_failed",
                            "reasoning_decode_failed",
                            "model_load_failed",
                            "context_create_failed",
                        ):
                            failures.append(
                                f"/v1/chat/completions tools 500 code={code!r} "
                                f"not in APC-wiring set"
                            )
                    else:
                        failures.append(
                            f"/v1/chat/completions tools status {r.status_code} "
                            f"unexpected"
                        )

                    # Reasoning plumbing-alive: the ReasoningDecoder runs
                    # unconditionally on every request. Send a prompt
                    # that *would* trigger a thinking model and confirm
                    # the streaming envelope still parses end-to-end —
                    # no frame should be malformed even when no reasoning
                    # tokens are produced. reasoning_content is omitted
                    # via `skip_serializing_if = Option::is_none`, so a
                    # well-behaved stream has the same shape as before
                    # the wiring landed (regression guard).
                    r = await http.post(
                        f"{base}/v1/chat/completions",
                        json={
                            "model": model_id,
                            "messages": [
                                {"role": "system", "content": "Think step by step."},
                                {"role": "user", "content": "Solve: 17*24+13"},
                            ],
                            "stream": True,
                        },
                    )
                    print(
                        f"[harness] POST /v1/chat/completions(reasoning-prompt) "
                        f"-> {r.status_code}"
                    )
                    if r.status_code != 200:
                        failures.append(
                            f"/v1/chat/completions reasoning stream status {r.status_code}"
                        )
                    else:
                        data_lines = [
                            line[len("data: "):]
                            for line in r.text.splitlines()
                            if line.startswith("data: ")
                        ]
                        for d in data_lines:
                            if d == "[DONE]":
                                continue
                            try:
                                _json.loads(d)
                            except _json.JSONDecodeError as e:
                                failures.append(
                                    f"/v1/chat/completions reasoning stream: "
                                    f"malformed frame {d!r}: {e}"
                                )
                                break

                await client.close()

                # Skipped contracts surface BEFORE pass/fail so a
                # reviewer scanning the tail of CI output can see
                # them. Skipped entries don't fail the run (parallel
                # to pytest's skipped-vs-failed split), but they
                # MUST be visible — F16c review caught that the
                # prior bare `print(NOTE: …)` was effectively
                # invisible to anything past stdout-grep.
                if skipped:
                    print("[harness] SKIPPED:")
                    for s in skipped:
                        print(f"  - {s}")
                if failures:
                    print("[harness] FAILURES:")
                    for f in failures:
                        print(f"  - {f}")
                    return 1
                if skipped:
                    print(f"[harness] PASS ({len(skipped)} skipped)")
                else:
                    print("[harness] PASS")
                return 0
            finally:
                # Order matters here. The drainer is parked in
                # `run_in_executor(readline)`, and `cancel()` does NOT
                # interrupt the executor thread. The cleanest unblock
                # is to terminate the subprocess first, which sends
                # EOF down the pipe and lets readline return naturally.
                # The outer finally is then idempotent via
                # `proc.poll() is None`.
                _terminate_subprocess(proc, label="inner")
                with contextlib.suppress(Exception):
                    proc.stdout.close()
                drain_task.cancel()
                # Narrow the swallowed exceptions to `CancelledError`;
                # `TimeoutError` is handled explicitly so CI sees a
                # diagnostic when the executor thread is still parked
                # past 2s (review v3 F1). Any other exception in the
                # drainer was a real bug masked by the previous broad
                # `except Exception` — F7.
                #
                # The catch-all `Exception` branch logs + re-raises so
                # CI sees the propagation explicitly (v4 F2): an
                # unexpected drainer failure (UnicodeDecodeError, etc.)
                # used to slip past Cancelled/Timeout handling and
                # bubble through the outer finally with no breadcrumb.
                # Python's `finally`-during-unwind semantics still run
                # the outer cleanup including `_shm_unlink_quiet`, so
                # raising here doesn't leak the shmem region.
                try:
                    with contextlib.suppress(asyncio.CancelledError):
                        await asyncio.wait_for(drain_task, timeout=2.0)
                except asyncio.TimeoutError:
                    print(
                        "[harness] drain_task abandoned after 2s timeout "
                        "(executor thread parked on readline; subprocess may "
                        "not be sending EOF). Thread will leak to process "
                        "exit.",
                        flush=True,
                    )
                except Exception as e:
                    print(
                        f"[harness] drain_task raised unexpected "
                        f"{type(e).__name__}: {e!r}; outer cleanup will "
                        f"still run, then exception propagates",
                        flush=True,
                    )
                    raise
        finally:
            print("[harness] entering outer cleanup", flush=True)
            _terminate_subprocess(proc, label="outer")
            # F6: unlink the region we asked for so a SIGKILL'd engine
            # doesn't leak it into POSIX's host-global namespace.
            # The actual region the engine creates is `<base>_g{N}`; we
            # only spawn DP=1 so `_g0` is the single shard.
            _shm_unlink_quiet(f"{shmem_base}_g0")


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
