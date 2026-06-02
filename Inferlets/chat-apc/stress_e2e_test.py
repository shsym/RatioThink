"""HTTP API stress + agent-client tool-calling contract E2E suite (#398).

Extends the baseline `e2e_test.py` engine-side coverage with:

  1. Protocol stress for `/v1/chat/completions` (long messages/history,
     malformed/oversized bodies, empty/invalid model, invalid roles,
     out-of-range sampling, unknown fields, large + invalid `tools[]`).
  2. SSE/streaming stress (valid framing under long output, exactly one
     terminal outcome before `[DONE]`, nothing after `[DONE]`, meta-frames
     that never corrupt OpenAI chunk parsing, repeated streams that don't
     cross-contaminate, client-disconnect behavior recorded against #200).
  3. Frequency/concurrency (sequential `/healthz` + `/v1/models` storms,
     repeated `/v1/models/load`, frequent short chats, bounded concurrent
     chats, a request storm with cancellation that must not hang or leak).
  4. Agent-client tool-call CONTRACT — the OpenAI client-side execution
     loop proven deterministically against the dummy driver:
        prompt + forced tool_choice  ->  finish_reason "tool_calls"
          ->  client runs a fake tool  ->  submits the result turn
          ->  receives a final assistant answer.
     Non-streaming + streaming wire shapes are both asserted. The
     `role:"tool"` follow-up shape is a documented gap (chat-apc returns
     400 `tool_role_unsupported`); the contract uses the server's
     documented user-turn path and pins the 400 as a known limitation.

Determinism (no large model required): everything runs against pie's
**dummy driver**. `tool_choice: "required" | {function}` constrains
generation to the model's native tool-call grammar (see
`chat/completions.rs::build_forced_tool_constraint`); the dummy honors the
grammar's per-step logit mask, and the Qwen tool grammar forces a
`<tool_call>{…}</tool_call>` with the name pinned. pie's tool grammar
permits unbounded JSON arguments, and the dummy's uniform-random walk only
closes reliably on the FIRST generation of a fresh engine (seed 42) — so
each FORCED tool call is issued as the first request on its own short-lived
engine. The round-trip's result turn is unconstrained, so it runs as the
second request on the same engine.

Tier: dummy-only → runnable in normal CI (no GGUF weights, no GPU). The
one real-engine smoke that proves production launch wiring lives in
`RealEngineLaunchE2ETests`, not here.

Usage::

    # from the repo root, with the pie_client env + httpx:
    uv run --project Vendor/pie/client/python --with httpx \
        python Inferlets/chat-apc/stress_e2e_test.py
    # or via the make target (self-bootstraps the engine + wasm):
    make test-e2e-http
"""
from __future__ import annotations

import asyncio
import contextlib
import itertools
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import httpx
from pie_client import PieClient

# Reuse the baseline harness's boot + teardown plumbing (handshake parse,
# stdout drain, idempotent SIGINT->SIGKILL teardown, shmem unlink, stamp
# verify, path constants). Importing is side-effect-free — `e2e_test.main`
# only runs under `__main__`.
_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))
import e2e_test as E  # noqa: E402

MODEL = "default"
_BOOT_SEQ = itertools.count()

# Dummy config that AUTO-DISCOVERS arch=qwen3 + vocab from the cached
# Qwen/Qwen3-0.6B config.json (no `arch_name`/`vocab_size` pin). qwen3's
# Instruct has `has_tools:true`, so the tool decoder + native tool-call
# grammar are live — the prerequisite for the scope-4 contract. The
# baseline `e2e_test.py` pins `arch_name="test"` (tools inert) on purpose;
# this suite needs tools, hence the different config.
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

[model.driver]
type = "dummy"
device = ["cpu"]
# Pin the dummy RNG (this is also pie's default) so the first generation
# of each fresh engine deterministically closes the forced tool-call
# grammar — see the module docstring.
random_seed = 42
"""

CALC_TOOL = {
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
}


# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

class Report:
    """Collects pass/fail/skip across sections. `failures` fail the run;
    `skipped` are contracts intentionally not exercised here (e.g. tied to
    an open ticket) and are surfaced but non-fatal — mirrors pytest's
    skipped-vs-failed split and the baseline harness's convention."""

    def __init__(self) -> None:
        self.failures: list[str] = []
        self.skipped: list[str] = []
        self.passed = 0

    def ok(self, cond: bool, msg: str) -> bool:
        if cond:
            self.passed += 1
        else:
            self.failures.append(msg)
        return cond

    def fail(self, msg: str) -> None:
        self.failures.append(msg)

    def skip(self, msg: str) -> None:
        self.skipped.append(msg)


def sse_payloads(text: str) -> list[str]:
    """The `data:` payloads of an SSE response, in order, prefix stripped."""
    return [
        line[len("data: "):]
        for line in text.splitlines()
        if line.startswith("data: ")
    ]


