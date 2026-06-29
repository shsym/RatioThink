#!/usr/bin/env python3
"""Real-model Best-of-N round-trip smoke — gated, NOT in CI.

Boots `pie serve` with the portable Metal driver over the staged
Qwen3-0.6B-Q8_0 GGUF, installs chat-apc.wasm, and drives the interactive
Best-of-N profile end-to-end across multiple `/v1/chat/completions`
advanced-profile requests — the round model where the engine generates N
candidates, the user picks one, and a think-more round resumes from that pick.

Best-of-N always streams (the N-pane UI consumes per-candidate deltas), so the
driver consumes the SSE event stream — which is also where the parallel-decode
evidence lives. It asserts, against a real model:

  (a) CO-BATCH / parallel decode: all N candidates emit `node_start` before any
      `node_complete` (all in flight at once), and their `node_delta` chunks
      INTERLEAVE by id — a serialized "finish candidate 0, then 1, …" stream
      would show ~N-1 id transitions; concurrent decode shows many more.
  (b) DIVERGENCE: the N final candidate answers are not near-duplicates — at
      least one sibling pair is below the duplicate threshold (real stances).
  (c) RESUME across the request boundary:
        * WARM: a think-more round whose `resume_from` is a real round-1 pick
          snapshot opens that KV state in a SEPARATE request and expands deeper.
        * FALLBACK: a think-more round whose `resume_from` names an evicted /
          nonexistent snapshot falls back to re-prefilling the base from
          `messages` + `picked_text` and still produces N candidates.
  (d) DAEMON SURVIVAL: the engine survives the whole multi-round sequence of
      `/v1/chat/completions` advanced-profile requests (thinking OFF, so it
      never rides the ToT thinking-ON crash path).

Usage:
    Scripts/run-bestofn-real-smoke.sh
    # or directly, with the staged model + built pie/wasm in place:
    uv run --project Vendor/pie/client/python --with httpx \
        python Inferlets/chat-apc/bestofn_real_smoke.py
"""

from __future__ import annotations

import asyncio
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

import httpx

sys.path.insert(0, str(Path(__file__).resolve().parent))
import e2e_test as e2e  # noqa: E402
from pie_client import PieClient  # noqa: E402
from tot_profile_accuracy import ArmResult, parse_best_of_n_stream  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
MODEL_PATH = Path(
    os.environ.get(
        "BESTOFN_SMOKE_MODEL",
        str(ROOT / "test-models" / "Qwen3-0.6B-Q8_0.gguf"),
    )
)

N = int(os.environ.get("BESTOFN_SMOKE_N", "5"))
DUP_THRESHOLD = 0.8  # mirrors Rust super::diversity::DUP_THRESHOLD

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
name = "default"
hf_repo = "{MODEL_PATH}"

[model.scheduler]
batch_policy = "adaptive"
request_timeout_secs = 600
default_endowment_pages = 8
admission_oversubscription_factor = 8.0
restore_pause_at_utilization = 0.85

[model.driver]
type = "portable"
device = ["metal"]

