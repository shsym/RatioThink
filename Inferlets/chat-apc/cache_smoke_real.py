"""Real-model cross-request prefix-cache smoke for chat-apc (#522).

Unlike `e2e_test.py` (dummy driver — no forward-pass capability, so it
cannot exercise save/open of real KV pages), this boots `pie serve` with
the production **portable Metal** driver against a real cached model and
drives a multi-turn conversation, asserting the cross-request KV reuse
contract end to end:

  1. Turn 1 (fresh chat) → cache MISS, and a boundary is SAVED.
  2. Turn 2 (same chat key, history = turn-1 user + assistant + new user)
     → cache HIT with base_boundary > 0 (the [user, assistant] prefix was
     reused — the history prefill was skipped).
  3. A `policy:"bypass"` request emits NO cache diagnostics (reuse off).
  4. A different chat key → MISS (per-chat namespacing).
  5. A retry/truncate-shaped request after turn 2 reopens the turn-1
     boundary, never the now-erased turn-2 suffix boundary.
  6. A changed system prompt under the same key → MISS (prompt-affecting
     change is not reused).

The diagnostics ride the `X-ChatAPC-Cache` response header (non-streaming).

Qwen3-0.6B is a *thinking* model: its `<think>` reasoning is not replayed
into history, and this suite still gets a real HIT because the boundary is
the canonical text rendering (`assistant(visible_content)`), rebuilt at
save time — never the reasoning-bearing generation KV.

Reuses the boot/teardown helpers from `e2e_test.py`.

Requires: built `Vendor/pie/target/release/pie` (Metal portable, via
`make engine-build`), the prebuilt chat-apc wasm + stamp, and a real model
in `~/.cache/huggingface/hub`.

Usage::

    make test-e2e-cache-real

    # or invoke the harness directly:
    MODEL=Qwen/Qwen3-0.6B uv run --project Vendor/pie/client/python \
        --with httpx python Inferlets/chat-apc/cache_smoke_real.py
"""
from __future__ import annotations

import asyncio
import json
import os
import subprocess
import tempfile
import uuid
from pathlib import Path

SELFTEST = os.environ.get("CACHE_SMOKE_REAL_SELFTEST")

if SELFTEST:
    httpx = None
    PieClient = None
    h = None
else:
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


def _diag(resp: httpx.Response) -> dict | None:
    raw = resp.headers.get("X-ChatAPC-Cache")
    return json.loads(raw) if raw else None


def _require_status_ok(label: str, resp: httpx.Response, failures: list[str]) -> bool:
    if resp.status_code == 200:
        return True
    failures.append(f"{label} status {resp.status_code}: {resp.text[:200]!r}")
    return False