def terminal_chunk(payloads: list[str]) -> tuple[int, dict] | tuple[None, None]:
    """Locate the single chat.completion.chunk carrying a finish_reason.
    Returns (index_in_payloads, parsed_obj) or (None, None)."""
    for i, d in enumerate(payloads):
        if d == "[DONE]":
            continue
        try:
            obj = json.loads(d)
        except json.JSONDecodeError:
            continue
        if obj.get("object") == "chat.completion.chunk":
            if obj["choices"][0].get("finish_reason") is not None:
                return i, obj
    return None, None


# ---------------------------------------------------------------------------
# Engine session
# ---------------------------------------------------------------------------

@contextlib.asynccontextmanager
async def engine_session(label: str):
    """Boot a pie `serve` (dummy driver, qwen3 auto-discover), install the
    prebuilt chat-apc wasm, launch the daemon, and yield its base URL.
    Tears down idempotently (SIGINT->SIGKILL + shmem unlink + tmp rm) so
    multiple sessions in one process don't leak. Each session is a FRESH
    engine (seed-42 RNG reset) — required for deterministic forced
    tool-call closure."""
    n = next(_BOOT_SEQ)
    shmem = f"/pie_398_{os.getpid()}_{n}"
    tmp = Path(tempfile.mkdtemp(prefix=f"chat-apc-398-{label}-"))
    cfg = tmp / "config.toml"
    cfg.write_text(CONFIG_TOML)
    home = tmp / "home"
    home.mkdir()
    env = {**os.environ, "PIE_HOME": str(home), "PIE_SHMEM_NAME": shmem}
    proc = subprocess.Popen(
        [str(E.PIE_BIN), "serve", "--config", str(cfg), "--no-auth", "--debug"],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        env=env,
        bufsize=1,
    )
    drain_task = None
    client = None
    try:
        ws_addr, token = await E._parse_handshake(proc, timeout=45)
        drain_task = asyncio.create_task(E._drain_stdout(proc))
        client = PieClient(f"ws://{ws_addr}")
        await client.connect()
        await client.auth_by_token(token)
        await client.install_program(E.WASM_PATH, E.MANIFEST_PATH, force_overwrite=True)
        port = E._free_port()
        base = f"http://127.0.0.1:{port}"
        await client.launch_daemon("chat-apc@0.1.0", port)
        if not E._wait_for_port(port, timeout=20):
            raise RuntimeError(f"daemon never bound port {port} (session {label})")
        yield base
    finally:
        if client is not None:
            with contextlib.suppress(Exception):
                await client.close()
        E._terminate_subprocess(proc, label=f"{label}-inner")
        with contextlib.suppress(Exception):
            if proc.stdout:
                proc.stdout.close()
        if drain_task is not None:
            drain_task.cancel()
            # `cancel()` makes the awaited task raise `CancelledError`,
            # which is a `BaseException` (NOT caught by `suppress(Exception)`)
            # — suppress it explicitly, alongside a drain that overran.
            with contextlib.suppress(asyncio.CancelledError, asyncio.TimeoutError):
                await asyncio.wait_for(drain_task, timeout=2.0)
        E._terminate_subprocess(proc, label=f"{label}-outer")
        E._shm_unlink_quiet(f"{shmem}_g0")
        shutil.rmtree(tmp, ignore_errors=True)


# ---------------------------------------------------------------------------
# Scope 1 — protocol stress
# ---------------------------------------------------------------------------