[model.driver.options]
"""

PROMPT = "What's a good way to spend a free Saturday afternoon? Give me one idea."


def word_set(text: str) -> set[str]:
    out: set[str] = set()
    cur: list[str] = []
    for ch in text:
        if ch.isalnum():
            cur.append(ch.lower())
        elif cur:
            out.add("".join(cur))
            cur = []
    if cur:
        out.add("".join(cur))
    return out


def jaccard(a: str, b: str) -> float:
    sa, sb = word_set(a), word_set(b)
    union = sa | sb
    return len(sa & sb) / len(union) if union else 1.0


def pairwise_sims(texts: list[str]) -> list[float]:
    real = [t for t in texts if t.strip()]
    sims = []
    for i in range(len(real)):
        for j in range(i + 1, len(real)):
            sims.append(jaccard(real[i], real[j]))
    return sims


class RoundResult:
    """Frames + derived evidence from one Best-of-N round's SSE stream."""

    def __init__(self) -> None:
        self.node_starts: list[str] = []          # ids, in arrival order
        self.delta_ids: list[str] = []            # node_delta ids, in arrival order
        self.first_complete_after_starts = True   # all node_start before any node_complete?
        self.contents: dict[str, str] = {}        # id -> final content (node_complete)
        self.statuses: dict[str, str] = {}        # id -> status
        self.errors: dict[str, str] = {}          # id -> error (non-ok nodes)
        self.candidates: list[dict] = []          # awaiting_selection candidates
        self.level: int | None = None
        self.error: dict | None = None
        self.profile_arm: ArmResult | None = None
        self._seen_complete = False

    def feed(self, frame: dict) -> None:
        ev = frame.get("event")
        if ev == "node_start":
            self.node_starts.append(frame["id"])
            if self._seen_complete:
                self.first_complete_after_starts = False
        elif ev == "node_delta":
            self.delta_ids.append(frame["id"])
        elif ev == "node_complete":
            self._seen_complete = True
            node = frame.get("node", {})
            self.contents[node.get("id", "")] = node.get("content", "") or ""
            self.statuses[node.get("id", "")] = node.get("status", "")
            if node.get("error"):
                self.errors[node.get("id", "")] = node.get("error", "")
        elif ev == "level_pruned":
            self.level = frame.get("level")
        elif ev == "awaiting_selection":
            self.level = frame.get("level")
            self.candidates = frame.get("candidates", [])
        elif ev == "error":
            self.error = frame

    # ---- derived evidence ----
    def delta_transitions(self) -> int:
        """# of times consecutive node_delta frames switch id. Serialized
        generation ≈ (distinct ids − 1); concurrent decode interleaves → many
        more."""
        return sum(
            1 for a, b in zip(self.delta_ids, self.delta_ids[1:]) if a != b
        )

    def distinct_delta_ids(self) -> int:
        return len(set(self.delta_ids))

    def ok_contents(self) -> list[str]:
        return [
            self.contents[c["id"]]
            for c in self.candidates
            if self.statuses.get(c["id"]) == "ok"
        ]


async def run_round(http: httpx.AsyncClient, base: str, payload: dict) -> RoundResult:
    """POST a Best-of-N round and consume its SSE stream into a RoundResult."""
    result = RoundResult()
    sse_lines: list[str] = []
    async with http.stream(
        "POST",
        f"{base}/v1/chat/completions",
        json=payload,
        headers={"accept": "text/event-stream"},
    ) as resp:
        if resp.status_code != 200:
            body = (await resp.aread()).decode("utf-8", "replace")
            raise RuntimeError(f"round failed {resp.status_code}: {body[:400]}")
        async for line in resp.aiter_lines():
            line = line.strip()
            if not line.startswith("data:"):
                continue
            data = line[len("data:"):].strip()
            if not data:
                continue
            sse_lines.append(f"data: {data}")
            if data == "[DONE]":
                continue
            try:
                frame = json.loads(data)
            except json.JSONDecodeError:
                continue
            result.feed(frame)
    result.profile_arm = parse_best_of_n_stream(
        "\n".join(sse_lines), lambda text: len(text.split())
    )
    return result


def round1_payload() -> dict:
    return {
        "inferlet": "best-of-n",
        "stream": True,
        "input": {
            "messages": [{"role": "user", "content": PROMPT}],
            "n": N,
            "max_tokens_per_candidate": 96,
            "temperature": 0.8,
            "top_p": 0.95,
        },
    }


def think_more_payload(*, resume_from: str, picked_text: str, unpicked: list[str], level: int) -> dict:
    return {
        "inferlet": "best-of-n",
        "stream": True,
        "input": {
            "messages": [{"role": "user", "content": PROMPT}],
            "n": N,
            "max_tokens_per_candidate": 96,
            "temperature": 0.8,
            "top_p": 0.95,
            "resume_from": resume_from,
            "picked_text": picked_text,
            "unpicked": unpicked,
            "level": level,
        },
    }


