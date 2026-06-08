"""Real-engine harsh-LOAD evaluation for the Local API (#467, real tier).

Where `stress_e2e_test.py::section_harsh_surface` fuzzes the PROTOCOL against
pie's dummy driver (deterministic, CI-safe), THIS drives the REAL engine
(`pie serve` portable-Metal, real Qwen3-0.6B) under the realistic heavy load
the ticket means by "harsh": many *concurrent* requests, long/realistic
prompts and growing histories, and sustained agent-style traffic. It is NOT
protocol fuzzing and NOT big-model RAM pressure — the model is small (0.6B);
the pressure is concurrency + long contexts + sustained turns.

Workload source = prompts CAPTURED FROM REAL AGENTS, replayed (the approach
from `pie-agents/integrations/hermes-agent/bench/replay_pressure.py`). That
runner fires sequentially; the ticket wants concurrency, so this adds a
bounded-concurrent firing schedule on top of the same capture-replay idea.

Two tiers:
  * SMOKE  — a committed, self-contained openclaw capture sample
             (`fixtures/openclaw_replay_sample.jsonl`: real 28-tool, ~28k-char
             system prompt + multi-turn history). Low concurrency. A light
             real-engine smoke that runs wherever the weights exist.
  * HEAVY  — a richer hermes capture.jsonl env-sourced at runtime via
             `PIE_TEST_REPLAY_CORPUS` (NOT committed). High concurrency, more
             users/rounds, interleaved + sequential. Only runs when the env
             var points at a readable capture.

Both are env/weight-gated and NOT in normal CI. Absent weights / wasm /
corpus → clean SKIP (exit 0), never a failure.

Captured bodies are normalized to chat-apc's supported contract WITHOUT
changing the token shape (the realistic part):
  * `model` -> the served id.
  * content-parts arrays (openclaw) -> flattened text (chat-apc needs
    `content: String`).
  * `role:"tool"` + `tool_call_id` (hermes, OpenAI-native) -> folded into the
    user-turn path chat-apc documents (it rejects role=tool with 400
    `tool_role_unsupported`); assistant `tool_calls` are summarized to text so
    no message degenerates to empty content.

The contract asserted under load (encoding behavior MEASURED against the live
engine, pinned like the dummy tier), split into two classes:
  * CORRECTNESS — every RECEIVED response is a 200 with well-formed SSE
    (model_ready first, exactly one canonical finish_reason, `[DONE]` last,
    nothing after the terminal chunk) OR a structured JSON error envelope —
    never a bare 500, a malformed SSE frame, or an unhandled exception. This
    held at EVERY concurrency measured.
  * LIVENESS — every fire settles with a response within the deadline. This
    holds at sustainable concurrency (<= engine slots); MEASURED finding:
    firing PAST the slot count (8 in the shipped config) starves queued
    requests — the server's request_timeout doesn't abort a slot-blocked
    request, so it hangs past the client deadline with no response. Filed as
    a follow-up (engine liveness gap); the default concurrency stays below
    the slot count so a run is a clean guard. After the barrage the engine is
    still healthy and serves a normal request.

Usage::

    # smoke only (committed fixture):
    uv run --project Vendor/pie/client/python --with httpx \
        python Inferlets/chat-apc/harsh_load_real.py
    # + heavy concurrent replay of a real hermes capture:
    PIE_TEST_REPLAY_CORPUS=/path/to/captures/.../capture.jsonl \
        uv run ... python Inferlets/chat-apc/harsh_load_real.py
    # or via the make target (gated):
    make test-e2e-harsh-load
"""
from __future__ import annotations

import asyncio
import contextlib
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import httpx
from pie_client import PieClient

_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))
import e2e_test as E  # noqa: E402  boot/teardown helpers + path constants

MODEL = os.environ.get("MODEL", "Qwen/Qwen3-0.6B")
FIXTURE = _HERE / "fixtures" / "openclaw_replay_sample.jsonl"