async def section_protocol_stress(base: str, http: httpx.AsyncClient, rep: Report) -> None:
    P = "scope1/protocol"

    # very long single user message — long for a 4096-token-context model
    # (the dummy caps max_model_len=4096), but admissible -> 200. (A message
    # that overflows the context is a distinct over-length path; pie waits
    # then times out at request_timeout_secs rather than fast-rejecting, so
    # it isn't exercised in this fast suite.)
    long_msg = "word " * 3000  # ~3k tokens, fits 4096 ctx with room for gen
    r = await http.post(f"{base}/v1/chat/completions", json={
        "model": MODEL, "messages": [{"role": "user", "content": long_msg}],
        "stream": False, "max_tokens": 4,
    })
    rep.ok(r.status_code == 200, f"{P}: long single message -> {r.status_code} (want 200)")

    # long ordered conversation history -> 200.
    history = []
    for i in range(120):
        history.append({"role": "user" if i % 2 == 0 else "assistant",
                        "content": f"turn {i} content"})
    if history[-1]["role"] != "user":
        history.append({"role": "user", "content": "final user turn"})
    r = await http.post(f"{base}/v1/chat/completions", json={
        "model": MODEL, "messages": history, "stream": False, "max_tokens": 4,
    })
    rep.ok(r.status_code == 200, f"{P}: long history ({len(history)} turns) -> {r.status_code} (want 200)")

    # malformed JSON -> 400.
    r = await http.post(f"{base}/v1/chat/completions",
                        content=b"not json", headers={"Content-Type": "application/json"})
    rep.ok(r.status_code == 400, f"{P}: malformed JSON -> {r.status_code} (want 400)")

    # oversized body (> 1 MiB CHAT_MAX_BODY) -> 413.
    r = await http.post(f"{base}/v1/chat/completions",
                        content=b"a" * ((1 << 20) + 2048),
                        headers={"Content-Type": "application/json"})
    rep.ok(r.status_code == 413, f"{P}: oversized body -> {r.status_code} (want 413)")

    # empty messages -> 400.
    r = await http.post(f"{base}/v1/chat/completions",
                        json={"model": MODEL, "messages": [], "stream": False})
    rep.ok(r.status_code == 400, f"{P}: empty messages -> {r.status_code} (want 400)")

    # missing/blank model -> 400 with param=model.
    r = await http.post(f"{base}/v1/chat/completions",
                        json={"model": "  ", "messages": [{"role": "user", "content": "hi"}]})
    ok = r.status_code == 400 and (r.json().get("error", {}).get("param") == "model")
    rep.ok(ok, f"{P}: blank model -> {r.status_code} {r.text[:120]!r} (want 400 param=model)")

    # unknown model -> 404.
    r = await http.post(f"{base}/v1/chat/completions",
                        json={"model": "nope", "messages": [{"role": "user", "content": "hi"}]})
    rep.ok(r.status_code == 404, f"{P}: unknown model -> {r.status_code} (want 404)")

    # invalid role "tool" -> 400 tool_role_unsupported.
    r = await http.post(f"{base}/v1/chat/completions", json={
        "model": MODEL, "messages": [{"role": "tool", "content": "x"}], "stream": False,
    })
    ok = r.status_code == 400 and r.json().get("error", {}).get("code") == "tool_role_unsupported"
    rep.ok(ok, f"{P}: role=tool -> {r.status_code} {r.text[:120]!r} (want 400 tool_role_unsupported)")

    # whitespace-only content -> 400 param messages[i].content.
    r = await http.post(f"{base}/v1/chat/completions", json={
        "model": MODEL, "messages": [{"role": "user", "content": "   "}], "stream": False,
    })
    rep.ok(r.status_code == 400, f"{P}: whitespace content -> {r.status_code} (want 400)")

    # out-of-range sampling params -> 400 with the offending param tagged.
    for field, value in [("temperature", -1.0), ("temperature", 3.0),
                         ("top_p", 0.0), ("top_p", 1.5),
                         ("max_tokens", 0), ("max_tokens", 1_000_000)]:
        r = await http.post(f"{base}/v1/chat/completions", json={
            "model": MODEL, "messages": [{"role": "user", "content": "hi"}],
            "stream": False, field: value,
        })
        ok = r.status_code == 400 and r.json().get("error", {}).get("param") == field
        rep.ok(ok, f"{P}: {field}={value} -> {r.status_code} {r.text[:120]!r} (want 400 param={field})")

    # unknown / unsupported fields are ignored (serde default), not 400.
    r = await http.post(f"{base}/v1/chat/completions", json={
        "model": MODEL, "messages": [{"role": "user", "content": "hi"}],
        "stream": False, "max_tokens": 4,
        "frequency_penalty": 0.5, "presence_penalty": 0.1,
        "n": 1, "user": "abc", "totally_made_up_field": {"x": [1, 2, 3]},
    })
    rep.ok(r.status_code == 200, f"{P}: unknown fields ignored -> {r.status_code} (want 200)")

    # large but valid tools[] schema -> parses (not 400). tool_choice auto.
    big_props = {f"p{i}": {"type": "string", "description": "d" * 200} for i in range(40)}
    big_tool = {"type": "function", "function": {
        "name": "big_tool", "description": "x" * 1000,
        "parameters": {"type": "object", "properties": big_props, "required": list(big_props)[:5]},
    }}
    r = await http.post(f"{base}/v1/chat/completions", json={
        "model": MODEL, "messages": [{"role": "user", "content": "hi"}],
        "stream": False, "max_tokens": 4, "tools": [big_tool], "tool_choice": "auto",
    })
    # Parse-only intent, but a closed allow-set so a 5xx/crash on a valid
    # large payload fails (not just a 400). "Suite fails on bare 500s."
    rep.ok(r.status_code in (200, 404),
           f"{P}: large tools[] schema -> {r.status_code} (want 200/404; 400=parse-fail, 5xx=crash)")

    # invalid tools[] schema (function entry missing required `name`) -> 400.
    r = await http.post(f"{base}/v1/chat/completions", json={
        "model": MODEL, "messages": [{"role": "user", "content": "hi"}],
        "stream": False, "tools": [{"type": "function", "function": {"description": "no name"}}],
    })
    rep.ok(r.status_code == 400, f"{P}: invalid tools[] (no name) -> {r.status_code} (want 400)")