async def _run_post_turn2_probes(
    http_c,
    base: str,
    *,
    model: str,
    hist2: list[dict],
    key: str,
    a1: str,
    t2: httpx.Response,
    d1: dict | None,
    d2: dict | None,
    directive,
    failures: list[str],
) -> None:
    # ── same-model profile/sampling switch → still HIT ─
    tp = await http_c.post(f"{base}/v1/chat/completions", json={
        "model": model, "messages": hist2,
        # Different sampling knobs model a profile switch
        # that should not invalidate the same-model prefix.
        "temperature": 0.7, "top_p": 0.95, "max_tokens": 32, "stream": False,
        "cache": directive(key, 3),
    })
    dp = _diag(tp)
    print(f"[cache] same-model-profile-switch -> {tp.status_code} diag={dp}")
    if _require_status_ok("same-model profile switch", tp, failures):
        if dp is None:
            failures.append("same-model profile switch: missing X-ChatAPC-Cache header")
        elif dp["outcome"] != "hit":
            failures.append(
                f"same-model profile switch outcome={dp['outcome']!r} (want hit)")
        elif d1 is not None and dp.get("prefix_hash") != d1.get("save_hash"):
            failures.append(
                "same-model profile switch hit the wrong boundary: "
                f"prefix_hash={dp.get('prefix_hash')!r} "
                f"turn1_save_hash={d1.get('save_hash')!r}")

    # ── bypass: no reuse, no diagnostics ──────────────
    tb = await http_c.post(f"{base}/v1/chat/completions", json={
        "model": model, "messages": hist2,
        "temperature": 0, "max_tokens": 32, "stream": False,
        "cache": directive(key, 3, policy="bypass"),
    })
    db = _diag(tb)
    print(f"[cache] bypass -> {tb.status_code} diag={db}")
    if _require_status_ok("bypass", tb, failures):
        if db is not None:
            failures.append("bypass policy must not emit cache diagnostics")

    # ── different key → miss (per-chat namespacing) ───
    tk = await http_c.post(f"{base}/v1/chat/completions", json={
        "model": model, "messages": hist2,
        "temperature": 0, "max_tokens": 32, "stream": False,
        "cache": directive(str(uuid.uuid4()), 3),
    })
    dk = _diag(tk)
    print(f"[cache] otherkey -> {tk.status_code} diag={dk}")
    if _require_status_ok("different key", tk, failures):
        if dk is None:
            failures.append("different key: missing X-ChatAPC-Cache header")
        elif dk["outcome"] != "miss":
            failures.append(f"different key outcome={dk['outcome']!r} (want miss)")

    # ── retry/truncate: erased suffix must not leak ────
    # After turn2, the engine may have saved a longer
    # [q1,a1,q2,a2] boundary. A retry of turn2 resends only
    # [q1,a1,new_user], so it must reopen turn1's saved
    # boundary and must not hit the stale turn2 suffix.
    a2 = ""
    if t2.status_code == 200:
        a2 = t2.json()["choices"][0]["message"].get("content") or ""
    hist_retry = [
        {"role": "user", "content": hist2[0]["content"]},
        {"role": "assistant", "content": a1},
        {"role": "user", "content": "Retry: answer with exactly one landmark name."},
    ]
    tr = await http_c.post(f"{base}/v1/chat/completions", json={
        "model": model, "messages": hist_retry,
        "temperature": 0, "max_tokens": 32, "stream": False,
        "cache": directive(key, 3),
    })
    dr = _diag(tr)
    print(f"[cache] retry-after-turn2 -> {tr.status_code} diag={dr} "
          f"turn2_content={a2[:60]!r}")
    if _require_status_ok("retry lookup", tr, failures):
        if dr is None:
            failures.append("retry lookup: missing X-ChatAPC-Cache header")
        elif dr["outcome"] != "hit":
            failures.append(f"retry lookup outcome={dr['outcome']!r} (want hit)")
        elif d1 is not None and dr.get("prefix_hash") != d1.get("save_hash"):
            failures.append(
                "retry lookup must hit turn1's boundary, not rebuild/leak: "
                f"prefix_hash={dr.get('prefix_hash')!r} "
                f"turn1_save_hash={d1.get('save_hash')!r}")
        elif d2 is not None and dr.get("prefix_hash") == d2.get("save_hash"):
            failures.append(
                "retry lookup hit the stale turn2 suffix boundary; "
                "erased assistant/user tokens leaked into reuse")

    # ── changed system prompt under same key → miss ───
    ts = await http_c.post(f"{base}/v1/chat/completions", json={
        "model": model,
        "messages": [{"role": "system", "content": "You are a terse assistant."}] + hist2,
        "temperature": 0, "max_tokens": 32, "stream": False,
        "cache": directive(key, 4),
    })
    ds = _diag(ts)
    print(f"[cache] sysprompt-change -> {ts.status_code} diag={ds}")
    if _require_status_ok("prompt-changing request", ts, failures):
        if ds is None:
            failures.append("prompt-changing request: missing X-ChatAPC-Cache header")
        elif ds["outcome"] != "miss":
            failures.append(
                f"prompt-changing request outcome={ds['outcome']!r} (want miss): "
                "a changed system prompt must not reuse physical KV")


class _FakeAsyncClient:
    def __init__(self, responses: list):
        self._responses = responses

    async def post(self, *_args, **_kwargs):
        if not self._responses:
            raise AssertionError("mock cache-smoke probe exhausted fake responses")
        return self._responses.pop(0)


class _SelfTestResponse:
    def __init__(self, status_code: int, *, headers: dict | None = None,
                 body: str = "", json_body: dict | None = None):
        self.status_code = status_code
        self.headers = headers or {}
        self.text = body
        self._json_body = json_body

    def json(self) -> dict:
        if self._json_body is None:
            raise ValueError("self-test response has no JSON body")
        return self._json_body