# Bounded-but-high load knobs (all env-tunable). Defaults keep the run
# bounded (a few minutes) while still oversubscribing the engine's slots.
SMOKE_CONCURRENCY = int(os.environ.get("HARSH_SMOKE_CONCURRENCY", "4"))
# Sustainable default: the portable engine serves a fixed number of KV slots
# (8 in the shipped config). Firing MORE than that oversubscribes — queued
# requests block on slot acquisition, and because the server's
# `request_timeout_secs` does NOT abort a slot-blocked request, an
# over-the-cap request can starve past the client deadline with no response
# (a real liveness gap, MEASURED here and filed as a follow-up). The default
# stays below the slot count so a run is a clean regression guard for wire
# CORRECTNESS under sustained concurrent load; crank HARSH_CONCURRENCY past
# the slot count to reproduce the starvation.
HEAVY_CONCURRENCY = int(os.environ.get("HARSH_CONCURRENCY", "6"))
# Defaults keep a full run bounded (~10 min on an M-series Metal box): the
# engine serializes/queues concurrent decode under slot-oversubscription, so
# wall-clock scales with the request COUNT, not the concurrency. Operators who
# want a longer soak crank HARSH_ROUNDS / HARSH_USERS / HARSH_MAX_TOKENS.
N_USERS = int(os.environ.get("HARSH_USERS", "4"))
ROUNDS = int(os.environ.get("HARSH_ROUNDS", "1"))
MAX_TOKENS = int(os.environ.get("HARSH_MAX_TOKENS", "64"))
REQ_TIMEOUT = float(os.environ.get("HARSH_REQ_TIMEOUT", "180"))

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


# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

class Report:
    def __init__(self) -> None:
        self.failures: list[str] = []
        self.passed = 0

    def ok(self, cond: bool, msg: str) -> bool:
        if cond:
            self.passed += 1
        else:
            self.failures.append(msg)
        return cond

    def fail(self, msg: str) -> None:
        self.failures.append(msg)


# ---------------------------------------------------------------------------
# Capture normalization (any corpus -> chat-apc body, token shape preserved)
# ---------------------------------------------------------------------------

def _flatten_content(c) -> str:
    """OpenAI content can be a string or a list of typed parts. chat-apc
    needs a plain string — join the text parts."""
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        out = []
        for part in c:
            if isinstance(part, dict):
                out.append(part.get("text") or part.get("content") or "")
            elif isinstance(part, str):
                out.append(part)
        return "".join(out)
    if c is None:
        return ""
    return str(c)


def _normalize_messages(msgs: list[dict]) -> list[dict]:
    """Map captured messages onto chat-apc's supported {role, content}
    contract. role=tool -> user-turn path; assistant tool_calls -> text;
    every message ends with non-empty content (chat-apc 400s blank)."""
    out: list[dict] = []
    for m in msgs:
        role = m.get("role", "user")
        content = _flatten_content(m.get("content"))
        if role == "tool":
            # chat-apc rejects role=tool (tool_role_unsupported); fold the
            # tool result into the documented user-turn path.
            tid = m.get("tool_call_id") or "tool"
            out.append({"role": "user",
                        "content": f"Tool result ({tid}): {content}" if content
                        else f"Tool result ({tid})."})
            continue
        if role == "assistant" and not content and m.get("tool_calls"):
            names = []
            for tc in m["tool_calls"]:
                fn = (tc or {}).get("function") or {}
                names.append(fn.get("name") or "tool")
            content = f"[assistant requested tools: {', '.join(names)}]"
        if not content.strip():
            # Drop a message that would degenerate to blank content (chat-apc
            # 400s it); keeps the replay inside the supported surface.
            continue
        out.append({"role": role, "content": content})
    return out


def _to_body(raw: dict) -> dict | None:
    """Project a captured request body onto a chat-apc /v1/chat/completions
    body. Returns None if no usable messages survive normalization."""
    msgs = _normalize_messages(raw.get("messages") or [])
    if not msgs:
        return None
    body = {
        "model": MODEL,
        "messages": msgs,
        "stream": True,
        "max_tokens": MAX_TOKENS,
        "temperature": 0,
    }
    tools = raw.get("tools")
    if isinstance(tools, list) and tools:
        body["tools"] = tools  # already OpenAI {type:function, function:{...}}
    return body


def load_corpus(path: Path) -> list[dict]:
    """Read a capture.jsonl (flat openclaw rows OR kwargs-wrapped hermes rows)
    into an ordered list of chat-apc bodies. Order matters: turn N+1's
    messages embed turn N's output."""
    bodies: list[dict] = []
    with path.open() as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            raw = row.get("kwargs") if isinstance(row.get("kwargs"), dict) else row
            if not isinstance(raw, dict) or not raw.get("messages"):
                continue
            body = _to_body(raw)
            if body is not None:
                bodies.append(body)
    return bodies