# ---------------------------------------------------------------------------
# Scope 2 — SSE / streaming stress
# ---------------------------------------------------------------------------

def assert_sse_framing(payloads: list[str], rep: Report, ctx: str) -> None:
    """Shared SSE invariants: model_ready first, every non-[DONE] frame is
    valid JSON, exactly one terminal finish_reason, [DONE] is last and
    nothing follows it, no content after the terminal chunk."""
    if not rep.ok(bool(payloads), f"{ctx}: empty SSE body"):
        return
    rep.ok(payloads[0] == '{"event":"model_ready"}',
           f"{ctx}: first frame {payloads[:1]!r} (want model_ready)")
    rep.ok(payloads[-1] == "[DONE]", f"{ctx}: last frame {payloads[-1]!r} (want [DONE])")
    rep.ok(payloads.count("[DONE]") == 1, f"{ctx}: [DONE] count {payloads.count('[DONE]')} (want 1)")

    # every non-[DONE] frame parses as JSON.
    for d in payloads:
        if d == "[DONE]":
            continue
        try:
            json.loads(d)
        except json.JSONDecodeError as e:
            rep.fail(f"{ctx}: malformed SSE frame {d[:80]!r}: {e}")
            return

    # exactly one terminal chunk (finish_reason set), and nothing carrying
    # content/finish after it (before [DONE]).
    finish_idxs = []
    for i, d in enumerate(payloads):
        if d == "[DONE]":
            continue
        obj = json.loads(d)
        if obj.get("object") == "chat.completion.chunk" and obj["choices"][0].get("finish_reason"):
            finish_idxs.append(i)
    if not rep.ok(len(finish_idxs) == 1, f"{ctx}: terminal-chunk count {len(finish_idxs)} (want 1)"):
        return
    term_i = finish_idxs[0]
    fr = json.loads(payloads[term_i])["choices"][0]["finish_reason"]
    rep.ok(fr in ("stop", "length", "tool_calls", "error"),
           f"{ctx}: finish_reason {fr!r} not canonical")
    # only [DONE] (and possibly trailing meta error frames) may follow; no
    # further chat.completion.chunk content frames.
    for d in payloads[term_i + 1:]:
        if d == "[DONE]":
            continue
        obj = json.loads(d)
        if obj.get("object") == "chat.completion.chunk":
            rep.fail(f"{ctx}: content chunk after terminal: {d[:80]!r}")


async def section_sse_stress(base: str, http: httpx.AsyncClient, rep: Report) -> None:
    P = "scope2/sse"

    # baseline stream framing.
    r = await http.post(f"{base}/v1/chat/completions", json={
        "model": MODEL, "messages": [{"role": "user", "content": "hi"}], "stream": True,
    })
    rep.ok(r.headers.get("content-type", "").split(";")[0] == "text/event-stream",
           f"{P}: content-type {r.headers.get('content-type')!r}")
    assert_sse_framing(sse_payloads(r.text), rep, f"{P}/baseline")

    # long output stream — framing holds across many content frames.
    r = await http.post(f"{base}/v1/chat/completions", json={
        "model": MODEL, "messages": [{"role": "user", "content": "tell me a long story"}],
        "stream": True, "max_tokens": 256,
    })
    payloads = sse_payloads(r.text)
    assert_sse_framing(payloads, rep, f"{P}/long")
    content_frames = sum(
        1 for d in payloads if d != "[DONE]" and json.loads(d).get("object") == "chat.completion.chunk"
    )
    rep.ok(content_frames >= 2, f"{P}/long: only {content_frames} chunks (want >=2 under long output)")

    # repeated short streams: each well-formed, ids unique across requests.
    ids = set()
    for k in range(5):
        r = await http.post(f"{base}/v1/chat/completions", json={
            "model": MODEL, "messages": [{"role": "user", "content": f"q{k}"}],
            "stream": True, "max_tokens": 8,
        })
        payloads = sse_payloads(r.text)
        assert_sse_framing(payloads, rep, f"{P}/repeat{k}")
        for d in payloads:
            if d == "[DONE]":
                continue
            obj = json.loads(d)
            if obj.get("object") == "chat.completion.chunk":
                ids.add(obj["id"])
    rep.ok(len(ids) == 5, f"{P}: repeated streams produced {len(ids)} distinct ids (want 5 — no cross-contamination)")

    # meta-frame non-corruption: model_ready is a meta object, NOT a
    # chat.completion.chunk, so a strict OpenAI parser keying on `object`
    # skips it cleanly and still finds the terminal chunk.
    r = await http.post(f"{base}/v1/chat/completions", json={
        "model": MODEL, "messages": [{"role": "user", "content": "hi"}], "stream": True,
    })
    payloads = sse_payloads(r.text)
    mr = json.loads(payloads[0])
    rep.ok(mr.get("event") == "model_ready" and mr.get("object") != "chat.completion.chunk",
           f"{P}: model_ready meta-frame shape {mr!r}")
    _, term = terminal_chunk(payloads)
    rep.ok(term is not None, f"{P}: strict-parser still finds terminal chunk past meta-frames")

    # client disconnect mid-stream: server must SURVIVE (no crash). Per #200
    # the server does not cancel generation on disconnect — recorded as a
    # known gap, not a failure.
    try:
        async with http.stream("POST", f"{base}/v1/chat/completions", json={
            "model": MODEL, "messages": [{"role": "user", "content": "long"}],
            "stream": True, "max_tokens": 256,
        }) as resp:
            n = 0
            async for _ in resp.aiter_lines():
                n += 1
                if n >= 3:
                    break  # abandon the stream early == client disconnect
    except Exception:
        pass
    r = await http.get(f"{base}/healthz")
    rep.ok(r.status_code == 200, f"{P}: engine alive after client disconnect -> {r.status_code}")
    rep.skip(f"{P}: server-side cancellation on client disconnect is a known gap (#200) — "
             f"disconnect does not abort in-flight generation; only survival is asserted here")


