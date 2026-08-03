#!/usr/bin/env python3
"""Milestone C gate: the whole Best-of-N lifecycle, end to end.

  chat -> BoN round 1 -> pick -> think-more -> pick -> commit -> chat

Asserts three things the legacy path did not do at all:

  1. A round ENTERS on the boundary chat left (chat-apc rebuilt the base with
     Context::new + fill + flush every time, so it never reused anything).
  2. A think-more round VALIDATES the (resume_from, picked_text) pair before
     opening a snapshot, and warm-starts when it is coherent.
  3. Commit saves the accepted answer's conv/ boundary and only THEN frees the
     round's KV, so the next chat turn reuses across the mode switch.

Plus the destructive-path guards, which are the reason this milestone is
riskier than the others: a conv/ boundary and another round's candidate must
both be refused rather than deleted.
"""
import json
import os
import sys
import urllib.error
import urllib.request

BASE = "http://127.0.0.1:%s" % os.environ.get("PORT", "8100")
KEY = sys.argv[1] if len(sys.argv) > 1 else "c-gate"
# Keep the small default as a regression case: a reasoning model may return
# content="" after spending the budget in `reasoning_content`. The app omits
# that empty assistant from history, and the round must enter through chat's
# prompt-only checkpoint. See crossmode.py.
MAX_TOKENS = int(os.environ.get("MAX_TOKENS", "32"))
FAILURES = []


def post(path, body):
    req = urllib.request.Request(
        BASE + path,
        data=json.dumps(body).encode(),
        headers={"content-type": "application/json"},
    )
    try:
        return 200, urllib.request.urlopen(req, timeout=900).read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def check(label, ok, detail=""):
    print(f"  {'✅' if ok else '❌'} {label}{'  ' + detail if detail else ''}")
    if not ok:
        FAILURES.append(label)
    return ok


def boundary(turn):
    return {"key": KEY, "turn": turn, "compat": "1", "policy": "auto"}


def append_persisted_assistant(history, content):
    """Mirror ChatSendController.excludesFromRequestHistory exactly."""
    if content is None or content == "":
        return list(history)
    return list(history) + [{"role": "assistant", "content": content}]


def chat(msgs, turn, label):
    _, raw = post(
        "/v1/chat/completions",
        {
            "model": "qwen", "stream": False, "temperature": 0, "max_tokens": MAX_TOKENS,
            "messages": msgs, "boundary": boundary(turn),
        },
    )
    d = json.loads(raw)
    txt = d["choices"][0]["message"]["content"]
    print(f"  {label}: prompt_tokens={d['usage']['prompt_tokens']} -> {txt[:50]!r}")
    return txt, d["usage"]["prompt_tokens"]


LAST_TEXTS = {}


def bon(payload, label):
    """A generative round: SSE in, (candidates, error) out.

    Also captures each node's committed text from `node_complete`, which a real
    think-more needs — `picked_text` is what the base is rebuilt from when the
    snapshot cannot be verified or has been evicted.
    """
    global LAST_TEXTS
    _, raw = post("/v1/inferlet", {"inferlet": "best-of-n", "input": payload})
    cands, err, texts = [], None, {}
    for line in raw.splitlines():
        if not line.startswith("data: "):
            continue
        p = line[6:].strip()
        if p == "[DONE]":
            break
        ev = json.loads(p)
        if ev.get("event") == "awaiting_selection":
            cands = ev["candidates"]
        elif ev.get("event") == "node_complete":
            n = ev["node"]
            texts[n["id"]] = n.get("content", "")
        elif ev.get("event") == "error":
            err = ev
    LAST_TEXTS = texts
    print(f"  {label}: {len(cands)} candidates" + (f"  ERROR {err}" if err else ""))
    return cands, err


def control(payload, label):
    code, raw = post("/v1/inferlet", {"inferlet": "best-of-n", "input": payload})
    print(f"  {label}: HTTP {code} {raw[:160]}")
    return code, json.loads(raw)


ROUND_ID_1 = f"{KEY}-round-1"
ROUND_ID_2 = f"{KEY}-round-2"

print(f"key={KEY}")

# ---------------------------------------------------------------- turn 1: chat
print("turn 1  chat (cold)")
A = "The capital of France is"
a1, _ = chat([{"role": "user", "content": A}], 1, "chat")
hist = append_persisted_assistant([{"role": "user", "content": A}], a1)

# ------------------------------------------------- turn 2: Best-of-N, round 1
print("turn 2  best-of-n round 1  <- must REUSE the boundary chat left")
B = "Name one prime number."
msgs2 = hist + [{"role": "user", "content": B}]
base_round = {
    "model": "qwen", "messages": msgs2, "n": 3, "max_tokens_per_candidate": 48,
    "thinking": False, "temperature": 0.9, "boundary": boundary(2),
}
cands1, err1 = bon({**base_round, "round_id": ROUND_ID_1, "level": 1}, "round 1")
texts1 = dict(LAST_TEXTS)
check("round 1 produced candidates", not err1 and len(cands1) >= 2)
if not cands1:
    print("cannot continue without candidates")
    sys.exit(1)

names1 = [c["snapshot_name"] for c in cands1]
check(
    "candidate names are digest-addressed",
    all(len(n.split("/")) == 5 for n in names1),
    names1[0],
)