def _mock_response(status: int = 200, diag: dict | None = None) -> _SelfTestResponse:
    headers = {}
    if diag is not None:
        headers["X-ChatAPC-Cache"] = json.dumps(diag)
    if status == 200:
        return _SelfTestResponse(
            status,
            headers=headers,
            json_body={"choices": [{"message": {"content": "mock assistant"}}]},
        )
    return _SelfTestResponse(status, body="mock probe failure")


_KNOWN_SELFTEST_SCENARIOS = {
    "post-turn2-same-model-profile-switch-500",
    "post-turn2-bypass-500",
    "post-turn2-otherkey-500",
    "post-turn2-retry-after-turn2-500",
    "post-turn2-sysprompt-change-500",
    "post-turn2-same-model-profile-switch-missing-diag",
    "post-turn2-otherkey-missing-diag",
    "post-turn2-retry-after-turn2-missing-diag",
    "post-turn2-sysprompt-change-missing-diag",
}


async def _selftest_post_turn2_probes() -> int:
    scenario = os.environ.get("CACHE_SMOKE_REAL_SELFTEST", "")
    if scenario not in _KNOWN_SELFTEST_SCENARIOS:
        print(f"[cache-selftest] unknown CACHE_SMOKE_REAL_SELFTEST scenario: {scenario}")
        return 1

    forced = scenario.removeprefix("post-turn2-")
    d1 = {"save_hash": "turn1"}
    d2 = {"save_hash": "turn2"}
    probe_defaults: list[tuple[str, _SelfTestResponse]] = [
        ("same-model-profile-switch", _mock_response(diag={"outcome": "hit", "prefix_hash": "turn1"})),
        ("bypass", _mock_response()),
        ("otherkey", _mock_response(diag={"outcome": "miss"})),
        ("retry-after-turn2", _mock_response(diag={"outcome": "hit", "prefix_hash": "turn1"})),
        ("sysprompt-change", _mock_response(diag={"outcome": "miss"})),
    ]
    responses: list[_SelfTestResponse] = []
    for name, response in probe_defaults:
        if forced == f"{name}-500":
            responses.append(_mock_response(500))
        elif forced == f"{name}-missing-diag":
            responses.append(_mock_response())
        else:
            responses.append(response)

    failures: list[str] = []

    def directive(k: str, turn: int, policy: str = "auto") -> dict:
        return {"key": k, "turn": turn, "compat": "1", "policy": policy}

    await _run_post_turn2_probes(
        _FakeAsyncClient(responses),
        "http://cache-smoke-selftest",
        model=MODEL,
        hist2=[
            {"role": "user", "content": "q1"},
            {"role": "assistant", "content": "a1"},
            {"role": "user", "content": "q2"},
        ],
        key="selftest-key",
        a1="a1",
        t2=_mock_response(diag={"outcome": "hit", "save_hash": "turn2"}),
        d1=d1,
        d2=d2,
        directive=directive,
        failures=failures,
    )
    if failures:
        print("\n[cache-selftest] FAILURES:")
        for f in failures:
            print(f"  ✗ {f}")
        return 1
    print("[cache-selftest] PASS")
    return 0


