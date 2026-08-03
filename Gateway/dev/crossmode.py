import json, os, urllib.request, sys
BASE = "http://127.0.0.1:%s" % os.environ.get("PORT", "8100")
KEY = sys.argv[1] if len(sys.argv) > 1 else "b2-crossmode"
# REGRESSION CASE — 32 is deliberately small enough that a reasoning model may
# spend the whole budget in its thinking block and return content="".
#
# The app excludes that empty assistant row from request history. gen-core must
# therefore leave the cue-free INPUT prompt as a reusable `conv/` checkpoint;
# the next mode finds it on the ladder and appends the next user turn. Hidden
# `reasoning_content` must never be copied into history merely to force a hit.
#
# With a non-thinking model this same gate exercises the deeper visible-answer
# boundary. Override MAX_TOKENS only when debugging answer quality, not to make
# cache reuse pass.
MAX_TOKENS = int(os.environ.get("MAX_TOKENS", "32"))

def post(path, body, stream=False):
    req = urllib.request.Request(BASE + path, data=json.dumps(body).encode(),
                                 headers={"content-type": "application/json"})
    raw = urllib.request.urlopen(req, timeout=900).read().decode()
    return raw

def boundary(turn):
    return {"key": KEY, "turn": turn, "compat": "1", "policy": "auto"}

def append_persisted_assistant(history, content):
    """Mirror ChatSendController.excludesFromRequestHistory exactly."""
    if content is None or content == "":
        return list(history)
    return list(history) + [{"role": "assistant", "content": content}]

def chat(msgs, turn, label):
    d = json.loads(post("/v1/chat/completions", {
        "model": "qwen", "stream": False, "temperature": 0, "max_tokens": MAX_TOKENS,
        "messages": msgs, "boundary": boundary(turn)}))
    txt = d["choices"][0]["message"]["content"]
    print(f"  {label}: prompt_tokens={d['usage']['prompt_tokens']}  -> {txt[:60]!r}")
    return txt

def tot(msgs, turn, label):
    raw = post("/v1/inferlet", {"inferlet": "tree-of-thought", "input": {
        "model": "qwen", "messages": msgs, "breadth": 2, "depth": 1, "beam_width": 1,
        "max_tokens_per_node": 64, "thinking": False, "temperature": 0.7,
        "boundary": boundary(turn)}})
    answer = None
    for line in raw.splitlines():
        if not line.startswith("data: "): continue
        p = line[6:].strip()
        if p == "[DONE]": break
        ev = json.loads(p)
        if ev.get("event") == "tree_complete":
            answer = ev.get("final_answer")
    print(f"  {label}: -> {str(answer)[:60]!r}")
    return answer

A = "The capital of France is"
print(f"key={KEY}")
print("turn 1  chat (cold)")
a1 = chat([{"role": "user", "content": A}], 1, "chat")
h = append_persisted_assistant([{"role": "user", "content": A}], a1)

B = "Name one prime number."
print("turn 2  ToT  <- must REUSE the boundary chat left")
a2 = tot(h + [{"role": "user", "content": B}], 2, "tot")
h2 = append_persisted_assistant(h + [{"role": "user", "content": B}], a2)

C = "And the capital of Italy?"
print("turn 3  chat <- must REUSE the boundary ToT left")
chat(h2 + [{"role": "user", "content": C}], 3, "chat")