# ---------------------------------------------------------------------------
# Scope 3 — frequency / concurrency
# ---------------------------------------------------------------------------

async def section_concurrency(base: str, http: httpx.AsyncClient, rep: Report) -> None:
    P = "scope3/concurrency"

    # many sequential /healthz.
    bad = 0
    for _ in range(50):
        r = await http.get(f"{base}/healthz")
        if r.status_code != 200 or r.json() != {"status": "ok"}:
            bad += 1
    rep.ok(bad == 0, f"{P}: 50 sequential /healthz had {bad} failures")

    # many sequential /v1/models, consistent shape.
    bad = 0
    for _ in range(50):
        r = await http.get(f"{base}/v1/models")
        if r.status_code != 200 or r.json().get("object") != "list":
            bad += 1
    rep.ok(bad == 0, f"{P}: 50 sequential /v1/models had {bad} failures")

    # repeated /v1/models/load on the same model — instant registry lookup.
    bad = 0
    for _ in range(10):
        r = await http.post(f"{base}/v1/models/load", json={"model": MODEL})
        if r.status_code != 200 or 'data: {"event":"model_ready"}' not in r.text \
                or "data: [DONE]" not in r.text:
            bad += 1
    rep.ok(bad == 0, f"{P}: 10 repeated /v1/models/load had {bad} failures")

    # frequent short sequential chats.
    bad = 0
    for k in range(20):
        r = await http.post(f"{base}/v1/chat/completions", json={
            "model": MODEL, "messages": [{"role": "user", "content": f"q{k}"}],
            "stream": False, "max_tokens": 4,
        })
        if r.status_code != 200:
            bad += 1
    rep.ok(bad == 0, f"{P}: 20 frequent short chats had {bad} non-200")

    # bounded concurrent chats — all complete, none 500/hung.
    async def one_chat(k: int):
        return await http.post(f"{base}/v1/chat/completions", json={
            "model": MODEL, "messages": [{"role": "user", "content": f"c{k}"}],
            "stream": False, "max_tokens": 4,
        })
    results = await asyncio.gather(*(one_chat(k) for k in range(8)), return_exceptions=True)
    exc = [r for r in results if isinstance(r, Exception)]
    non200 = [r.status_code for r in results if not isinstance(r, Exception) and r.status_code != 200]
    rep.ok(not exc and not non200,
           f"{P}: 8 concurrent chats -> exceptions={len(exc)} non200={non200} (want all 200)")

    # request storm WITH cancellation: fire concurrent streams, cancel half
    # mid-flight, await the rest, then assert the engine still serves
    # (no hung tasks / process leak). Server-side cancel itself is #200.
    async def one_stream(k: int):
        r = await http.post(f"{base}/v1/chat/completions", json={
            "model": MODEL, "messages": [{"role": "user", "content": f"s{k}"}],
            "stream": True, "max_tokens": 64,
        })
        return r.status_code
    tasks = [asyncio.create_task(one_stream(k)) for k in range(8)]
    await asyncio.sleep(0.05)
    for t in tasks[:4]:
        t.cancel()
    settled = await asyncio.gather(*tasks, return_exceptions=True)
    survived = [s for s in settled if s == 200]
    rep.ok(len(survived) >= 4, f"{P}: storm-with-cancel — {len(survived)} streams completed 200 (want >=4)")
    r = await http.get(f"{base}/healthz")
    rep.ok(r.status_code == 200, f"{P}: engine alive after request storm -> {r.status_code}")


