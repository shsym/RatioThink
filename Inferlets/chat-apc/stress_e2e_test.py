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
     frequent short chats, bounded concurrent
     chats, a request storm with cancellation that must not hang or leak).
  4. Agent-client tool-call CONTRACT — the OpenAI client-side execution
     loop proven deterministically against the dummy driver:
        prompt + forced tool_choice  ->  finish_reason "tool_calls"
          ->  client runs a fake tool  ->  submits the result turn
          ->  receives a final assistant answer.
     Non-streaming + streaming wire shapes are both asserted. The
     continuation uses the OpenAI-native history shape: assistant
     `tool_calls`, then `role:"tool"` with the matching `tool_call_id`.
  5. Harsh live-surface evaluation (#467) — the malformed/abusive inputs a
     normal SDK never sends, on the no-auth loopback surface: HTTP method
     abuse, the closed-CORS security posture (no `Access-Control-*`),
     JSON type confusion, structural abuse + nested-value recursion DoS,
     hostile content (NUL/emoji/control/RTL), and removed-endpoint (`/v1/models/load`) 404 abuse.
     Every case must fail as a 4xx JSON envelope (never a bare 5xx, hang,
     or crash) and the engine must still serve afterward.

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

    # wrong model for the resident engine -> 409 target_mismatch.
    r = await http.post(f"{base}/v1/chat/completions",
                        json={"model": "nope", "messages": [{"role": "user", "content": "hi"}]})
    ok = r.status_code == 409 and r.json().get("error", {}).get("code") == "target_mismatch"
    rep.ok(ok, f"{P}: unknown model -> {r.status_code} {r.text[:120]!r} (want 409 target_mismatch)")

    # Orphan role "tool" -> 400 with a precise tool_call_id param.
    r = await http.post(f"{base}/v1/chat/completions", json={
        "model": MODEL, "messages": [{"role": "tool", "content": "x"}], "stream": False,
    })
    err = r.json().get("error", {}) if r.status_code == 400 else {}
    ok = (
        r.status_code == 400
        and err.get("code") == "missing_tool_call_id"
        and err.get("param") == "messages[0].tool_call_id"
    )
    rep.ok(ok, f"{P}: orphan role=tool -> {r.status_code} {r.text[:120]!r} "
               "(want 400 missing_tool_call_id param=messages[0].tool_call_id)")

    # unknown role (#468) -> 400 unsupported_role, NOT a silently mis-templated
    # 200. `developer` is included: OpenAI accepts it but the chat template has
    # no slot, so chat-apc rejects rather than demote it to `user`.
    for bad_role in ("banana", "developer"):
        r = await http.post(f"{base}/v1/chat/completions", json={
            "model": MODEL, "messages": [{"role": bad_role, "content": "hi"}], "stream": False,
        })
        ok = r.status_code == 400 and r.json().get("error", {}).get("code") == "unsupported_role"
        rep.ok(ok, f"{P}: role={bad_role} -> {r.status_code} {r.text[:120]!r} (want 400 unsupported_role)")

    # #468: the tree-of-thought dispatch path (POST /v1/inferlet) shares
    # `fill_context`, so the same unknown-role rejection must hold there —
    # NOT a 500, and not a silently mis-templated tree.
    for bad_role in ("banana", "developer"):
        r = await http.post(f"{base}/v1/inferlet", json={
            "inferlet": "tree-of-thought", "stream": False,
            "input": {"messages": [{"role": bad_role, "content": "hi"}]},
        })
        ok = r.status_code == 400 and r.json().get("error", {}).get("code") == "unsupported_role"
        rep.ok(ok, f"{P}: tot role={bad_role} -> {r.status_code} {r.text[:120]!r} (want 400 unsupported_role)")

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

async def section_content_parts(base: str, http: httpx.AsyncClient, rep: Report) -> None:
    """OpenAI multi-part `messages[].content` arrays (PR #115): the array
    form must behave exactly like its flattened-string equivalent on both
    the non-stream and stream paths, and malformed parts must 400 at the
    request boundary."""
    P = "scope6/content-parts"

    # non-stream: single text part -> 200, completion shape intact.
    r = await http.post(f"{base}/v1/chat/completions", json={
        "model": MODEL, "stream": False, "max_tokens": 4,
        "messages": [{"role": "user",
                      "content": [{"type": "text", "text": "hello"}]}],
    })
    ok = r.status_code == 200 and r.json().get("object") == "chat.completion"
    rep.ok(ok, f"{P}: single text part (non-stream) -> {r.status_code} (want 200 chat.completion)")

    # non-stream: multi-part array across roles -> 200 (order/separators are
    # unit-tested; here we prove the wire accepts the multi-part shape on
    # every templated role).
    r = await http.post(f"{base}/v1/chat/completions", json={
        "model": MODEL, "stream": False, "max_tokens": 4,
        "messages": [
            {"role": "system",
             "content": [{"type": "text", "text": "be "}, {"type": "text", "text": "brief"}]},
            {"role": "user",
             "content": [{"type": "text", "text": "two "}, {"type": "text", "text": "parts"}]},
        ],
    })
    rep.ok(r.status_code == 200, f"{P}: multi-part system+user -> {r.status_code} (want 200)")

    # concatenation is observable on the wire via the blank-content gate:
    # all-whitespace parts flatten to a blank string -> 400, while the same
    # array plus one non-blank part -> 200. Both parts must therefore have
    # contributed to the flattened content.
    r = await http.post(f"{base}/v1/chat/completions", json={
        "model": MODEL, "stream": False, "max_tokens": 4,
        "messages": [{"role": "user",
                      "content": [{"type": "text", "text": " "}, {"type": "text", "text": " "}]}],
    })
    rep.ok(r.status_code == 400,
           f"{P}: all-whitespace parts flatten blank -> {r.status_code} (want 400 blank-content gate)")
    r = await http.post(f"{base}/v1/chat/completions", json={
        "model": MODEL, "stream": False, "max_tokens": 4,
        "messages": [{"role": "user",
                      "content": [{"type": "text", "text": " "}, {"type": "text", "text": "x"}]}],
    })
    rep.ok(r.status_code == 200,
           f"{P}: same array + one non-blank part -> {r.status_code} (want 200 — proves concatenation)")

    # empty array flattens to "" -> same 400 as content:"".
    r = await http.post(f"{base}/v1/chat/completions", json={
        "model": MODEL, "stream": False, "max_tokens": 4,
        "messages": [{"role": "user", "content": []}],
    })
    rep.ok(r.status_code == 400, f"{P}: empty content array -> {r.status_code} (want 400)")

    # non-text part types are accepted but contribute no text.
    r = await http.post(f"{base}/v1/chat/completions", json={
        "model": MODEL, "stream": False, "max_tokens": 4,
        "messages": [{"role": "user", "content": [
            {"type": "image_url", "image_url": {"url": "http://x/y.png"}},
            {"type": "text", "text": "caption"},
        ]}],
    })
    rep.ok(r.status_code == 200, f"{P}: image_url part + text part -> {r.status_code} (want 200)")

    # image-only array: with no text part the flattened content is "" and
    # the blank-content gate 400s — black-box proof that non-text parts
    # really contribute no text (the mixed case above would pass even if
    # the image part leaked text).
    r = await http.post(f"{base}/v1/chat/completions", json={
        "model": MODEL, "stream": False, "max_tokens": 4,
        "messages": [{"role": "user", "content": [
            {"type": "image_url", "image_url": {"url": "http://x/y.png"}},
        ]}],
    })
    rep.ok(r.status_code == 400,
           f"{P}: image_url-only array flattens blank -> {r.status_code} (want 400 — proves no text contributed)")

    # malformed part (non-object element) -> 400, never a silently dropped part.
    for bad, label in (
        (["bare string"], "bare-string part"),
        ([{"type": "text", "text": "ok"}, 7], "mixed valid+scalar part"),
        ({"type": "text", "text": "x"}, "object (non-array) content"),
        (42, "numeric content"),
    ):
        r = await http.post(f"{base}/v1/chat/completions", json={
            "model": MODEL, "stream": False, "max_tokens": 4,
            "messages": [{"role": "user", "content": bad}],
        })
        rep.ok(r.status_code == 400, f"{P}: {label} -> {r.status_code} (want 400)")

    # stream path: multi-part array -> 200 + well-formed SSE with a terminal
    # finish_reason (the branch split is post-parse; this proves it end-to-end).
    r = await http.post(f"{base}/v1/chat/completions", json={
        "model": MODEL, "stream": True, "max_tokens": 8,
        "messages": [{"role": "user",
                      "content": [{"type": "text", "text": "two "}, {"type": "text", "text": "parts"}]}],
    })
    rep.ok(r.headers.get("content-type", "").split(";")[0] == "text/event-stream",
           f"{P}/stream: content-type {r.headers.get('content-type')!r}")
    assert_sse_framing(sse_payloads(r.text), rep, f"{P}/stream")

    # stream path: malformed part still 400s (no SSE leak before the gate).
    r = await http.post(f"{base}/v1/chat/completions", json={
        "model": MODEL, "stream": True, "max_tokens": 8,
        "messages": [{"role": "user", "content": ["bare string"]}],
    })
    rep.ok(r.status_code == 400, f"{P}/stream: bare-string part -> {r.status_code} (want 400)")


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

    # #572 JSON Think: streaming response_format engages the two-phase
    # constrained decode. The dummy samples randomly WITHIN the JSON grammar
    # mask, so the concatenated content is grammar-valid JSON (a value or a
    # value-prefix under max_tokens truncation). Deterministic invariants:
    #   · SSE framing stays valid (exactly one terminal finish_reason, [DONE]),
    #   · content deltas concatenate to something beginning with a JSON value,
    #   · NO `<think>`/`</think>` ever appears in the content channel (reasoning
    #     rides `reasoning_content` only).
    r = await http.post(f"{base}/v1/chat/completions", json={
        "model": MODEL, "messages": [{"role": "user", "content": "give me json"}],
        "stream": True, "max_tokens": 64, "response_format": {"type": "json_object"},
    })
    rep.ok(r.headers.get("content-type", "").split(";")[0] == "text/event-stream",
           f"{P}/json: content-type {r.headers.get('content-type')!r}")
    payloads = sse_payloads(r.text)
    assert_sse_framing(payloads, rep, f"{P}/json")
    content = ""
    for d in payloads:
        if d == "[DONE]":
            continue
        obj = json.loads(d)
        if obj.get("object") != "chat.completion.chunk":
            continue
        delta = obj["choices"][0].get("delta", {})
        if delta.get("content"):
            content += delta["content"]
    rep.ok("<think>" not in content and "</think>" not in content,
           f"{P}/json: reasoning delimiter leaked into streamed content: {content!r}")
    stripped = content.lstrip()
    rep.ok(not stripped or stripped[0] in '{["-0123456789tfn',
           f"{P}/json: streamed content does not begin with a JSON value: {content!r}")
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

    # #469: /v1/models/load is REMOVED (pie binds the model at boot). Hammer
    # the removed route to prove it stays a clean 404, not a 500/hang.
    bad = 0
    for _ in range(10):
        r = await http.post(f"{base}/v1/models/load", json={"model": MODEL})
        if r.status_code != 404:
            bad += 1
    rep.ok(bad == 0, f"{P}: 10 repeated /v1/models/load (removed) had {bad} non-404")

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

    # role:"tool" without preceding assistant tool_calls is still malformed;
    # the OpenAI-compatible path requires preserving the assistant call ID.
    r = await http.post(f"{base}/v1/chat/completions", json={
        "model": MODEL,
        "messages": [{"role": "tool", "tool_call_id": "call_x", "content": "4"}],
        "stream": False,
    })
    err = r.json().get("error", {}) if r.status_code == 400 else {}
    ok = (
        r.status_code == 400
        and err.get("code") == "unknown_tool_call_id"
        and err.get("param") == "messages[0].tool_call_id"
    )
    rep.ok(ok, f"{P}: orphan role=tool -> {r.status_code} {r.text[:120]!r} "
               "(want 400 unknown_tool_call_id param=messages[0].tool_call_id)")

    malformed_tool_calls = [
        (
            {"type": "function", "function": {"name": "calculator", "arguments": "{}"}},
            "messages[0].tool_calls[0].id",
        ),
        (
            {"id": "call_x", "function": {"name": "calculator", "arguments": "{}"}},
            "messages[0].tool_calls[0].type",
        ),
        (
            {"id": "call_x", "type": "function"},
            "messages[0].tool_calls[0].function",
        ),
        (
            {"id": "call_x", "type": "function", "function": {"arguments": "{}"}},
            "messages[0].tool_calls[0].function.name",
        ),
        (
            {"id": "call_x", "type": "function", "function": {"name": "calculator"}},
            "messages[0].tool_calls[0].function.arguments",
        ),
        (
            {"id": 123, "type": "function", "function": {"name": "calculator", "arguments": "{}"}},
            "messages[0].tool_calls[0].id",
        ),
        (
            {"id": "call_x", "type": 7, "function": {"name": "calculator", "arguments": "{}"}},
            "messages[0].tool_calls[0].type",
        ),
        (
            {"id": "call_x", "type": "function", "function": []},
            "messages[0].tool_calls[0].function",
        ),
        (
            {"id": "call_x", "type": "function", "function": {"name": {}, "arguments": "{}"}},
            "messages[0].tool_calls[0].function.name",
        ),
    ]
    for tool_call, param in malformed_tool_calls:
        r = await http.post(f"{base}/v1/chat/completions", json={
            "model": MODEL,
            "messages": [{"role": "assistant", "content": None, "tool_calls": [tool_call]}],
            "stream": False,
        })
        err = r.json().get("error", {}) if r.status_code == 400 else {}
        ok = (
            r.status_code == 400
            and err.get("code") == "malformed_tool_calls"
            and err.get("param") == param
        )
        rep.ok(ok, f"{P}: malformed tool_call param={param} -> {r.status_code} {r.text[:160]!r}")

    malformed_continuation_fields = [
        (
            [{"role": "user", "content": "hi", "tool_call_id": "call_x"}],
            "messages[0].tool_call_id",
        ),
        (
            [{"role": "assistant", "content": "hi", "tool_call_id": "call_x"}],
            "messages[0].tool_call_id",
        ),
        (
            [{"role": "future", "content": "hi", "tool_calls": [
                {"id": "call_x", "type": "function", "function": {"name": "calculator", "arguments": "{}"}}
            ]}],
            "messages[0].tool_calls",
        ),
        (
            [{"role": "user", "content": "hi", "tool_call_id": 123}],
            "messages[0].tool_call_id",
        ),
        (
            [{"role": "assistant", "content": None, "tool_calls": {}}],
            "messages[0].tool_calls",
        ),
        (
            [{"role": "assistant", "content": None, "tool_calls": [None]}],
            "messages[0].tool_calls",
        ),
    ]
    for messages, param in malformed_continuation_fields:
        r = await http.post(f"{base}/v1/chat/completions", json={
            "model": MODEL,
            "messages": messages,
            "stream": False,
        })
        err = r.json().get("error", {}) if r.status_code == 400 else {}
        ok = (
            r.status_code == 400
            and err.get("code") == "malformed_tool_calls"
            and err.get("param") == param
        )
        rep.ok(ok, f"{P}: malformed continuation field param={param} -> "
                   f"{r.status_code} {r.text[:160]!r}")

    r = await http.post(f"{base}/v1/chat/completions", json={
        "model": MODEL,
        "messages": [
            {"role": "assistant", "content": None, "tool_calls": [
                {"id": "call_a", "type": "function", "function": {"name": "calculator", "arguments": "{\"expr\":\"2+2\"}"}},
                {"id": "call_b", "type": "function", "function": {"name": "calculator", "arguments": "{\"expr\":\"3+3\"}"}},
            ]},
            {"role": "tool", "tool_call_id": "call_b", "content": "6"},
            {"role": "tool", "tool_call_id": "call_a", "content": "4"},
        ],
        "stream": False,
    })
    err = r.json().get("error", {}) if r.status_code == 400 else {}
    ok = (
        r.status_code == 400
        and err.get("code") == "invalid_tool_order"
        and err.get("param") == "messages[1].tool_call_id"
    )
    rep.ok(ok, f"{P}: out-of-order tool results -> {r.status_code} {r.text[:160]!r} "
               "(want 400 invalid_tool_order param=messages[1].tool_call_id)")

    r = await http.post(f"{base}/v1/inferlet", json={
        "inferlet": "tree-of-thought",
        "stream": False,
        "input": {
            "model": MODEL,
            "messages": [{"role": "assistant", "content": None, "tool_calls": [
                {"id": 123, "type": "function", "function": {"name": "calculator", "arguments": "{}"}}
            ]}],
            "breadth": 1,
            "depth": 1,
            "beam_width": 1,
            "max_tokens_per_node": 1,
        },
    })
    err = r.json().get("error", {}) if r.status_code == 400 else {}
    ok = (
        r.status_code == 400
        and err.get("code") == "malformed_tool_calls"
        and err.get("param") == "messages[0].tool_calls[0].id"
    )
    rep.ok(ok, f"{P}: ToT malformed assistant tool_call -> {r.status_code} {r.text[:160]!r} "
               "(want 400 malformed_tool_calls param=messages[0].tool_calls[0].id)")

    r = await http.post(f"{base}/v1/inferlet", json={
        "inferlet": "tree-of-thought",
        "stream": False,
        "input": {
            "model": MODEL,
            "messages": [{"role": "user", "content": "hi", "tool_calls": [
                {"id": "call_x", "type": "function", "function": {"name": "calculator", "arguments": "{}"}}
            ]}],
            "breadth": 1,
            "depth": 1,
            "beam_width": 1,
            "max_tokens_per_node": 1,
        },
    })
    err = r.json().get("error", {}) if r.status_code == 400 else {}
    ok = (
        r.status_code == 400
        and err.get("code") == "malformed_tool_calls"
        and err.get("param") == "messages[0].tool_calls"
    )
    rep.ok(ok, f"{P}: ToT user tool_calls rejected at boundary -> {r.status_code} {r.text[:160]!r} "
               "(want 400 malformed_tool_calls param=messages[0].tool_calls)")

    for messages, param in [
        (
            [{"role": "user", "content": "hi", "tool_call_id": 123}],
            "messages[0].tool_call_id",
        ),
        (
            [{"role": "assistant", "content": None, "tool_calls": {}}],
            "messages[0].tool_calls",
        ),
        (
            [{"role": "assistant", "content": None, "tool_calls": [None]}],
            "messages[0].tool_calls",
        ),
    ]:
        r = await http.post(f"{base}/v1/inferlet", json={
            "inferlet": "tree-of-thought",
            "stream": False,
            "input": {
                "model": MODEL,
                "messages": messages,
                "breadth": 1,
                "depth": 1,
                "beam_width": 1,
                "max_tokens_per_node": 1,
            },
        })
        err = r.json().get("error", {}) if r.status_code == 400 else {}
        ok = (
            r.status_code == 400
            and err.get("code") == "malformed_tool_calls"
            and err.get("param") == param
        )
        rep.ok(ok, f"{P}: ToT malformed continuation container param={param} -> "
                   f"{r.status_code} {r.text[:160]!r}")

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

            if not (tcs and len(tcs) == 1):
                return
            tc = tcs[0]

            # TURN 2: client ran the tool; submit OpenAI-native history with
            # the assistant tool_calls message plus a role=tool result carrying
            # the matching tool_call_id. Expect a normal assistant answer.
            r = await http.post(f"{base}/v1/chat/completions", json={
                "model": MODEL,
                "messages": [
                    {"role": "user", "content": "What is 2+2?"},
                    {
                        "role": "assistant",
                        "content": msg.get("content"),
                        "tool_calls": tcs,
                    },
                    {"role": "tool", "tool_call_id": tc["id"], "content": "4"},
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
# Scope 5 — harsh live-surface evaluation (#467)
#
# The local API binds 127.0.0.1 with [auth] enabled=false (see
# PieControlLauncher.renderConfigBody + LocalAPIStateTests): a no-auth
# loopback surface whose threat model is a hostile/buggy LOCAL client
# (a script, or a website driving it via the user's browser). #398 above
# covers the well-formed-but-extreme inputs; this scope covers the truly
# malformed/abusive ones a normal SDK never sends, and pins the security
# posture. Every case must fail CLEANLY — a 4xx JSON envelope, never a
# bare 5xx, a hang, or a crash — and the engine must still serve afterward.
# All assertions encode behavior MEASURED against the dummy engine.
# ---------------------------------------------------------------------------

async def section_harsh_surface(base: str, http: httpx.AsyncClient, rep: Report) -> None:
    P = "scope5/harsh"

    # ── G1: HTTP method abuse. The router matches on (method, path); any
    # other pairing falls through to the JSON `endpoint_not_found` 404
    # (lib.rs `not_found`, F11). A wrong method must NEVER 405-with-no-body,
    # return bare text/plain, or 5xx — it must be the same structured 404
    # envelope an OpenAI client can JSON.parse on a non-2xx.
    method_abuse = [
        ("GET", "/v1/chat/completions"), ("PUT", "/v1/chat/completions"),
        ("DELETE", "/v1/chat/completions"), ("OPTIONS", "/v1/chat/completions"),
        ("POST", "/v1/models"), ("POST", "/healthz"),
        ("PATCH", "/v1/models/load"), ("GET", "/v1/models/load"),
    ]
    for method, route in method_abuse:
        r = await http.request(method, f"{base}{route}", json={})
        code = ""
        try:
            code = r.json().get("error", {}).get("code", "")
        except Exception:
            pass
        rep.ok(r.status_code == 404 and code == "endpoint_not_found",
               f"{P}/method: {method} {route} -> {r.status_code} code={code!r} "
               f"(want 404 endpoint_not_found)")
    # HEAD has no response body to parse, but must still 404 (not 405/crash).
    r = await http.head(f"{base}/v1/chat/completions")
    rep.ok(r.status_code == 404, f"{P}/method: HEAD -> {r.status_code} (want 404)")

    # ── G2: CORS posture (security). The engine ships NO CORS handler
    # (no OPTIONS route, no Access-Control-* headers — verified absent in
    # both the inferlet and pie's host HTTP layer). For a no-auth loopback
    # API that is the SAFE posture: a malicious website's cross-origin JS
    # is preflight-blocked and cannot read responses. Pin it so a future
    # change can't silently open the local model to drive-by browser
    # attacks. An OPTIONS preflight is just an unmatched method -> 404.
    pre = await http.options(f"{base}/v1/chat/completions", headers={
        "Origin": "https://evil.example",
        "Access-Control-Request-Method": "POST",
        "Access-Control-Request-Headers": "content-type",
    })
    rep.ok(pre.status_code == 404 and "access-control-allow-origin" not in pre.headers,
           f"{P}/cors: preflight -> {pre.status_code} "
           f"acao={pre.headers.get('access-control-allow-origin')!r} (want 404, no ACAO)")
    # A real cross-origin request executes (no preflight for a simple GET),
    # but the response must NOT grant the origin read access via ACAO.
    for label, coro in [
        ("chat", http.post(f"{base}/v1/chat/completions",
                           headers={"Origin": "https://evil.example"},
                           json={"model": MODEL, "max_tokens": 2,
                                 "messages": [{"role": "user", "content": "hi"}]})),
        ("models", http.get(f"{base}/v1/models", headers={"Origin": "https://evil.example"})),
    ]:
        r = await coro
        rep.ok("access-control-allow-origin" not in r.headers,
               f"{P}/cors: {label} w/ Origin leaked ACAO="
               f"{r.headers.get('access-control-allow-origin')!r} (want none — closed CORS)")

    # ── G3: type confusion. Every field at the wrong JSON type must be
    # rejected by deserialization at the 400 boundary (code invalid_request),
    # NOT coerced and NOT 5xx/panicked.
    type_confusion = [
        ("temperature", "hot"), ("top_p", "x"), ("max_tokens", -5),
        ("max_tokens", "10"), ("max_tokens", 1.5), ("stream", "true"),
        ("model", 123),
    ]
    for field, value in type_confusion:
        r = await http.post(f"{base}/v1/chat/completions", json={
            "model": MODEL, "messages": [{"role": "user", "content": "hi"}], field: value,
        })
        code = _err_code(r)
        rep.ok(r.status_code == 400 and code == "invalid_request",
               f"{P}/type: {field}={value!r} -> {r.status_code} code={code!r} "
               f"(want 400 invalid_request, never 5xx)")
    # `messages` as a scalar instead of an array.
    r = await http.post(f"{base}/v1/chat/completions", json={"model": MODEL, "messages": "hi"})
    rep.ok(r.status_code == 400, f"{P}/type: messages='hi' -> {r.status_code} (want 400)")

    # ── G4: structural abuse + JSON-recursion DoS. A wrong-shape top-level
    # body (array/string/null/number) -> 400 at column 1 (struct expected).
    for label, payload in [("array", [1, 2, 3]), ("string", "x"), ("number", 42)]:
        r = await http.post(f"{base}/v1/chat/completions", json=payload)
        rep.ok(r.status_code == 400 and _err_code(r) == "invalid_request",
               f"{P}/struct: body={label} -> {r.status_code} (want 400 invalid_request)")
    r = await http.post(f"{base}/v1/chat/completions", content=b"null",
                        headers={"Content-Type": "application/json"})
    rep.ok(r.status_code == 400, f"{P}/struct: body=null -> {r.status_code} (want 400)")
    # The real recursion vector is a deeply-nested value inside a free-form
    # field (`tool_choice`/`tools[].parameters` are serde_json::Value). A
    # top-level array is rejected instantly at the struct boundary, but a
    # nested Value descends — serde_json's recursion limit (128) is the
    # guard. Depth 2000 must hit it as a 400 "recursion limit exceeded",
    # NOT a stack-overflow/crash. Closed allow-set so a 5xx fails loud.
    deep = "[" * 2000 + "]" * 2000
    body = ('{"model":"%s","messages":[{"role":"user","content":"hi"}],'
            '"tool_choice":%s}' % (MODEL, deep))
    r = await http.post(f"{base}/v1/chat/completions", content=body.encode(),
                        headers={"Content-Type": "application/json"})
    rep.ok(r.status_code == 400 and _err_code(r) == "invalid_request",
           f"{P}/deep: nested tool_choice depth=2000 -> {r.status_code} "
           f"(want 400 recursion-limit, never a 5xx/stack-overflow)")

    # ── G5: hostile content payloads. A NUL byte, astral-plane emoji,
    # ANSI/control chars, an RTL override, and a long no-space token are
    # all valid non-empty JSON strings — they must generate cleanly (200),
    # never wedge the tokenizer/decoder into a 5xx.
    hostile = [
        ("nul", "a" + chr(0) + "b"),
        ("emoji", chr(0x1F525) * 40),
        ("control", chr(27) + "[31m" + chr(9) + chr(13)),
        ("rtl", "abc" + chr(0x202E) + "def"),
        ("long-token", "x" * 1000),
    ]
    for label, content in hostile:
        r = await http.post(f"{base}/v1/chat/completions", json={
            "model": MODEL, "messages": [{"role": "user", "content": content}],
            "stream": False, "max_tokens": 2,
        })
        rep.ok(r.status_code == 200,
               f"{P}/content: {label} -> {r.status_code} (want 200; never 5xx on valid text)")

    # ── G6: malformed message objects. A null/missing required field is a
    # 400 deserialize error.
    for label, msg in [
        ("content=null", {"role": "user", "content": None}),
        ("missing-role", {"content": "hi"}),
    ]:
        r = await http.post(f"{base}/v1/chat/completions",
                            json={"model": MODEL, "messages": [msg]})
        rep.ok(r.status_code == 400 and _err_code(r) == "invalid_request",
               f"{P}/msg: {label} -> {r.status_code} (want 400 invalid_request)")
    r = await http.post(f"{base}/v1/chat/completions",
                        json={"model": None, "messages": [{"role": "user", "content": "hi"}]})
    rep.ok(r.status_code == 400, f"{P}/msg: model=null -> {r.status_code} (want 400)")
    # Unknown roles are rejected at the shared validation boundary — never
    # demoted into a user turn or allowed to carry dropped continuation fields.
    r = await http.post(f"{base}/v1/chat/completions", json={
        "model": MODEL, "messages": [{"role": "banana", "content": "hi"}],
        "stream": False, "max_tokens": 2,
    })
    err = r.json().get("error", {}) if r.status_code == 400 else {}
    rep.ok(r.status_code == 400 and err.get("code") == "unsupported_role",
           f"{P}/role: unknown role=banana -> {r.status_code} {r.text[:120]!r} "
           "(want 400 unsupported_role)")

    # ── G8: /v1/models/load is REMOVED (#469 — pie binds the served model at
    # boot; `GET /v1/models` is the served-model source of truth). Every abuse
    # input that used to probe its validation must now hit the unknown-route
    # fallthrough: a clean 404 `endpoint_not_found` JSON envelope, never a
    # 400/413/500/hang.
    removed_load_bodies = [
        ('{}', "missing model"),
        ('{"model":null}', "model=null"),
        ('xxx', "non-json"),
        ('{"model":"' + "a" * 5000 + '"}', "oversized"),
        ('{"model":"  "}', "blank model"),
    ]
    for body, label in removed_load_bodies:
        r = await http.post(f"{base}/v1/models/load", content=body.encode(),
                            headers={"Content-Type": "application/json"})
        rep.ok(r.status_code == 404 and _err_code(r) == "endpoint_not_found",
               f"{P}/load: {label} -> {r.status_code} code={_err_code(r)!r} "
               f"(want 404 endpoint_not_found — endpoint removed)")

    # ── Survival: after the full malformed-input barrage the engine must
    # still be healthy and serve a normal request (no wedge / leaked task).
    r = await http.get(f"{base}/healthz")
    rep.ok(r.status_code == 200 and r.json() == {"status": "ok"},
           f"{P}/survival: /healthz after barrage -> {r.status_code}")
    r = await http.post(f"{base}/v1/chat/completions", json={
        "model": MODEL, "messages": [{"role": "user", "content": "hi"}],
        "stream": False, "max_tokens": 2,
    })
    rep.ok(r.status_code == 200,
           f"{P}/survival: normal chat after barrage -> {r.status_code} (engine not wedged)")


def _err_code(r: httpx.Response) -> str:
    """Best-effort `error.code` from a JSON error envelope ('' if absent)."""
    try:
        return r.json().get("error", {}).get("code", "")
    except Exception:
        return ""


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
                ("harsh-surface", section_harsh_surface),
                ("content-parts", section_content_parts),
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