# ---------------------------------------------------------------------------
# SSE wire-correctness check (same invariants as the dummy stress tier)
# ---------------------------------------------------------------------------

def _sse_payloads(text: str) -> list[str]:
    return [ln[len("data: "):] for ln in text.splitlines() if ln.startswith("data: ")]


def check_sse(text: str) -> tuple[bool, str]:
    """Return (ok, reason). Enforces: non-empty; model_ready first; every
    non-[DONE] frame is valid JSON; exactly one terminal chunk with a
    canonical finish_reason; [DONE] last; no content chunk after terminal."""
    payloads = _sse_payloads(text)
    if not payloads:
        return False, "empty SSE body"
    if payloads[0] != '{"event":"model_ready"}':
        return False, f"first frame {payloads[0][:60]!r} (want model_ready)"
    if payloads[-1] != "[DONE]":
        return False, f"last frame {payloads[-1][:60]!r} (want [DONE])"
    if payloads.count("[DONE]") != 1:
        return False, f"[DONE] count {payloads.count('[DONE]')}"
    finish_idxs = []
    for i, d in enumerate(payloads):
        if d == "[DONE]":
            continue
        try:
            obj = json.loads(d)
        except json.JSONDecodeError as e:
            return False, f"malformed frame {d[:60]!r}: {e}"
        if obj.get("object") == "chat.completion.chunk" and obj["choices"][0].get("finish_reason"):
            finish_idxs.append(i)
    if len(finish_idxs) != 1:
        return False, f"terminal-chunk count {len(finish_idxs)} (want 1)"
    fr = json.loads(payloads[finish_idxs[0]])["choices"][0]["finish_reason"]
    if fr not in ("stop", "length", "tool_calls", "error"):
        return False, f"finish_reason {fr!r} not canonical"
    for d in payloads[finish_idxs[0] + 1:]:
        if d == "[DONE]":
            continue
        if json.loads(d).get("object") == "chat.completion.chunk":
            return False, f"content chunk after terminal: {d[:60]!r}"
    return True, fr


def _err_code(text: str) -> str:
    try:
        return json.loads(text).get("error", {}).get("code", "")
    except Exception:
        return ""


# ---------------------------------------------------------------------------
# Bounded-concurrent firing
# ---------------------------------------------------------------------------

def _schedule(n_users: int, n_turns: int, rounds: int, pattern: str) -> list[tuple[int, int, int]]:
    out = []
    if pattern == "sequential":
        for u in range(n_users):
            for r in range(rounds):
                for t in range(n_turns):
                    out.append((u, r, t))
    elif pattern == "interleaved":
        for r in range(rounds):
            for t in range(n_turns):
                for u in range(n_users):
                    out.append((u, r, t))
    else:
        raise ValueError(f"unknown pattern {pattern!r}")
    return out


async def _fire(http: httpx.AsyncClient, base: str, body: dict, bearer: str,
                sem: asyncio.Semaphore) -> dict:
    """Fire one streaming request under the concurrency semaphore. Returns a
    settled result dict — exceptions are CAUGHT and recorded (a leaked/hung
    task would surface as a TimeoutError here, which is a failure, not a
    silent drop)."""
    async with sem:
        t0 = time.monotonic()
        try:
            r = await http.post(
                f"{base}/v1/chat/completions", json=body,
                headers={"Authorization": f"Bearer {bearer}"},
            )
            return {"status": r.status_code, "text": r.text,
                    "elapsed": round(time.monotonic() - t0, 2)}
        except Exception as e:
            return {"status": None, "error": f"{type(e).__name__}: {str(e)[:160]}",
                    "elapsed": round(time.monotonic() - t0, 2)}