async def release_snapshots(http: httpx.AsyncClient, base: str, names: list[str]) -> dict:
    """POST a Best-of-N lifecycle release (no generation) and return the
    accounting ack {requested, released, absent}."""
    r = await http.post(
        f"{base}/v1/chat/completions",
        json={"inferlet": "best-of-n", "stream": False, "input": {"release": names}},
    )
    if r.status_code != 200:
        raise RuntimeError(f"release failed {r.status_code}: {r.text[:300]}")
    return r.json()


def report_round(tag: str, r: RoundResult) -> None:
    print(f"\n===== {tag} =====")
    print(f"  node_starts={len(r.node_starts)} distinct_delta_ids={r.distinct_delta_ids()} "
          f"delta_transitions={r.delta_transitions()} all_started_before_complete={r.first_complete_after_starts}")
    print(f"  level={r.level} candidates={len(r.candidates)} error={r.error}")
    if r.profile_arm is not None:
        print(
            "  profile parser: "
            f"selected={r.profile_arm.selected_candidate_id} "
            f"tokens={r.profile_arm.tokens} "
            f"snapshots={len(r.profile_arm.release_snapshots)} "
            f"error={r.profile_arm.error}"
        )
    # Per-node statuses (incl. nodes that streamed but were not pickable) — the
    # diagnostic for a no_candidates terminal: distinguishes generate failure
    # (incomplete/error) from persist failure (KV could not be saved).
    if not r.candidates and (r.statuses or r.node_starts):
        print(f"  node statuses: {r.statuses}")
        print(f"  node errors:   {r.errors}")
    for c in r.candidates:
        cid = c["id"]
        txt = (r.contents.get(cid, "") or "").replace("\n", " ")
        print(f"    cand[{c['branch_index']}] id={cid} snap={c['snapshot_name']} status={r.statuses.get(cid)}")
        print(f"              {txt[:160]}")
    sims = pairwise_sims(r.ok_contents())
    if sims:
        print(f"  pairwise Jaccard: min={min(sims):.2f} mean={sum(sims)/len(sims):.2f} max={max(sims):.2f}")


def check_round(tag: str, r: RoundResult, *, expect_level: int, failures: list[str],
                require_cobatch: bool) -> None:
    if r.error is not None:
        failures.append(f"{tag}: terminal error frame {r.error}")
        return
    if not r.candidates:
        failures.append(f"{tag}: no pickable candidates (awaiting_selection empty)")
        return
    if r.level != expect_level:
        failures.append(f"{tag}: level={r.level}, expected {expect_level}")
    if r.profile_arm is None:
        failures.append(f"{tag}: profile parser was not run over the real SSE stream")
    elif r.profile_arm.error:
        failures.append(f"{tag}: profile parser rejected real SSE: {r.profile_arm.error}")
    else:
        candidate_ids = {str(c.get("id")) for c in r.candidates}
        if r.profile_arm.selected_candidate_id not in candidate_ids:
            failures.append(
                f"{tag}: profile parser selected {r.profile_arm.selected_candidate_id!r}, "
                f"not one of awaiting_selection candidates {sorted(candidate_ids)!r}"
            )
        if not r.profile_arm.answer:
            failures.append(f"{tag}: profile parser returned an empty selected answer")
        if not r.profile_arm.release_snapshots:
            failures.append(f"{tag}: profile parser did not expose candidate snapshots to release")
        elif set(r.profile_arm.release_snapshots) != {
            str(c.get("snapshot_name")) for c in r.candidates if c.get("snapshot_name")
        }:
            failures.append(
                f"{tag}: profile parser release snapshots {r.profile_arm.release_snapshots!r} "
                f"do not match awaiting_selection candidates {r.candidates!r}"
            )
        if r.profile_arm.tokens <= 0:
            failures.append(f"{tag}: profile parser token count {r.profile_arm.tokens} <= 0")
    n_ok = sum(1 for c in r.candidates if r.statuses.get(c["id"]) == "ok")
    if n_ok < 2:
        failures.append(f"{tag}: only {n_ok} ok candidate(s); need >=2 to judge divergence")
        return
    # (a) co-batch / parallel decode
    if require_cobatch:
        if not r.first_complete_after_starts:
            failures.append(f"{tag}: a candidate completed before all node_starts arrived "
                            "(siblings not all in flight)")
        transitions = r.delta_transitions()
        distinct = r.distinct_delta_ids()
        # Serialized would be ~distinct-1; require clearly more interleaving.
        if transitions <= distinct:
            failures.append(f"{tag}: delta_transitions={transitions} <= distinct_ids={distinct} "
                            "— candidate streams did not interleave (looks serialized)")
    # (b) divergence
    sims = pairwise_sims(r.ok_contents())
    if not (sims and min(sims) < DUP_THRESHOLD):
        mn = min(sims) if sims else 1.0
        failures.append(f"{tag}: candidates near-duplicate (min pairwise Jaccard {mn:.2f} "
                        f">= {DUP_THRESHOLD}); divergence not real")