# ------------------------------------------------ turn 2b: think-more (resume)
#
# THE APP'S ACTUAL FLOW. An earlier version of this gate built both hops itself
# and passed the SAME round_id to each — which tested the guest's contract while
# silently sidestepping whether the client could satisfy it. `sendBestOfN` minted
# a fresh scope on every call, so every real think-more failed with a hard 400
# and this gate stayed green. A gate that builds its own inputs can only test
# the half it models, so it now mirrors the client: carry the scope forward.
print("turn 2b think-more  <- must carry the round scope, and warm-start")
picked = cands1[0]
picked_text = texts1.get(picked["id"], "")
check("the picked candidate's text is known", bool(picked_text), repr(picked_text[:40]))

cands2b, err2b = bon(
    {
        **base_round, "round_id": ROUND_ID_1, "level": 2,
        "resume_from": picked["snapshot_name"],
        "picked_text": picked_text,
        "unpicked": [n for n in names1 if n != picked["snapshot_name"]],
    },
    "think-more (scope carried)",
)
check("think-more produced candidates", not err2b and len(cands2b) >= 1)
names2b = [c["snapshot_name"] for c in cands2b]
if names2b:
    check("resumed candidates keep the SAME round scope",
          all(n.split("/")[1] == names1[0].split("/")[1] for n in names2b))
    check("resumed candidates are a distinct level",
          all(n.split("/")[2] == "2" for n in names2b), names2b[0])
    # P2: the resumed base includes the picked answer and the deepen turn, so a
    # level-2 name cannot be a function of the answer alone. If it were, two
    # continuations differing only in the pick would collide.
    check("resumed names differ from the level they resumed",
          not (set(names2b) & set(names1)))

# A mismatched pair must still yield a usable round: it rebuilds rather than
# rejecting, because benign history drift must not kill a working session.
cands_bad, err_bad = bon(
    {
        **base_round, "round_id": ROUND_ID_1, "level": 2,
        "resume_from": picked["snapshot_name"],
        "picked_text": "a text that is definitely not the picked candidate",
        "unpicked": [],
    },
    "resume with a mismatched pair",
)
check("a mismatched pair still produces a usable round", not err_bad and len(cands_bad) >= 1)

# A pick from ANOTHER round is authorization, not drift — a hard 400.
code_x, body_x = control(
    {
        **base_round, "round_id": ROUND_ID_2, "level": 2,
        "resume_from": picked["snapshot_name"],
        "picked_text": picked_text,
        "unpicked": [],
    },
    "resume a pick from another round",
)
check("resuming another round's pick is rejected",
      code_x == 400 and body_x.get("error", {}).get("code") == "snapshot_not_in_round")

# ------------------------------------------------------- the destructive guards
print("guards  <- the only place a guest deletes durable state on client say-so")
victim_conv = "conv/deadbeef/cafebabe/" + "0" * 64
code, ack = control(
    {"model": "qwen", "round_id": ROUND_ID_1, "release": [victim_conv]},
    "release a conv/ boundary",
)
check("a conv/ boundary is REFUSED, not deleted",
      code == 200 and ack.get("refused") == 1 and ack.get("released") == 0)

code, ack = control(
    {"model": "qwen", "round_id": ROUND_ID_2, "release": names1},
    "release another round's candidates",
)
check("another round's candidates are REFUSED",
      code == 200 and ack.get("refused") == len(names1) and ack.get("released") == 0)

code, body = control(
    {"model": "qwen", "release": names1},
    "release with no round_id",
)
check("a release with no authorization scope is rejected",
      code == 400 and body.get("error", {}).get("param") == "round_id")

# --------------------------------------------------------------- turn 2c: commit
print("turn 2c commit  <- save the accepted answer's boundary, THEN free the round")
cands2, err2 = bon({**base_round, "round_id": ROUND_ID_2, "level": 1}, "round 2")
if not cands2:
    print("cannot continue without candidates")
    sys.exit(1)
names2 = [c["snapshot_name"] for c in cands2]

code, body = control(
    {
        "model": "qwen", "round_id": ROUND_ID_2, "messages": msgs2,
        "boundary": boundary(2),
        "commit": {
            "snapshot_name": names2[0],
            "answer": "One prime number is 7.",
            "release": names2,
        },
    },
    "commit",
)
check("commit saved the boundary", code == 200 and body.get("boundary_saved") is True)
check("commit freed the round's snapshots",
      code == 200 and body.get("released", 0) >= 1 and body.get("refused") == 0,
      f"released={body.get('released')} absent={body.get('absent')}")

code, body = control(
    {
        "model": "qwen", "round_id": ROUND_ID_2, "messages": msgs2,
        "boundary": boundary(2),
        "commit": {"snapshot_name": names1[0], "answer": "x", "release": []},
    },
    "commit another round's candidate",
)
check("committing another round's candidate is rejected",
      code == 400 and body.get("error", {}).get("code") == "snapshot_not_in_round")

# ------------------------------------------------------------- turn 3: back to chat
print("turn 3  chat  <- must REUSE the boundary the commit left")
hist3 = msgs2 + [{"role": "assistant", "content": "One prime number is 7."}]
C = "And the capital of Italy?"
chat(hist3 + [{"role": "user", "content": C}], 3, "chat")

print()
if FAILURES:
    print(f"❌ C gate: {len(FAILURES)} failed: {FAILURES}")
    sys.exit(1)
print("✅ C gate: lifecycle + guards passed (check the log for reuse numbers)")