# ---------------------------------------------------------------------------
# Scope 4 — agent-client tool-call contract
# ---------------------------------------------------------------------------

async def section_toolcall_parse(base: str, http: httpx.AsyncClient, rep: Report) -> None:
    """Cheap scope-4 checks that don't need a forced (fresh-engine) call —
    run on the shared engine."""
    P = "scope4/parse"

    # tools[] + tool_choice:"auto" must PARSE (not 400). Outcome stays in
    # the canonical envelope (200 assistant message, or a known 5xx code
    # from the APC wiring); only a 400 (failed deserialize) is wrong.
    r = await http.post(f"{base}/v1/chat/completions", json={
        "model": MODEL, "messages": [{"role": "user", "content": "What is 2+2?"}],
        "stream": False, "max_tokens": 8, "tools": [CALC_TOOL], "tool_choice": "auto",
    })
    # Closed allow-set (not just `!= 400`) so a 5xx crash on a valid
    # tools[] payload fails instead of reporting green.
    rep.ok(r.status_code in (200, 404),
           f"{P}: tools[]+auto -> {r.status_code} (want 200/404; tools[] must deserialize, no 5xx)")

    # role:"tool" follow-up shape is unsupported -> documented 400. Pin it so
    # the gap can't silently change shape.
    r = await http.post(f"{base}/v1/chat/completions", json={
        "model": MODEL,
        "messages": [{"role": "tool", "tool_call_id": "call_x", "content": "4"}],
        "stream": False,
    })
    ok = r.status_code == 400 and r.json().get("error", {}).get("code") == "tool_role_unsupported"
    rep.ok(ok, f"{P}: role=tool gap -> {r.status_code} {r.text[:120]!r} (want 400 tool_role_unsupported)")
    rep.skip("scope4: OpenAI-native role=\"tool\"+tool_call_id follow-up is a documented gap "
             "(chat-apc returns 400 tool_role_unsupported); contract uses the server's user-turn "
             "path. Native tool-result turn tracked as a follow-up (SDK answer_prefix unwired).")

    # tool_choice forcing a call but the named function is absent -> 400.
    r = await http.post(f"{base}/v1/chat/completions", json={
        "model": MODEL, "messages": [{"role": "user", "content": "hi"}], "stream": False,
        "tools": [CALC_TOOL],
        "tool_choice": {"type": "function", "function": {"name": "ghost"}},
    })
    rep.ok(r.status_code == 400, f"{P}: forced choice of absent tool -> {r.status_code} (want 400)")

    # tool_choice:"required" with empty tools[] -> 400.
    r = await http.post(f"{base}/v1/chat/completions", json={
        "model": MODEL, "messages": [{"role": "user", "content": "hi"}], "stream": False,
        "tool_choice": "required",
    })
    rep.ok(r.status_code == 400, f"{P}: required + empty tools -> {r.status_code} (want 400)")

    # F1 (v2 review): a forced call that CANNOT close the tool-call grammar
    # within max_tokens (here 1; the args object can't complete) must NOT be
    # a silent empty 200. Content is suppressed on the forced path, so the
    # contract requires either tool_calls OR an explicit error — never a
    # deceptive empty completion that drops the directive.
    r = await http.post(f"{base}/v1/chat/completions", json={
        "model": MODEL, "messages": [{"role": "user", "content": "What is 2+2?"}],
        "stream": False, "max_tokens": 1,
        "tools": [CALC_TOOL], "tool_choice": "required",
    })
    if r.status_code == 200:
        tcs = r.json().get("choices", [{}])[0].get("message", {}).get("tool_calls")
        rep.ok(bool(tcs),
               f"{P}: forced+max_tokens=1 returned a SILENT EMPTY 200 (no tool_calls, no error) "
               f"— directive dropped: {r.text[:160]!r}")
    else:
        code = ""
        try:
            code = r.json().get("error", {}).get("code", "")
        except Exception:
            pass
        rep.ok(r.status_code in (500, 502) and code == "tool_call_not_produced",
               f"{P}: forced unfulfilled -> {r.status_code} code={code!r} "
               f"(want 500/502 tool_call_not_produced)")

    # Same, streaming: the terminal frame must carry finish_reason "error"
    # (+ tool_call_not_produced meta) or tool_calls — never a clean
    # "stop"/"length" with an empty content channel.
    r = await http.post(f"{base}/v1/chat/completions", json={
        "model": MODEL, "messages": [{"role": "user", "content": "What is 2+2?"}],
        "stream": True, "max_tokens": 1,
        "tools": [CALC_TOOL],
        "tool_choice": {"type": "function", "function": {"name": "calculator"}},
    })
    if rep.ok(r.status_code == 200, f"{P}: forced stream unfulfilled status {r.status_code}"):
        _, term = terminal_chunk(sse_payloads(r.text))
        if rep.ok(term is not None, f"{P}: forced stream unfulfilled: no terminal chunk"):
            ch = term["choices"][0]
            fr = ch.get("finish_reason")
            has_tc = bool(ch.get("delta", {}).get("tool_calls"))
            rep.ok(fr == "error" or has_tc,
                   f"{P}: forced stream unfulfilled terminal finish_reason={fr!r} "
                   f"tool_calls={has_tc} (want \"error\" or tool_calls — not a silent stop/length)")


