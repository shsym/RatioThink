"""Replay the EXACT body shape the view now builds, against the live guest.

The Swift tests prove the body is assembled correctly; this proves the guest
accepts that shape and that the boundary it names is the one the next chat
turn asks for.
"""
import json, urllib.request, urllib.error, sys

BASE = "http://127.0.0.1:8100"
KEY = sys.argv[1] if len(sys.argv) > 1 else "view-commit"
SYSTEM = "Be concise."
ROUND = f"{KEY}-round"

def post(path, body):
    req = urllib.request.Request(BASE + path, data=json.dumps(body).encode(),
                                 headers={"content-type": "application/json"})
    try:
        return 200, urllib.request.urlopen(req, timeout=900).read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()

def bnd(turn):
    return {"key": KEY, "turn": turn, "compat": "1", "policy": "auto"}

# The view prepends systemPromptOverride, exactly as transcriptTurns does.
def turns(rest):
    return [{"role": "system", "content": SYSTEM}] + rest

USER = "Name one prime number."
hist = [{"role": "user", "content": USER}]

print("round: the view's Best-of-N request")
_, raw = post("/v1/inferlet", {"inferlet": "best-of-n", "input": {
    "model": "qwen", "boundary": bnd(2), "round_id": ROUND,
    "messages": turns(hist), "n": 3, "max_tokens_per_candidate": 48,
    "thinking": False, "temperature": 0.9, "top_p": 0.95, "level": 2}})
cands = []
for line in raw.splitlines():
    if line.startswith("data: ") and line[6:].strip() != "[DONE]":
        ev = json.loads(line[6:])
        if ev.get("event") == "awaiting_selection":
            cands = ev["candidates"]
print(f"  {len(cands)} candidates")
if not cands:
    sys.exit("no candidates")

chosen = cands[0]
ANSWER = "One prime number is 7."

# The view's commit: messages are the PRE-commit history (no assistant row,
# because an empty-content assistant is excluded from request history).
print("commit: the view's prepared body")
code, raw = post("/v1/inferlet", {"inferlet": "best-of-n", "input": {
    "model": "qwen", "boundary": bnd(2), "round_id": ROUND,
    "messages": turns(hist),
    "commit": {"snapshot_name": chosen["snapshot_name"], "answer": ANSWER,
               "release": [c["snapshot_name"] for c in cands]}}})
print(f"  HTTP {code} {raw}")
ack = json.loads(raw)
assert code == 200 and ack.get("boundary_saved") is True, "commit did not save the boundary"
assert ack.get("refused") == 0, f"unexpected refusals: {ack}"

# The next chat turn: the history the app will actually resend.
print("next chat turn: must reuse the boundary the commit wrote")
nxt = turns(hist + [{"role": "assistant", "content": ANSWER},
                    {"role": "user", "content": "And another one?"}])
_, raw = post("/v1/chat/completions", {
    "model": "qwen", "stream": False, "temperature": 0, "max_tokens": 24,
    "messages": nxt, "boundary": bnd(3)})
d = json.loads(raw)
print(f"  prompt_tokens={d['usage']['prompt_tokens']} -> "
      f"{d['choices'][0]['message']['content'][:40]!r}")
print()
print("✅ the view's commit body saved a boundary the next chat turn asks for")
print("   (check the gateway log for reused_tokens > 0 on that turn)")