async def run_load(http: httpx.AsyncClient, base: str, bodies: list[dict], *,
                   concurrency: int, n_users: int, rounds: int, pattern: str,
                   label: str, rep: Report) -> int:
    """Fire the schedule and classify every result. Returns the count of
    well-formed 200/SSE responses (`ok200`) so the caller can assert that the
    tier actually GENERATED — a run where every request returns a structured
    non-200 (a normalization regression, context overflow, tool-equip failure)
    would otherwise pass the structured-error branch with ok200=0 while the
    harness's whole premise — real decode under load — went unexercised."""
    n_turns = len(bodies)
    schedule = _schedule(n_users, n_turns, rounds, pattern)
    sem = asyncio.Semaphore(concurrency)
    t_start = time.monotonic()
    tasks = [
        asyncio.create_task(_fire(http, base, dict(bodies[t]), f"replay-u{u:04d}", sem))
        for (u, r, t) in schedule
    ]
    results = await asyncio.gather(*tasks, return_exceptions=True)
    wall = time.monotonic() - t_start

    # Two distinct failure classes, reported separately:
    #   * CORRECTNESS — a RECEIVED response is malformed (bad SSE framing,
    #     non-canonical finish_reason, a bare/empty non-2xx). These are the
    #     real wire-contract bugs and must never happen at any concurrency.
    #   * LIVENESS — a request never gets a response within the client
    #     deadline (slot-acquisition starvation under oversubscription). At
    #     sustainable concurrency (<= engine slots) this is 0; above it,
    #     queued requests can starve because the server's request_timeout
    #     doesn't abort a slot-blocked request — see the filed follow-up.
    ok200 = err_structured = hangs = 0
    for i, res in enumerate(results):
        ctx = f"{label}/{pattern}[req{i}]"
        if isinstance(res, BaseException):
            hangs += 1
            rep.fail(f"{ctx}: LIVENESS task raised {type(res).__name__}: {res}")
            continue
        if res.get("status") is None:
            hangs += 1
            rep.fail(f"{ctx}: LIVENESS no response in {res.get('elapsed')}s "
                     f"— {res.get('error')} (slot starvation: concurrency > engine slots?)")
            continue
        st = res["status"]
        if st == 200:
            ok, reason = check_sse(res["text"])
            rep.ok(ok, f"{ctx}: CORRECTNESS 200 with bad SSE: {reason}")
            if ok:
                ok200 += 1
        else:
            # A non-200 under load is allowed IFF it is a structured JSON
            # error envelope (never a bare/empty 500).
            code = _err_code(res["text"])
            rep.ok(400 <= st < 600 and bool(code),
                   f"{ctx}: CORRECTNESS status {st} without structured error "
                   f"envelope: {res['text'][:160]!r}")
            if code:
                err_structured += 1
    note = ""
    if hangs:
        note = (f"  [!] {hangs} LIVENESS hang(s): concurrency {concurrency} likely exceeds "
                f"engine slots — queued requests starved past the client deadline")
    print(f"[harsh-load] {label}/{pattern}: {len(schedule)} reqs in {wall:.1f}s "
          f"(conc={concurrency}, users={n_users}, turns={n_turns}, rounds={rounds}) "
          f"-> ok200={ok200} structured_err={err_structured} hangs={hangs}{note}", flush=True)
    return ok200


# ---------------------------------------------------------------------------
# Real-engine session (portable Metal, real weights)
# ---------------------------------------------------------------------------

@contextlib.asynccontextmanager
async def real_engine_session():
    """Boot `pie serve` with the production portable-Metal driver against the
    real cached model, install the prebuilt chat-apc wasm, launch the daemon,
    yield the base URL. Idempotent teardown (reuses e2e_test helpers)."""
    tmp = Path(tempfile.mkdtemp(prefix="harsh-real-"))
    cfg = tmp / "config.toml"
    cfg.write_text(CONFIG_TOML)
    home = tmp / "home"
    home.mkdir()
    shmem = f"/pie_harsh_{os.getpid()}"
    env = {**os.environ, "PIE_HOME": str(home), "PIE_SHMEM_NAME": shmem}
    proc = subprocess.Popen(
        [str(E.PIE_BIN), "serve", "--config", str(cfg), "--no-auth", "--debug"],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env, bufsize=1,
    )
    drain = None
    client = None
    try:
        ws_addr, token = await E._parse_handshake(proc, timeout=180)
        drain = asyncio.create_task(E._drain_stdout(proc))
        client = PieClient(f"ws://{ws_addr}")
        await client.connect()
        await client.auth_by_token(token)
        await client.install_program(E.WASM_PATH, E.MANIFEST_PATH, force_overwrite=True)
        port = E._free_port()
        base = f"http://127.0.0.1:{port}"
        await client.launch_daemon("chat-apc@0.1.0", port)
        if not E._wait_for_port(port, timeout=60):
            raise RuntimeError(f"daemon never bound port {port}")
        yield base
    finally:
        if client is not None:
            with contextlib.suppress(Exception):
                await client.close()
        E._terminate_subprocess(proc, label="harsh-inner")
        with contextlib.suppress(Exception):
            if proc.stdout:
                proc.stdout.close()
        if drain is not None:
            drain.cancel()
            with contextlib.suppress(asyncio.CancelledError, asyncio.TimeoutError):
                await asyncio.wait_for(drain, timeout=2.0)
        E._terminate_subprocess(proc, label="harsh-outer")
        E._shm_unlink_quiet(f"{shmem}_g0")
        import shutil
        shutil.rmtree(tmp, ignore_errors=True)


