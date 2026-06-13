"""Real-model speculative-decoding smoke for chat-apc (#418).

Unlike `e2e_test.py` (dummy driver — non-deterministic, can't show
acceptance), this boots `pie serve` with the production **portable Metal**
driver against a real cached model, then POSTs the SAME greedy
(temperature=0) chat twice — once with `speculation:{enabled:true}` and
once without — and checks:

  1. spec output is TOKEN-IDENTICAL to plain output within a SHORT WINDOW
     (max_tokens=64). This is the genuine but BOUNDED greedy-equivalence
     guarantee: the batched verify forward (`kernel_mul_mm`) rounds
     differently from single-token plain decode (`kernel_mul_mv`), so past
     a near-tie (~80-150 tok on Qwen3-0.6B) the spec trajectory drifts off
     plain while staying a valid greedy continuation (#592). 64 tok stays
     short of that, so identity here is a meaningful regression gate; the
     LONG-window drift is recorded (not asserted) by `spec_bench_real.py`.
  2. the spec run accepted at least one draft token (proves the linear
     Cacheback drafter actually speeds up decode on real text).

Reuses the boot/teardown helpers from `e2e_test.py`.

Requires: built `Vendor/pie/target/release/pie` (Metal portable, via
`make engine-build`), the prebuilt chat-apc wasm + stamp, and a real model
in `~/.cache/huggingface/hub`.

Usage::

    MODEL=Qwen/Qwen3-0.6B uv run --with ./Vendor/pie/client/python \
        python Inferlets/chat-apc/spec_smoke_real.py
"""
from __future__ import annotations

import asyncio
import glob
import json
import os
import subprocess
import tempfile
from pathlib import Path

import httpx
from pie_client import PieClient

import e2e_test as h  # boot/teardown helpers + PIE_BIN/WASM_PATH/MANIFEST_PATH

MODEL = os.environ.get("MODEL", "Qwen/Qwen3-0.6B")
TOKENIZER_CLI = Path(os.environ.get("TOKENIZER_CLI", "/tmp/pie-tokenize/target/debug/pie-tokenize-once"))


def _tokenizer_json_path() -> str:
    parts = MODEL.split("/", 1)
    if len(parts) != 2:
        raise RuntimeError(f"MODEL {MODEL!r} is not an owner/repo Hugging Face id")
    pattern = os.path.expanduser(
        f"~/.cache/huggingface/hub/models--{parts[0]}--{parts[1]}/snapshots/*/tokenizer.json"
    )
    matches = sorted(glob.glob(pattern))
    if not matches:
        raise RuntimeError(f"no tokenizer.json for {MODEL} matching {pattern}")
    return matches[-1]


def _tokenize_all(texts: list[str]) -> list[list[int]]:
    if not TOKENIZER_CLI.exists():
        raise RuntimeError(
            f"missing TOKENIZER_CLI at {TOKENIZER_CLI}; set TOKENIZER_CLI to a helper that "
            "accepts '<tokenizer.json>' argv plus a JSON string-list on stdin and emits JSON token-id lists"
        )
    proc = subprocess.run(
        [str(TOKENIZER_CLI), _tokenizer_json_path()],
        input=json.dumps(texts),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    )
    return json.loads(proc.stdout)


def _first_diff(a: list[int], b: list[int]) -> tuple[int | None, int | None, int | None]:
    for i, (x, y) in enumerate(zip(a, b)):
        if x != y:
            return i, x, y
    if len(a) != len(b):
        i = min(len(a), len(b))
        return i, a[i] if i < len(a) else None, b[i] if i < len(b) else None
    return None, None, None

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