async def main() -> int:
    assert e2e.PIE_BIN.exists(), f"missing pie binary at {e2e.PIE_BIN} (build: make engine-build)"
    assert e2e.WASM_PATH.exists(), f"missing wasm at {e2e.WASM_PATH} (build: make build-inferlets)"
    assert MODEL_PATH.exists(), f"missing model at {MODEL_PATH} (stage: Scripts/stage-test-model.sh)"

    failures: list[str] = []
    shmem_base = f"/pie_bon_{os.getpid()}"
    # PIE_HOME must be a SHORT path: the engine builds a unix-domain aux.sock at
    # <PIE_HOME>/standalone/<pid>/g0/aux.sock, and sun_path caps at ~104 bytes —
    # a temp dir under /var/folders/… overruns it. Use a short /tmp dir.
    pie_home = Path(tempfile.mkdtemp(prefix="pb", dir="/tmp"))
    with tempfile.TemporaryDirectory(prefix="bestofn-smoke-") as tmp:
        tmp = Path(tmp)
        cfg = tmp / "config.toml"
        cfg.write_text(CONFIG_TOML)
        env = {**os.environ, "PIE_HOME": str(pie_home), "PIE_SHMEM_NAME": shmem_base}

        proc = subprocess.Popen(
            [str(e2e.PIE_BIN), "serve", "--config", str(cfg), "--no-auth", "--debug"],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env, bufsize=1,
        )
        try:
            ws_addr, token = await e2e._parse_handshake(proc, timeout=180)
            print(f"[bon-smoke] engine ws={ws_addr} token={token[:8]}…")
            drain = asyncio.create_task(e2e._drain_stdout(proc))
            try:
                client = PieClient(f"ws://{ws_addr}")
                await client.connect()
                await client.auth_by_token(token)
                await client.install_program(e2e.WASM_PATH, e2e.MANIFEST_PATH, force_overwrite=True)
                http_port = e2e._free_port()
                base = f"http://127.0.0.1:{http_port}"
                await client.launch_daemon("chat-apc@0.1.0", http_port)
                if not e2e._wait_for_port(http_port, timeout=30):
                    raise RuntimeError(f"daemon never bound port {http_port}")

                async with httpx.AsyncClient(timeout=600) as http:
                    # ── Round 1: N parallel candidates ──
                    r1 = await run_round(http, base, round1_payload())
                    report_round("round-1 (generate N)", r1)
                    check_round("round-1", r1, expect_level=1, failures=failures,
                                require_cobatch=True)

                    # Pick branch 0 (the user's choice); the rest are unpicked.
                    if r1.candidates:
                        pick = r1.candidates[0]
                        picked_text = r1.contents.get(pick["id"], "")
                        unpicked = [c["snapshot_name"] for c in r1.candidates[1:]]

                        # ── Round 2: WARM think-more (resume real pick) ──
                        r2 = await run_round(http, base, think_more_payload(
                            resume_from=pick["snapshot_name"],
                            picked_text=picked_text,
                            unpicked=unpicked,
                            level=2,
                        ))
                        report_round("round-2 (think-more, WARM resume)", r2)
                        check_round("round-2-warm", r2, expect_level=2, failures=failures,
                                    require_cobatch=True)

                        # ── Round 3: open-miss → REPREFILL fallback ──
                        # A realistic think-more FROM round-2 whose picked
                        # snapshot was evicted during the pick: `resume_from`
                        # names a (here, deliberately bogus) snapshot so open()
                        # MISSES, and the round must re-prefill the base from
                        # messages + picked_text and still produce N candidates.
                        # The round-2 siblings are passed as `unpicked` so they
                        # are freed first (exactly as a real pick would), which
                        # also relieves KV-page pressure from the prior round.
                        if r2.candidates:
                            r2_pick = r2.candidates[0]
                            r2_picked_text = r2.contents.get(r2_pick["id"], "") or picked_text
                            r2_unpicked = [c["snapshot_name"] for c in r2.candidates[1:]]
                            r3 = await run_round(http, base, think_more_payload(
                                resume_from=f"bon/evicted-{os.getpid()}/2/0",
                                picked_text=r2_picked_text,
                                unpicked=r2_unpicked,
                                level=3,
                            ))
                            report_round("round-3 (think-more, REPREFILL fallback)", r3)
                            check_round("round-3-reprefill", r3, expect_level=3, failures=failures,
                                        require_cobatch=False)  # fallback path: assert it still produces N divergent candidates

                            # ── Lifecycle release (stop/commit + abandon) ──
                            # Round 3 has no further round, so its candidate
                            # snapshots are exactly what stop/commit (or abandon)
                            # must free. Release them, then RE-release the same
                            # names: the first frees all (released=N), the second
                            # finds them all gone (absent=N) — the accounting
                            # proof that the snapshots, and their KV pages, were
                            # actually returned (the runtime delete frees the
                            # pages and errors on a missing snapshot). The
                            # mechanism is identical for stop/commit and abandon;
                            # only the App-side trigger differs.
                            if r3.candidates:
                                r3_snaps = [c["snapshot_name"] for c in r3.candidates]
                                n3 = len(r3_snaps)
                                ack1 = await release_snapshots(http, base, r3_snaps)
                                ack2 = await release_snapshots(http, base, r3_snaps)
                                print("\n===== lifecycle release (stop/commit + abandon) =====")
                                print(f"  release:    {ack1}")
                                print(f"  re-release: {ack2}  (all absent ⇒ snapshots + pages freed)")
                                if not (ack1.get("released") == n3 and ack1.get("absent") == 0):
                                    failures.append(
                                        f"release: freed {ack1.get('released')}/{n3} (absent "
                                        f"{ack1.get('absent')}); stop/commit must free every snapshot")
                                if not (ack2.get("released") == 0 and ack2.get("absent") == n3):
                                    failures.append(
                                        f"re-release: {ack2.get('released')} freed / {ack2.get('absent')} "
                                        f"absent; expected all absent — snapshots were not actually "
                                        f"deleted (KV page leak)")
            finally:
                drain.cancel()
                with __import__("contextlib").suppress(asyncio.CancelledError, Exception):
                    await drain
        finally:
            # (d) daemon survival: the engine must still be alive after the
            # whole multi-round sequence (it was never killed by a crash).
            alive = proc.poll() is None
            if not alive:
                failures.append(f"daemon exited mid-sequence (returncode={proc.returncode}) "
                                "— did not survive the multi-round Best-of-N requests")
            else:
                print("\n[bon-smoke] daemon alive after all rounds ✓")
            e2e._terminate_subprocess(proc, "pie")
            __import__("shutil").rmtree(pie_home, ignore_errors=True)

    print("\n==================== BEST-OF-N SMOKE RESULT ====================")
    if failures:
        print("RESULT: FAIL")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("RESULT: PASS")
    print("  (a) co-batch parallel decode  (b) real divergence  "
          "(c) warm resume + reprefill fallback  (d) daemon survived  "
          "(e) stop/commit+abandon release frees snapshots (re-release all absent)  "
          "(f) profile parser accepted the real Best-of-N SSE envelope")
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