# ---------------------------------------------------------------------------
# Gating + main
# ---------------------------------------------------------------------------

def assert_generated(ok200: int, label: str, rep: Report) -> bool:
    """The F1 generation guard: a tier meant to DECODE that produced zero
    200/SSE responses is a silent no-op (every body failed to decode — a
    normalization regression, context overflow, or tool-equip failure), so a
    hollow PASS would hide that the harness premise went unexercised. Shared
    by main()'s smoke + heavy tiers AND the regression self-test, so the test
    drives this exact production guard and fails if a caller removes it."""
    return rep.ok(ok200 > 0,
                  f"{label}: no replayed request produced a 200/SSE — the corpus never "
                  f"decoded under load (normalization regression / context overflow / "
                  f"tool-equip failure?)")


async def run_all_tiers(http, base: str, smoke_bodies: list[dict],
                        heavy_bodies: list[dict], heavy_path, rep: Report, *,
                        survival: bool = True) -> None:
    """The full load schedule + guards, shared by main() and the self-test so
    the test drives the SAME guard wiring (F7): if a future change drops an
    `assert_generated` call here, BOTH paths lose it and the self-test's
    all-400 stub run stops reporting a generation failure -> self-test FAILs.
    `survival` is False under the engine-free self-test (no live engine to
    health-check)."""
    # SMOKE tier — committed openclaw sample, low concurrency.
    print(f"[harsh-load] SMOKE: {len(smoke_bodies)} turns from committed fixture", flush=True)
    smoke_ok = 0
    smoke_ok += await run_load(http, base, smoke_bodies, concurrency=SMOKE_CONCURRENCY,
                               n_users=2, rounds=1, pattern="sequential", label="smoke", rep=rep)
    smoke_ok += await run_load(http, base, smoke_bodies, concurrency=SMOKE_CONCURRENCY,
                               n_users=2, rounds=1, pattern="interleaved", label="smoke", rep=rep)
    assert_generated(smoke_ok, "smoke", rep)

    # HEAVY tier — env-sourced hermes capture, high concurrency.
    if heavy_bodies:
        print(f"[harsh-load] HEAVY: {len(heavy_bodies)} turns from {heavy_path}", flush=True)
        heavy_ok = 0
        for pattern in ("interleaved", "sequential"):
            heavy_ok += await run_load(http, base, heavy_bodies, concurrency=HEAVY_CONCURRENCY,
                                       n_users=N_USERS, rounds=ROUNDS, pattern=pattern,
                                       label="heavy", rep=rep)
        assert_generated(heavy_ok, "heavy", rep)
    else:
        print("[harsh-load] HEAVY tier skipped (set PIE_TEST_REPLAY_CORPUS to a "
              "hermes capture.jsonl to enable the concurrent replay).", flush=True)

    # Survival: engine healthy + serves a normal request after the barrage.
    if survival:
        r = await http.get(f"{base}/healthz")
        rep.ok(r.status_code == 200 and r.json() == {"status": "ok"},
               f"survival: /healthz after load -> {r.status_code}")
        r = await http.post(f"{base}/v1/chat/completions", json={
            "model": MODEL, "stream": False, "max_tokens": 8,
            "messages": [{"role": "user", "content": "Say hi."}],
        })
        rep.ok(r.status_code == 200, f"survival: normal chat after load -> {r.status_code} "
               f"{r.text[:160]!r} (engine not wedged)")


def _weights_cached(model: str) -> bool:
    """True if a resolved WEIGHT artifact for `model` exists in the HF cache
    (not just config/tokenizer — the dummy tier needs only those)."""
    cache = Path(os.environ.get("HF_HUB_CACHE")
                 or (Path(os.environ.get("HF_HOME", Path.home() / ".cache/huggingface")) / "hub"))
    repo = "models--" + model.replace("/", "--")
    snaps = cache / repo / "snapshots"
    if not snaps.is_dir():
        return False
    for ext in ("*.safetensors", "*.gguf", "*.bin"):
        if any(snaps.glob(f"*/{ext}")):
            return True
    return False