async def main() -> int:
    assert h.PIE_BIN.exists(), f"missing pie binary at {h.PIE_BIN}"
    assert h.WASM_PATH.exists(), f"missing wasm at {h.WASM_PATH}"
    h.verify_stamp()

    failures: list[str] = []
    with tempfile.TemporaryDirectory(prefix="spec-real-") as tmp:
        tmp = Path(tmp)
        cfg = tmp / "config.toml"
        cfg.write_text(CONFIG_TOML)
        pie_home = tmp / "home"
        pie_home.mkdir()
        env = {**os.environ, "PIE_HOME": str(pie_home), "PIE_SHMEM_NAME": f"/spec_real_{os.getpid()}"}
        proc = subprocess.Popen(
            [str(h.PIE_BIN), "serve", "--config", str(cfg), "--no-auth", "--debug"],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env, bufsize=1,
        )
        try:
            ws_addr, token = await h._parse_handshake(proc, timeout=120)
            print(f"[smoke] engine ws=ws://{ws_addr}")
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

                msg = [{"role": "user", "content": "List the first six prime numbers, comma separated."}]
                body = {"model": MODEL, "messages": msg, "temperature": 0, "max_tokens": 64}
                forced_body = {
                    "model": MODEL,
                    "messages": [{"role": "user", "content": "What is 2+2?"}],
                    "temperature": 0,
                    "max_tokens": 32,
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
                }
                async with httpx.AsyncClient(timeout=180) as http_c:
                    r_plain = await http_c.post(f"{base}/v1/chat/completions", json=body)
                    r_spec = await http_c.post(
                        f"{base}/v1/chat/completions",
                        json={**body, "speculation": {"enabled": True}},
                    )
                    forced = await http_c.post(f"{base}/v1/chat/completions", json=forced_body)
                print(f"[smoke] plain -> {r_plain.status_code}; spec -> {r_spec.status_code}")
                if r_plain.status_code != 200 or r_spec.status_code != 200:
                    failures.append(f"non-200: plain={r_plain.status_code} spec={r_spec.status_code} "
                                    f"plain_body={r_plain.text[:300]!r} spec_body={r_spec.text[:300]!r}")
                else:
                    b_plain = json.loads(r_plain.text)
                    b_spec = json.loads(r_spec.text)

                    def _full(msg: dict) -> tuple[str, str]:
                        # Qwen3 is a thinking model: most/all output lands
                        # in `reasoning_content` (inside <think>), not
                        # `content`. Compare BOTH so the equivalence check
                        # exercises the actually-generated tokens, not an
                        # empty visible string.
                        m = msg["choices"][0]["message"]
                        return (m.get("content") or "", m.get("reasoning_content") or "")

                    def _message_text(body: dict) -> tuple[str, str]:
                        return _full(body)

                    def _compare_token_ids(label_a: str, label_b: str, ids: dict[str, tuple[list[int], list[int]]]) -> bool:
                        ok = True
                        for idx, channel in enumerate(("content", "reasoning")):
                            a = ids[label_a][idx]
                            b = ids[label_b][idx]
                            pos, x, y = _first_diff(a, b)
                            print(
                                f"[smoke] TOKEN_COMPARE {label_a} vs {label_b} "
                                f"channel={channel} len={len(a)}/{len(b)} equal={pos is None}"
                            )
                            if pos is not None:
                                lo = max(0, pos - 5)
                                hi = pos + 6
                                failures.append(
                                    f"token-id equivalence broken for {label_a} vs {label_b} "
                                    f"channel={channel} pos={pos} {label_a}_id={x} {label_b}_id={y} "
                                    f"{label_a}[{lo}:{hi}]={a[lo:hi]} {label_b}[{lo}:{hi}]={b[lo:hi]}"
                                )
                                ok = False
                                break
                        return ok

                    full_plain = _full(b_plain)
                    full_spec = _full(b_spec)
                    sm = b_spec.get("spec_metrics")
                    print(f"[smoke] plain content/reasoning lens={tuple(len(x) for x in full_plain)}")
                    print(f"[smoke] spec  content/reasoning lens={tuple(len(x) for x in full_spec)}")
                    print(f"[smoke] spec_metrics={sm}")
                    # Short-window gate: at max_tokens=64 the spec and plain
                    # greedy trajectories must be byte-identical. Drift only
                    # appears past a near-tie further out (#592), which the
                    # bench records; here it is a hard regression failure.
                    if full_spec != full_plain:
                        failures.append(
                            "short-window greedy equivalence broken: spec != plain "
                            f"within 64 tok (plain={full_plain!r} spec={full_spec!r})"
                        )
                    if sm is None:
                        failures.append("spec_metrics missing")
                    else:
                        if sm["accepted_draft_tokens"] + sm["rejected_draft_tokens"] != sm["proposed_draft_tokens"]:
                            failures.append(f"accounting inconsistent: {sm}")
                        if sm["accepted_draft_tokens"] <= 0:
                            failures.append(f"no draft tokens accepted on real text: {sm}")
                        else:
                            print(f"[smoke] ACCEPTED {sm['accepted_draft_tokens']}/{sm['proposed_draft_tokens']} "
                                  f"draft tokens, avg {sm['avg_tokens_per_step']:.2f} tok/step")

                    # Long deterministic token-id gate: this catches speculation
                    # rollback/page-accounting bugs that only surface at page
                    # boundaries. It intentionally compares token IDs (not text)
                    # for a >=96-token continuation: plain-vs-plain must be
                    # stable, and both rebuilt-per-request and persisted-sidecar
                    # speculation must stay greedy-identical.
                    # `/no_think` keeps the reasoning block empty and
                    # deterministic (`<think>\n\n</think>`) — a minimal think
                    # boundary that a warmed sidecar tends to accept together
                    # with the following content in a single multi-token
                    # speculative batch. That batch is the #466 regression
                    # trigger for reasoning text dropped at the close.
                    warm_messages = [{
                        "role": "user",
                        "content": (
                            "Output exactly this sequence, with spaces, and no commentary: "
                            + "red blue green yellow orange purple " * 14
                        ).strip() + " /no_think",
                    }]
                    continuation_user = (
                        "Continue the same color sequence for fourteen more repetitions. "
                        "Output only the sequence, with spaces, no bullets, no explanation. /no_think"
                    )
                    spec_rebuilt = {"enabled": True, "leader_len": 1, "draft_len": 3}
                    spec_sidecar = {
                        **spec_rebuilt,
                        "thread_id": "spec-smoke-real-96",
                        "profile_id": "determinism-gate",
                    }
                    async with httpx.AsyncClient(timeout=300) as http_c:
                        # Turn 1 warms the per-thread sidecar.
                        warm_sidecar = await http_c.post(
                            f"{base}/v1/chat/completions",
                            json={
                                "model": MODEL,
                                "messages": warm_messages,
                                "temperature": 0,
                                "max_tokens": 96,
                                "speculation": spec_sidecar,
                            },
                        )
                        # A real chat client echoes the assistant turn back.
                        # The continuation lineage [user, assistant, user2]
                        # must extend the persisted lineage [user, assistant]
                        # or the sidecar (correctly) forks and never reuses —
                        # the earlier gate omitted this and silently tested a
                        # COLD cache.
                        warm_assistant = ""
                        if warm_sidecar.status_code == 200:
                            warm_assistant = (
                                json.loads(warm_sidecar.text)["choices"][0]["message"].get("content") or ""
                            )
                        cont_messages = warm_messages + [
                            {"role": "assistant", "content": warm_assistant},
                            {"role": "user", "content": continuation_user},
                        ]
                        gate_common = {"model": MODEL, "messages": cont_messages, "temperature": 0, "max_tokens": 96}
                        gate_responses = {
                            "plain1": await http_c.post(f"{base}/v1/chat/completions", json=gate_common),
                            "plain2": await http_c.post(f"{base}/v1/chat/completions", json=gate_common),
                            "rebuilt": await http_c.post(
                                f"{base}/v1/chat/completions",
                                json={**gate_common, "speculation": spec_rebuilt},
                            ),
                            "persisted": await http_c.post(
                                f"{base}/v1/chat/completions",
                                json={**gate_common, "speculation": spec_sidecar},
                            ),
                        }
                    if warm_sidecar.status_code != 200:
                        failures.append(f"96-token sidecar warmup status {warm_sidecar.status_code}: {warm_sidecar.text[:200]!r}")
                    elif not warm_assistant.strip():
                        failures.append("96-token warm turn produced empty assistant content; continuation cannot reuse the sidecar")
                    if warm_sidecar.status_code != 200 or any(r.status_code != 200 for r in gate_responses.values()):
                        failures.append(
                            "96-token determinism gate non-200: "
                            + f"warm={warm_sidecar.status_code}, "
                            + ", ".join(f"{k}={v.status_code}" for k, v in gate_responses.items())
                        )
                    else:
                        gate_bodies = {k: json.loads(v.text) for k, v in gate_responses.items()}
                        labels = list(gate_bodies)
                        texts: list[str] = []
                        for label in labels:
                            content, reasoning = _message_text(gate_bodies[label])
                            texts.extend([content, reasoning])
                        try:
                            encoded = _tokenize_all(texts)
                        except Exception as exc:  # noqa: BLE001 - smoke should report the missing gate dependency.
                            failures.append(f"96-token tokenization gate failed: {exc}")
                        else:
                            ids: dict[str, tuple[list[int], list[int]]] = {}
                            it = iter(encoded)
                            for label in labels:
                                ids[label] = (next(it), next(it))
                            print(f"[smoke] 96-token warm spec_metrics={json.loads(warm_sidecar.text).get('spec_metrics')}")
                            for label, body_ in gate_bodies.items():
                                content, reasoning = _message_text(body_)
                                print(
                                    f"[smoke] 96-token {label} text_lens content/reasoning="
                                    f"{len(content)}/{len(reasoning)} token_lens="
                                    f"{len(ids[label][0])}/{len(ids[label][1])} spec_metrics={body_.get('spec_metrics')}"
                                )
                            _compare_token_ids("plain1", "plain2", ids)
                            _compare_token_ids("plain1", "rebuilt", ids)
                            _compare_token_ids("plain1", "persisted", ids)

                            # The persisted sidecar must actually REUSE the
                            # warmed table on a real same-thread continuation
                            # (not silently fork to a cold cache).
                            persisted_sm = gate_bodies["persisted"].get("spec_metrics") or {}
                            rebuilt_sm = gate_bodies["rebuilt"].get("spec_metrics") or {}
                            sidecar_status = persisted_sm.get("ngram_sidecar_status")
                            if sidecar_status != "reused":
                                failures.append(
                                    "96-token persisted sidecar did not reuse the warmed table: "
                                    f"ngram_sidecar_status={sidecar_status!r} "
                                    f"leaders={persisted_sm.get('ngram_sidecar_leaders')}"
                                )
                            # Warming must not COST throughput: the warmed
                            # cache proposes more drafts, so the acceptance
                            # RATE can dip while absolute work drops. Gate on
                            # the honest signals — accepted-token count and
                            # decode steps — not the proposal-normalized rate.
                            p_acc = persisted_sm.get("accepted_draft_tokens", 0) or 0
                            r_acc = rebuilt_sm.get("accepted_draft_tokens", 0) or 0
                            p_steps = persisted_sm.get("decode_steps", 0) or 0
                            r_steps = rebuilt_sm.get("decode_steps", 0) or 0
                            print(
                                f"[smoke] 96-token warming accepted persisted/rebuilt={p_acc}/{r_acc} "
                                f"decode_steps={p_steps}/{r_steps}"
                            )
                            if p_acc < r_acc or (r_steps and p_steps > r_steps):
                                failures.append(
                                    "96-token warmed sidecar did not help: "
                                    f"accepted persisted/rebuilt={p_acc}/{r_acc}, "
                                    f"decode_steps={p_steps}/{r_steps} (want accepted>= and steps<=)"
                                )

                # #418 x tool_choice: speculation gates OFF when a tool call
                # is FORCED (sampler constrained to the tool-call grammar).
                # The real model has a native tool grammar, so a forced
                # request 200s and returns a tool call; spec_metrics must
                # report enabled=false + fallback_reason=tool_choice_forced.
                # (The request was issued inside the client block above.)
                print(f"[smoke] forced tool + speculation -> {forced.status_code}")
                if forced.status_code != 200:
                    failures.append(
                        f"forced-tool request status {forced.status_code} "
                        f"(want 200): {forced.text[:200]!r}"
                    )
                else:
                    fb = json.loads(forced.text)
                    fsm = fb.get("spec_metrics")
                    tcs = fb["choices"][0].get("finish_reason")
                    tool_calls = fb["choices"][0]["message"].get("tool_calls")
                    print(f"[smoke] forced-tool finish_reason={tcs} tool_calls={bool(tool_calls)} spec_metrics={fsm}")
                    if fsm is None:
                        failures.append("forced-tool: spec_metrics missing")
                    elif fsm.get("enabled") is not False:
                        failures.append(f"forced-tool: speculation NOT gated off: {fsm}")
                    elif fsm.get("fallback_reason") != "tool_choice_forced":
                        failures.append(
                            f"forced-tool: fallback_reason={fsm.get('fallback_reason')!r} "
                            f"(want tool_choice_forced)"
                        )
                    else:
                        print("[smoke] forced-tool gate OK "
                              "(speculation off, fallback_reason=tool_choice_forced)")
            finally:
                drain.cancel()
        finally:
            h._terminate_subprocess(proc, "engine")

    if failures:
        print("\n[smoke] FAILURES:")
        for f in failures:
            print(f"  ✗ {f}")
        return 1
    print("\n[smoke] PASS: short-window greedy equivalence (64 tok) + real draft acceptance")
    return 0


if __name__ == "__main__":
    import sys
    sys.exit(asyncio.run(main()))