async def section_toolcall_nonstream_roundtrip(rep: Report) -> None:
    """Fresh engine: forced non-stream tool call (FIRST gen -> deterministic
    closure) proves the non-stream tool wire shape; the follow-up user turn
    (2nd gen, unconstrained) proves the client can submit a tool result and
    receive a final assistant answer."""
    P = "scope4/nonstream"
    async with engine_session("toolA") as base:
        async with httpx.AsyncClient(timeout=60) as http:
            # TURN 1: force a tool call.
            r = await http.post(f"{base}/v1/chat/completions", json={
                "model": MODEL, "messages": [{"role": "user", "content": "What is 2+2?"}],
                "stream": False, "max_tokens": 512,
                "tools": [CALC_TOOL], "tool_choice": "required",
            })
            if not rep.ok(r.status_code == 200, f"{P}: turn1 -> {r.status_code} {r.text[:160]!r}"):
                return
            body = r.json()
            choice = body["choices"][0]
            msg = choice["message"]
            rep.ok(choice.get("finish_reason") == "tool_calls",
                   f"{P}: finish_reason {choice.get('finish_reason')!r} (want tool_calls)")
            rep.ok(msg.get("role") == "assistant", f"{P}: role {msg.get('role')!r}")
            rep.ok((msg.get("content") or "") == "",
                   f"{P}: content {msg.get('content')!r} (want empty alongside tool_calls)")
            tcs = msg.get("tool_calls")
            if rep.ok(bool(tcs) and len(tcs) == 1, f"{P}: tool_calls {tcs!r} (want exactly 1)"):
                tc = tcs[0]
                rep.ok(isinstance(tc.get("id"), str) and tc["id"],
                       f"{P}: tool_call id {tc.get('id')!r}")
                rep.ok(tc.get("type") == "function", f"{P}: tool_call type {tc.get('type')!r}")
                fn = tc.get("function", {})
                rep.ok(fn.get("name") == "calculator",
                       f"{P}: function.name {fn.get('name')!r} (want calculator — grammar pins it)")
                try:
                    parsed = json.loads(fn.get("arguments", ""))
                    rep.ok(isinstance(parsed, dict),
                           f"{P}: arguments not a JSON object: {fn.get('arguments')!r}")
                except (json.JSONDecodeError, TypeError):
                    rep.fail(f"{P}: arguments not parseable JSON: {fn.get('arguments')!r}")

            # TURN 2: client ran the tool; submit the result as a user turn
            # (server's documented path) and expect a final assistant answer.
            r = await http.post(f"{base}/v1/chat/completions", json={
                "model": MODEL,
                "messages": [
                    {"role": "user", "content": "What is 2+2?"},
                    {"role": "assistant", "content": "Let me use the calculator."},
                    {"role": "user", "content": "Tool calculator returned: 4. Now answer."},
                ],
                "stream": False, "max_tokens": 32,
            })
            if rep.ok(r.status_code == 200, f"{P}: turn2 -> {r.status_code} {r.text[:160]!r}"):
                ch = r.json()["choices"][0]
                rep.ok(ch.get("finish_reason") in ("stop", "length"),
                       f"{P}: turn2 finish_reason {ch.get('finish_reason')!r}")
                rep.ok(len(ch["message"].get("content") or "") > 0,
                       f"{P}: turn2 produced no final assistant answer")