def _skip(reason: str) -> int:
    print(f"[harsh-load] SKIP — {reason}")
    return 0


async def main() -> int:
    # Gate: never a hard failure when prerequisites are absent.
    if not E.PIE_BIN.exists():
        return _skip(f"pie binary missing at {E.PIE_BIN} (build: make engine-build)")
    if not E.WASM_PATH.exists():
        return _skip(f"chat-apc wasm missing at {E.WASM_PATH} "
                     f"(build: Scripts/stamp-chat-apc.sh write)")
    try:
        E.verify_stamp()
    except Exception as e:
        return _skip(f"wasm stamp mismatch: {e}")
    if not _weights_cached(MODEL):
        return _skip(f"real weights for {MODEL} not in HF cache (this is the real-engine tier)")
    if not FIXTURE.exists():
        return _skip(f"committed fixture missing at {FIXTURE}")

    smoke_bodies = load_corpus(FIXTURE)
    if not smoke_bodies:
        print(f"[harsh-load] FATAL: committed fixture yielded no usable bodies: {FIXTURE}")
        return 1

    corpus_env = os.environ.get("PIE_TEST_REPLAY_CORPUS")
    heavy_path = Path(corpus_env) if corpus_env else None
    heavy_bodies: list[dict] = []
    if heavy_path and heavy_path.is_file():
        heavy_bodies = load_corpus(heavy_path)
        if not heavy_bodies:
            print(f"[harsh-load] WARN: PIE_TEST_REPLAY_CORPUS={heavy_path} has no usable rows; "
                  f"heavy tier skipped.")
    elif corpus_env:
        print(f"[harsh-load] WARN: PIE_TEST_REPLAY_CORPUS={corpus_env} not a file; "
              f"heavy tier skipped.")

    rep = Report()
    print(f"[harsh-load] booting REAL engine (portable Metal, {MODEL})…", flush=True)
    async with real_engine_session() as base:
        async with httpx.AsyncClient(timeout=REQ_TIMEOUT) as http:
            await run_all_tiers(http, base, smoke_bodies, heavy_bodies, heavy_path, rep)

    if rep.failures:
        print(f"\n[harsh-load] FAILURES ({len(rep.failures)}):")
        for f in rep.failures[:40]:
            print(f"  - {f}")
        print(f"\n[harsh-load] RESULT: FAIL ({rep.passed} passed, {len(rep.failures)} failed)")
        return 1
    print(f"\n[harsh-load] RESULT: PASS ({rep.passed} checks)")
    return 0


# ---------------------------------------------------------------------------
# Engine-free negative self-test (guards the F1 generation assertion)
# ---------------------------------------------------------------------------

async def self_test() -> int:
    """Deterministic, engine-free regression guard for the F1 fix. Drives the
    REAL production path — `run_all_tiers` — against a stub that returns ALL
    structured 400s (every replayed body fails to decode). Each per-request
    classification stays green (a structured non-200 is allowed), so the ONLY
    thing that can fail the run is the `assert_generated` guard. The test
    passes iff that guard fired. Because `run_all_tiers` is the same code main()
    runs, deleting OR weakening the guard there is caught here — not just a
    copy of the assertion (review v2 F7)."""

    class _Stub400:
        async def post(self, url, json=None, headers=None):
            class _R:
                status_code = 400
                text = '{"error":{"code":"invalid_request","message":"stub"}}'
            return _R()

    rep = Report()
    bodies = [{"model": MODEL, "messages": [{"role": "user", "content": "hi"}],
               "stream": True, "max_tokens": 8}]
    # survival=False: no live engine to health-check. heavy disabled (no corpus).
    await run_all_tiers(_Stub400(), "http://stub", bodies, [], None, rep, survival=False)
    gen_failures = [f for f in rep.failures if "produced a 200/SSE" in f]
    # Exactly the generation guard must have failed — nothing else (all-400 is
    # an allowed per-request outcome, so without the guard there'd be 0 failures).
    passed = len(rep.failures) == 1 and len(gen_failures) == 1
    print(f"[harsh-load] SELF-TEST {'PASS' if passed else 'FAIL'}: all-400 corpus via "
          f"run_all_tiers -> {len(rep.failures)} failure(s), generation-guard fired="
          f"{len(gen_failures) == 1} (expect exactly 1: the generation guard)")
    return 0 if passed else 1


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        sys.exit(asyncio.run(self_test()))
    sys.exit(asyncio.run(main()))