async def main() -> int:
    if SELFTEST:
        return await _selftest_post_turn2_probes()

    assert h is not None
    assert PieClient is not None
    assert h.PIE_BIN.exists(), f"missing pie binary at {h.PIE_BIN}"
    assert h.WASM_PATH.exists(), f"missing wasm at {h.WASM_PATH}"
    h.verify_stamp()

    failures: list[str] = []
    with tempfile.TemporaryDirectory(prefix="cache-real-") as tmp:
        tmp = Path(tmp)
        cfg = tmp / "config.toml"
        cfg.write_text(CONFIG_TOML)
        pie_home = tmp / "home"
        pie_home.mkdir()
        env = {
            **os.environ,
            "PIE_HOME": str(pie_home),
            "PIE_SHMEM_NAME": f"/cache_real_{os.getpid()}",
        }
        proc = subprocess.Popen(
            [str(h.PIE_BIN), "serve", "--config", str(cfg), "--no-auth", "--debug"],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env, bufsize=1,
        )
        try:
            ws_addr, token = await h._parse_handshake(proc, timeout=120)
            print(f"[cache] engine ws=ws://{ws_addr}")
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

                key = str(uuid.uuid4())
                q1 = "What is the capital of France? Answer in one short sentence."
                q2 = "And what is its most famous landmark? One short sentence."

                def directive(
                    k: str,
                    turn: int,
                    policy: str = "auto",
                    retention: dict | None = None,
                ) -> dict:
                    out = {"key": k, "turn": turn, "compat": "1", "policy": policy}
                    if retention is not None:
                        out["retention"] = retention
                    return out

                async with httpx.AsyncClient(timeout=240) as http_c:
                    # ── Control: no cache directive (legacy path) ─────
                    ctrl = await http_c.post(f"{base}/v1/chat/completions", json={
                        "model": MODEL,
                        "messages": [{"role": "user", "content": q1}],
                        "temperature": 0, "max_tokens": 256, "stream": False,
                    })
                    print(f"[cache] control(no-cache) -> {ctrl.status_code} "
                          f"diag={_diag(ctrl)} body={ctrl.text[:200]!r}")
                    if ctrl.status_code != 200:
                        failures.append(f"control status {ctrl.status_code}: {ctrl.text[:300]!r}")

                    # ── Turn 1: fresh chat → miss + save ──────────────
                    t1 = await http_c.post(f"{base}/v1/chat/completions", json={
                        "model": MODEL,
                        "messages": [{"role": "user", "content": q1}],
                        "temperature": 0, "max_tokens": 256, "stream": False,
                        "cache": directive(key, 1),
                    })
                    print(
                        f"[cache] turn1 -> {t1.status_code} diag={_diag(t1)} "
                        f"body={t1.text[:300]!r}"
                    )
                    if t1.status_code != 200:
                        failures.append(f"turn1 status {t1.status_code}: {t1.text[:300]!r}")
                        return 1
                    d1 = _diag(t1)
                    if d1 is None:
                        failures.append("turn1: missing X-ChatAPC-Cache header")
                    else:
                        if d1["outcome"] != "miss":
                            failures.append(f"turn1 outcome={d1['outcome']!r} (want miss)")
                        if d1["save_result"] not in ("saved", "exists"):
                            failures.append(
                                f"turn1 save_result={d1['save_result']!r} "
                                "(want saved/exists)"
                            )
                    a1 = t1.json()["choices"][0]["message"].get("content") or ""
                    print(f"[cache] turn1 assistant content={a1[:80]!r}")

                    # ── Turn 2: same key, history carries the assistant
                    #    reply → HIT (the [user, assistant] prefix reused). ──
                    hist2 = [
                        {"role": "user", "content": q1},
                        {"role": "assistant", "content": a1},
                        {"role": "user", "content": q2},
                    ]
                    t2 = await http_c.post(f"{base}/v1/chat/completions", json={
                        "model": MODEL, "messages": hist2,
                        "temperature": 0, "max_tokens": 256, "stream": False,
                        "cache": directive(key, 3),
                    })
                    print(f"[cache] turn2 -> {t2.status_code} diag={_diag(t2)}")
                    d2 = _diag(t2)
                    if t2.status_code != 200:
                        failures.append(f"turn2 status {t2.status_code}: {t2.text[:200]!r}")
                    elif d2 is None:
                        failures.append("turn2: missing X-ChatAPC-Cache header")
                    else:
                        if d2["outcome"] != "hit":
                            failures.append(
                                f"turn2 outcome={d2['outcome']!r} (want hit) — second turn must "
                                f"reuse the saved boundary. "
                                f"base_boundary={d2.get('base_boundary')}"
                            )
                        elif d2["base_boundary"] <= 0:
                            failures.append(
                                f"turn2 hit but base_boundary={d2['base_boundary']} "
                                "(want > 0)"
                            )
                        else:
                            print(f"[cache] HIT: reused {d2['base_boundary']} prefix tokens, "
                                  f"appended {d2['appended']}")

                    await _run_post_turn2_probes(
                        http_c,
                        base,
                        model=MODEL,
                        hist2=hist2,
                        key=key,
                        a1=a1,
                        t2=t2,
                        d1=d1,
                        d2=d2,
                        directive=directive,
                        failures=failures,
                    )

                    # ── retention: LRU state must survive HTTP requests ─
                    # The daemon instantiates a fresh WASM component for
                    # every request, so this proves eviction is driven by
                    # host-owned snapshot state rather than inferlet-local
                    # statics. Save an old snapshot, trigger a later request
                    # with an intentionally tiny retention target, then
                    # assert the old chat misses on the next HTTP request.
                    old_key = str(uuid.uuid4())
                    old_q1 = q1
                    old_q2 = q2
                    old1 = await http_c.post(f"{base}/v1/chat/completions", json={
                        "model": MODEL,
                        "messages": [{"role": "user", "content": old_q1}],
                        "temperature": 0, "max_tokens": 256, "stream": False,
                        "cache": directive(old_key, 1),
                    })
                    d_old1 = _diag(old1)
                    print(f"[cache] retention-old-save -> {old1.status_code} diag={d_old1}")
                    if old1.status_code != 200:
                        failures.append(
                            f"retention old save status {old1.status_code}: "
                            f"{old1.text[:200]!r}"
                        )
                    elif d_old1 is None:
                        failures.append("retention old save: missing X-ChatAPC-Cache header")
                    elif d_old1["save_result"] not in ("saved", "exists"):
                        failures.append(f"retention old save_result={d_old1['save_result']!r}")

                    old_a1 = ""
                    if old1.status_code == 200:
                        old_a1 = old1.json()["choices"][0]["message"].get("content") or ""
                    if old1.status_code == 200 and not old_a1.strip():
                        failures.append(
                            "retention old save produced empty visible assistant content; "
                            "cannot construct the follow-up history"
                        )

                    pressure_key = str(uuid.uuid4())
                    pressure = await http_c.post(f"{base}/v1/chat/completions", json={
                        "model": MODEL,
                        "messages": [{
                            "role": "user",
                            "content": "Retention pressure chat. Answer with one concise sentence.",
                        }],
                        "temperature": 0, "max_tokens": 64, "stream": False,
                        "cache": directive(pressure_key, 1, retention={
                            "kv_pages_used": 100,
                            "kv_pages_total": 100,
                            "soft_percent": 0,
                            "evict_percent": 0,
                            "hard_percent": 0,
                        }),
                    })
                    d_pressure = _diag(pressure)
                    print(f"[cache] retention-pressure -> {pressure.status_code} diag={d_pressure}")
                    if pressure.status_code != 200:
                        failures.append(
                            f"retention pressure status {pressure.status_code}: "
                            f"{pressure.text[:200]!r}"
                        )
                    elif d_pressure is None:
                        failures.append("retention pressure: missing X-ChatAPC-Cache header")
                    else:
                        if (d_pressure.get("evicted_snapshot_count") or 0) < 1:
                            failures.append(
                                "retention pressure did not evict any inactive snapshot: "
                                f"{d_pressure!r}"
                            )
                        if d_pressure.get("delete_failed_count") not in (0, None):
                            failures.append(
                                f"retention pressure delete_failed_count="
                                f"{d_pressure.get('delete_failed_count')!r}"
                            )

                    old2 = await http_c.post(f"{base}/v1/chat/completions", json={
                        "model": MODEL,
                        "messages": [
                            {"role": "user", "content": old_q1},
                            {"role": "assistant", "content": old_a1},
                            {"role": "user", "content": old_q2},
                        ],
                        "temperature": 0, "max_tokens": 64, "stream": False,
                        "cache": directive(old_key, 3),
                    })
                    d_old2 = _diag(old2)
                    print(
                        f"[cache] retention-old-after-pressure -> {old2.status_code} "
                        f"diag={d_old2}"
                    )
                    if old2.status_code != 200:
                        failures.append(
                            f"retention old follow-up status {old2.status_code}: "
                            f"{old2.text[:200]!r}"
                        )
                    elif d_old2 is None:
                        failures.append("retention old follow-up: missing X-ChatAPC-Cache header")
                    elif d_old2["outcome"] != "miss":
                        failures.append(
                            "old snapshot remained reusable after later-request retention "
                            f"pressure; outcome={d_old2['outcome']!r}"
                        )
            finally:
                drain.cancel()
        finally:
            h._terminate_subprocess(proc, "engine")

    if failures:
        print("\n[cache] FAILURES:")
        for f in failures:
            print(f"  ✗ {f}")
        return 1
    print("\n[cache] PASS: miss→save→hit, profile switch hit, retry safe, "
          "bypass off, per-key + prompt-change misses, retention evicts across requests")
    return 0


if __name__ == "__main__":
    import sys
    sys.exit(asyncio.run(main()))
