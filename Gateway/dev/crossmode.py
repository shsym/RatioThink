import json, urllib.request, sys
BASE = "http://127.0.0.1:8100"
KEY = sys.argv[1] if len(sys.argv) > 1 else "b2-crossmode"

def post(path, body, stream=False):
    req = urllib.request.Request(BASE + path, data=json.dumps(body).encode(),
                                 headers={"content-type": "application/json"})
    raw = urllib.request.urlopen(req, timeout=900).read().decode()
    return raw

def boundary(turn):
    return {"key": KEY, "turn": turn, "compat": "1", "policy": "auto"}

def chat(msgs, turn, label):
    d = json.loads(post("/v1/chat/completions", {
        "model": "qwen", "stream": False, "temperature": 0, "max_tokens": 32,
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
h = [{"role": "user", "content": A}, {"role": "assistant", "content": a1}]

B = "Name one prime number."
print("turn 2  ToT  <- must REUSE the boundary chat left")
a2 = tot(h + [{"role": "user", "content": B}], 2, "tot")
h2 = h + [{"role": "user", "content": B}, {"role": "assistant", "content": a2}]

C = "And the capital of Italy?"
print("turn 3  chat <- must REUSE the boundary ToT left")
chat(h2 + [{"role": "user", "content": C}], 3, "chat")