async def section_toolcall_stream(rep: Report) -> None:
    """Fresh engine: forced STREAM tool call (FIRST gen) proves the
    streaming tool wire shape — the terminal chunk carries the tool_calls
    delta with index/id/type/function, content is suppressed, and the
    stream still satisfies the SSE framing invariants."""
    P = "scope4/stream"
    async with engine_session("toolB") as base:
        async with httpx.AsyncClient(timeout=60) as http:
            r = await http.post(f"{base}/v1/chat/completions", json={
                "model": MODEL, "messages": [{"role": "user", "content": "What is 2+2?"}],
                "stream": True, "max_tokens": 512,
                "tools": [CALC_TOOL],
                "tool_choice": {"type": "function", "function": {"name": "calculator"}},
            })
            if not rep.ok(r.status_code == 200, f"{P}: stream -> {r.status_code} {r.text[:160]!r}"):
                return
            payloads = sse_payloads(r.text)
            assert_sse_framing(payloads, rep, P)
            _, term = terminal_chunk(payloads)
            if not rep.ok(term is not None, f"{P}: no terminal chunk: {payloads!r}"):
                return
            choice = term["choices"][0]
            rep.ok(choice.get("finish_reason") == "tool_calls",
                   f"{P}: finish_reason {choice.get('finish_reason')!r} (want tool_calls)")
            tcs = choice.get("delta", {}).get("tool_calls")
            if rep.ok(bool(tcs) and len(tcs) == 1, f"{P}: delta.tool_calls {tcs!r} (want exactly 1)"):
                tc = tcs[0]
                rep.ok(tc.get("index") == 0, f"{P}: tool_call index {tc.get('index')!r} (want 0)")
                rep.ok(isinstance(tc.get("id"), str) and tc["id"], f"{P}: id {tc.get('id')!r}")
                rep.ok(tc.get("type") == "function", f"{P}: type {tc.get('type')!r}")
                fn = tc.get("function", {})
                rep.ok(fn.get("name") == "calculator", f"{P}: function.name {fn.get('name')!r}")
                try:
                    json.loads(fn.get("arguments", ""))
                except (json.JSONDecodeError, TypeError):
                    rep.fail(f"{P}: streamed arguments not parseable JSON: {fn.get('arguments')!r}")
            # No visible content should have leaked on the content channel.
            leaked = []
            for d in payloads:
                if d == "[DONE]":
                    continue
                obj = json.loads(d)
                if obj.get("object") == "chat.completion.chunk":
                    c = obj["choices"][0].get("delta", {}).get("content")
                    if c:
                        leaked.append(c)
            rep.ok(not leaked, f"{P}: tool-call markup leaked as content: {leaked[:3]!r}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

async def main() -> int:
    # Self-bootstrap preflight: fail loud with the fix command, never a
    # silent skip (mirrors the repo's wrapper convention).
    missing = []
    if not E.PIE_BIN.exists():
        missing.append(f"pie binary at {E.PIE_BIN}\n    fix: make engine-build")
    if not E.WASM_PATH.exists():
        missing.append(f"chat-apc wasm at {E.WASM_PATH}\n    fix: Scripts/stamp-chat-apc.sh write")
    if missing:
        print("[stress-e2e] PREFLIGHT FAILED — missing prerequisites:")
        for m in missing:
            print(f"  - {m}")
        return 2
    try:
        E.verify_stamp()
    except Exception as e:
        print(f"[stress-e2e] PREFLIGHT FAILED — wasm stamp mismatch: {e}\n"
              f"    fix: Scripts/stamp-chat-apc.sh write")
        return 2

    rep = Report()

    # Shared engine for scope 1-3 + the cheap scope-4 parse/gap checks.
    print("[stress-e2e] booting shared engine (scope 1-3 + scope-4 parse)…", flush=True)
    async with engine_session("shared") as base:
        async with httpx.AsyncClient(timeout=60) as http:
            for name, fn in [
                ("protocol-stress", section_protocol_stress),
                ("sse-stress", section_sse_stress),
                ("concurrency", section_concurrency),
                ("toolcall-parse", section_toolcall_parse),
            ]:
                print(f"[stress-e2e] section: {name}", flush=True)
                try:
                    await fn(base, http, rep)
                except Exception as e:
                    rep.fail(f"section {name} raised {type(e).__name__}: {e}")

    # Fresh engines for the forced (deterministic) tool-call contract.
    for name, fn in [
        ("toolcall-nonstream-roundtrip", section_toolcall_nonstream_roundtrip),
        ("toolcall-stream", section_toolcall_stream),
    ]:
        print(f"[stress-e2e] section: {name} (fresh engine)", flush=True)
        try:
            await fn(rep)
        except Exception as e:
            rep.fail(f"section {name} raised {type(e).__name__}: {e}")

    # Report. Skipped first (visible but non-fatal), then failures.
    if rep.skipped:
        print("\n[stress-e2e] SKIPPED / known gaps:")
        for s in rep.skipped:
            print(f"  - {s}")
    if rep.failures:
        print(f"\n[stress-e2e] FAILURES ({len(rep.failures)}):")
        for f in rep.failures:
            print(f"  - {f}")
        print(f"\n[stress-e2e] RESULT: FAIL ({rep.passed} passed, "
              f"{len(rep.failures)} failed, {len(rep.skipped)} skipped)")
        return 1
    print(f"\n[stress-e2e] RESULT: PASS ({rep.passed} passed, {len(rep.skipped)} skipped)")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
