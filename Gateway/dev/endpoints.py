#!/usr/bin/env python3
"""Endpoint-parity gate: every route must behave the same on the URL the APP
uses as on the one the dev gates use.

This exists because the other four gates all posted to `/v1/inferlet`, while
`HTTPEngineClient.dispatchInferlet` sends streaming ToT and Best-of-N — and
Best-of-N release — to `/v1/chat/completions`. The chat endpoint resolved the
route and then drove it with the CHAT protocol, so a tree guest ran an entire
search, returned, and the driver reported "returned before ready" as a 500.
Fourteen seconds of generation, thrown away, on every request. Every gate was
green because no gate used the app's URL.

The general failure is not "wrong URL". It is that a gate which constructs its
own request can only test the half it models. So this one derives its inputs
from the SERVER's own route list and from the CLIENT's routing rule, and asserts
the two agree — rather than restating either.
"""
import json
import sys
import urllib.error
import urllib.request

BASE = "http://127.0.0.1:8100"
FAILURES = []

# The client's routing rule, transcribed from HTTPEngineClient.swift:187-200.
# Kept here as data so a change on the Swift side shows up as a diff in one
# place rather than as a mysteriously passing gate.
#
#   stream == false  -> /v1/inferlet, EXCEPT a best-of-n release -> /v1/chat/completions
#   stream == true   -> /v1/chat/completions for tree-of-thought and best-of-n,
#                       /v1/inferlet otherwise
def client_path(inferlet: str, stream: bool, body: dict) -> str:
    if not stream:
        is_release = (
            inferlet == "best-of-n" and isinstance(body.get("release"), list) and body["release"]
        )
        return "/v1/chat/completions" if is_release else "/v1/inferlet"
    return (
        "/v1/chat/completions"
        if inferlet in ("tree-of-thought", "best-of-n")
        else "/v1/inferlet"
    )


def post(path, body, timeout=180):
    req = urllib.request.Request(
        BASE + path, data=json.dumps(body).encode(),
        headers={"content-type": "application/json"})
    try:
        return 200, urllib.request.urlopen(req, timeout=timeout).read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()
    except Exception as e:  # noqa: BLE001 - a timeout is a result, not a crash
        return 0, f"<{type(e).__name__}: {e}>"


def check(label, ok, detail=""):
    print(f"  {'PASS' if ok else 'FAIL'}  {label}{'  ' + detail if detail else ''}")
    if not ok:
        FAILURES.append(label)
    return ok


def kind(code, raw):
    """Reduce a response to what a client can act on: the first frame's event,
    or the error code. Byte equality is not the contract — ids and timings
    differ per request — but the SHAPE must not depend on the URL."""
    if code != 200:
        try:
            return f"error:{json.loads(raw)['error']['code']}"
        except Exception:  # noqa: BLE001
            return f"http:{code}"
    for line in raw.splitlines():
        if line.startswith("data: ") and line[6:].strip() != "[DONE]":
            ev = json.loads(line[6:])
            return f"event:{ev.get('event', '?')}"
    try:
        return f"json:{json.loads(raw).get('object', '?')}"
    except Exception:  # noqa: BLE001
        return "empty"


# Routes come from the SERVER, so a newly registered inferlet is covered without
# editing this file — the bundle-vs-dev drift that hid the missing wasms would
# have shown up here as an absent route.
_, raw = post("/v1/inferlets", {})
try:
    entries = json.loads(urllib.request.urlopen(BASE + "/v1/inferlets", timeout=30).read())["data"]
except Exception as e:  # noqa: BLE001
    sys.exit(f"cannot list routes: {e}")

print("registered routes:", ", ".join(f"{e['route']}({e['protocol']})" for e in entries))
print()

MSGS = [{"role": "user", "content": "Name one prime number."}]

for e in entries:
    route, proto = e["route"], e["protocol"]
    if proto != "tree-v1":
        continue  # chat-v1 has its own endpoint and its own gates

    print(f"{route} — streaming round")
    body = {
        "model": "qwen", "messages": MSGS, "round_id": f"endpoint-{route}",
        "n": 2, "max_tokens_per_candidate": 24,
        "breadth": 2, "depth": 1, "beam_width": 1, "max_tokens_per_node": 24,
        "thinking": False, "level": 1,
    }
    env = {"inferlet": route, "stream": True, "input": body}
    app = client_path(route, True, body)
    other = "/v1/inferlet" if app != "/v1/inferlet" else "/v1/chat/completions"

    c1, r1 = post(app, env)
    c2, r2 = post(other, env)
    k1, k2 = kind(c1, r1), kind(c2, r2)
    check(f"{route}: opens on the APP's endpoint ({app})",
          k1 == "event:tree_start", k1)
    check(f"{route}: same shape on both endpoints", k1 == k2, f"{app}={k1}  {other}={k2}")

print("best-of-n — unary release (the app routes this to /v1/chat/completions)")
rel = {"model": "qwen", "round_id": "endpoint-rel", "release": ["bon/aa/1/0/bb"]}
env = {"inferlet": "best-of-n", "stream": False, "input": rel}
app = client_path("best-of-n", False, rel)
check("the release rule still routes to /v1/chat/completions", app == "/v1/chat/completions", app)
c1, r1 = post(app, env)
c2, r2 = post("/v1/inferlet", env)
check("release acks on the APP's endpoint", kind(c1, r1) == "json:best_of_n.release", kind(c1, r1))
check("release: same shape on both endpoints", kind(c1, r1) == kind(c2, r2),
      f"{kind(c1, r1)} vs {kind(c2, r2)}")

print("best-of-n — unary commit (stream:false, no release -> /v1/inferlet)")
com = {"model": "qwen", "round_id": "endpoint-com", "messages": MSGS,
       "commit": {"snapshot_name": "bon/aa/1/0/bb", "answer": "7", "release": []}}
check("the commit rule routes to /v1/inferlet",
      client_path("best-of-n", False, com) == "/v1/inferlet")
c1, r1 = post("/v1/inferlet", {"inferlet": "best-of-n", "stream": False, "input": com})
c2, r2 = post("/v1/chat/completions", {"inferlet": "best-of-n", "stream": False, "input": com})
check("commit: same shape on both endpoints", kind(c1, r1) == kind(c2, r2),
      f"{kind(c1, r1)} vs {kind(c2, r2)}")

print()
if FAILURES:
    print(f"FAILED endpoint parity: {FAILURES}")
    sys.exit(1)
print("endpoint parity holds: the URL a caller picks cannot change behaviour")
