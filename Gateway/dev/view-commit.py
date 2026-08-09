#!/usr/bin/env python3
"""The view-side commit, using Swift's OWN encoded bytes.

Every other gate here builds its request in Python, which means it can only test
the half it models. That cost two live outages already — a think-more that 400'd
on every attempt, and ToT/Best-of-N failing entirely in the app — both invisible
because no gate constructed what the client constructs.

This gate does not write a request body at all. It:

  1. runs a REAL Best-of-N round, so the candidate name is one the guest minted;
  2. shells out to `bon-commit-body`, which runs
     `ChatSendController.prepareBestOfNCommit` — the same code path the view
     runs — and prints the complete dispatch envelope;
  3. POSTs those bytes verbatim, to the URL the client's routing rule selects;
  4. derives the FOLLOW-UP chat turn from Swift's own `messages` and `boundary`,
     rather than restating them.

So the only things Python contributes are the two prompt strings and the URL.
If the encoder renames a key, drops the system turn, or lets the accepted answer
into `messages`, the boundary it names stops being the one the next chat turn
asks for — and step 4 stops reusing.
"""
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

BASE = "http://127.0.0.1:%s" % os.environ.get("PORT", "8100")
REPO = subprocess.run(["git", "rev-parse", "--show-toplevel"],
                      capture_output=True, text=True, check=True).stdout.strip()
EMITTER = f"{REPO}/.build/debug/bon-commit-body"

KEY = sys.argv[1] if len(sys.argv) > 1 else "view-commit"
ROUND_ID = f"{KEY}-round"
SYSTEM = "Be concise."
USER = "Name one prime number."
ANSWER = "One prime number is 7."
FAILURES = []


def check(label, ok, detail=""):
    print(f"  {'PASS' if ok else 'FAIL'}  {label}{'  ' + detail if detail else ''}")
    if not ok:
        FAILURES.append(label)
    return ok


def post(path, raw_body: bytes, timeout=900):
    req = urllib.request.Request(BASE + path, data=raw_body,
                                 headers={"content-type": "application/json"})
    try:
        return 200, urllib.request.urlopen(req, timeout=timeout).read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


# ---------------------------------------------------------------- a real round
print("round: a real Best-of-N round, so the candidate name is the guest's")
round_body = json.dumps({
    "inferlet": "best-of-n", "stream": True,
    "input": {
        "model": "qwen", "round_id": ROUND_ID, "level": 2,
        # The same two strings `bon-commit-body` is given, so the candidate is
        # minted over the base Swift's `messages` will describe. Asserted below
        # rather than assumed.
        "messages": [{"role": "system", "content": SYSTEM},
                     {"role": "user", "content": USER}],
        "n": 2, "max_tokens_per_candidate": 40, "thinking": False,
        "temperature": 0.9,
    }}).encode()
_, raw = post("/v1/chat/completions", round_body)  # the URL the client uses
cands = []
for line in raw.splitlines():
    if line.startswith("data: ") and line[6:].strip() != "[DONE]":
        ev = json.loads(line[6:])
        if ev.get("event") == "awaiting_selection":
            cands = ev["candidates"]
print(f"  {len(cands)} candidates")
if not cands:
    sys.exit("no candidates — cannot exercise the commit")
snapshot = cands[0]["snapshot_name"]

# ------------------------------------------------------- Swift builds the body
print("body: emitted by ChatSendController.prepareBestOfNCommit")
emitted = subprocess.run(
    [EMITTER, "--round-id", ROUND_ID, "--snapshot", snapshot,
     "--answer", ANSWER, "--user", USER, "--system", SYSTEM],
    capture_output=True, check=False)
if emitted.returncode != 0:
    sys.exit(f"bon-commit-body failed: {emitted.stderr.decode()}")
body = emitted.stdout
env = json.loads(body)
inp = env["input"]
print(f"  {len(body)} bytes, input keys: {sorted(inp)}")

# What Swift shaped, asserted rather than assumed.
check("the accepted answer is NOT in messages",
      not any(m["content"] == ANSWER for m in inp["messages"]))
check("the system prompt IS in messages",
      any(m["role"] == "system" and m["content"] == SYSTEM for m in inp["messages"]))
check("the round scope is carried", inp.get("round_id") == ROUND_ID)
check("the chosen candidate is the one the guest minted",
      inp["commit"]["snapshot_name"] == snapshot)
check("a boundary directive is present", isinstance(inp.get("boundary"), dict))

# The client's routing rule: stream:false with no `release` -> /v1/inferlet.
path = "/v1/inferlet" if not env["stream"] and not inp.get("release") else "/v1/chat/completions"
print(f"commit: POSTing Swift's bytes verbatim to {path}")
code, raw = post(path, body)
print(f"  HTTP {code} {raw[:180]}")
ack = json.loads(raw) if code == 200 else {}
check("commit saved the boundary", code == 200 and ack.get("boundary_saved") is True)
check("commit freed the round", code == 200 and ack.get("refused") == 0)

# ------------------------------- the follow-up turn, derived from Swift's body
#
# `messages` and `boundary` come out of the emitted body, so this turn asks for
# exactly the boundary the commit named. Rebuilding them here would be the very
# hand-approximation this gate exists to remove.
print("next chat turn: derived from Swift's own messages + boundary")
bnd = dict(inp["boundary"])
bnd["turn"] = bnd.get("turn", 2) + 1
follow = inp["messages"] + [
    {"role": "assistant", "content": ANSWER},
    {"role": "user", "content": "And another one?"},
]
_, raw = post("/v1/chat/completions", json.dumps({
    "model": "qwen", "stream": False, "temperature": 0, "max_tokens": 24,
    "messages": follow, "boundary": bnd}).encode())
d = json.loads(raw)
print(f"  prompt_tokens={d['usage']['prompt_tokens']} -> "
      f"{d['choices'][0]['message']['content'][:40]!r}")

print()
if FAILURES:
    print(f"FAILED: {FAILURES}")
    sys.exit(1)
print("Swift's own commit body was accepted; check the log for reuse on that turn")
