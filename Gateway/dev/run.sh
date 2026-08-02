#!/usr/bin/env bash
# Dev driver for the gateway stack. No Xcode and no code signing required.
#
#   ./Gateway/dev/run.sh build            build gateway + inferlets
#   ./Gateway/dev/run.sh serve [real|dummy]   run gateway (default: real / Qwen2.5-7B)
#   ./Gateway/dev/run.sh chat "prompt"    one chat request against a running gateway
#   ./Gateway/dev/run.sh test             all Rust test suites
#   ./Gateway/dev/run.sh conformance      phase-1 transport gate (needs `serve dummy`)
#   ./Gateway/dev/run.sh ab               A/B vs the chat-apc oracle (needs both up)
#   ./Gateway/dev/run.sh oracle           start chat-apc on :8081 for the A/B
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUTER="$(cd "$REPO/.." && pwd)"          # …/ratiothink
PIE="$OUTER/engine/pie"                   # engine extracted from the release DMG
PORT="${PORT:-8100}"
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:$PATH"

need_cargo() {
  command -v cargo >/dev/null || { echo "error: cargo not on PATH (~/.cargo/bin)" >&2; exit 1; }
}

cmd_build() {
  need_cargo
  rustup target list --installed | grep -q wasm32-wasip2 || rustup target add wasm32-wasip2
  echo "==> inferlets → wasm"
  for i in chat echo; do
    ( cd "$REPO/Inferlets/$i" && cargo build --release --target wasm32-wasip2 )
  done
  echo "==> gateway"
  ( cd "$REPO/Gateway" && cargo build --release )
  echo "✅ built"
}

cmd_serve() {
  local which_model="${1:-real}"
  local cfg="$REPO/Gateway/dev/pie.$which_model.toml"
  [[ -f "$cfg" ]] || { echo "error: no config $cfg (use real|dummy)" >&2; exit 1; }
  [[ -x "$PIE" ]] || { echo "error: pie engine not found at $PIE" >&2; exit 1; }
  [[ -x "$REPO/Gateway/target/release/ratio-gateway" ]] || cmd_build
  echo "==> gateway on :$PORT  (model: $which_model)   Ctrl-C to stop"
  exec "$REPO/Gateway/target/release/ratio-gateway" \
    --listen "127.0.0.1:$PORT" \
    --spawn-engine --pie-bin "$PIE" --pie-config "$cfg" \
    --pie-home "${PIE_HOME:-/tmp/ratio-gateway-home}" \
    --inferlet-wasm "$REPO/Inferlets/echo/target/wasm32-wasip2/release/echo.wasm" \
    --inferlet-manifest "$REPO/Inferlets/echo/Pie.toml" \
    --chat-wasm "$REPO/Inferlets/chat/target/wasm32-wasip2/release/chat.wasm" \
    --chat-manifest "$REPO/Inferlets/chat/Pie.toml"
}

cmd_chat() {
  local prompt="${1:-The capital of France is}"
  local body
  body=$(python3 -c "import json,sys;print(json.dumps({'model':'qwen','stream':True,'temperature':0,'max_tokens':64,'messages':[{'role':'user','content':sys.argv[1]}]}))" "$prompt")
  curl -sN -m 300 "http://127.0.0.1:$PORT/v1/chat/completions" \
    -H 'content-type: application/json' -d "$body" \
  | python3 -c "
import sys,json
for l in sys.stdin:
    if not l.startswith('data: '): continue
    p=l[6:].strip()
    if p=='[DONE]': print(); break
    d=json.loads(p)
    if d.get('choices'):
        c=(d['choices'][0].get('delta') or {}).get('content')
        if c: print(c,end='',flush=True)
"
}

cmd_test() {
  need_cargo
  echo "==> ratio-wire (golden + forward-compat)"; ( cd "$REPO/Inferlets/ratio-wire" && cargo test )
  echo "==> gen-core (schema/demux/prompt)";        ( cd "$REPO/Inferlets/gen-core"  && cargo test --lib )
  echo "==> gateway";                                ( cd "$REPO/Gateway"             && cargo test )
}

cmd_conformance() {
  # Needs an engine; easiest is `serve dummy` in another shell, then reuse its engine.
  local log="${PIE_LOG:-/tmp/ratio-gateway-home/logs/pie.log}"
  echo "Point this at a running engine's ws:// address and internal token."
  echo "Simplest: start pie directly, then run:"
  echo "  $REPO/Gateway/target/release/pie-conformance \\"
  echo "     --url ws://127.0.0.1:PORT --token TOKEN \\"
  echo "     --wasm $REPO/Inferlets/echo/target/wasm32-wasip2/release/echo.wasm \\"
  echo "     --manifest $REPO/Inferlets/echo/Pie.toml --iterations 5000 --concurrency 8"
  echo "(log hint: $log)"
}

cmd_oracle() {
  echo "==> chat-apc oracle on :8081"
  exec "$OUTER/.venv/bin/python" "$OUTER/serve.py"
}

cmd_ab() {
  local prompts=("Say hi" "The capital of France is" "Name three prime numbers." "What is 2+2?")
  local pass=0 fail=0
  kinds() { grep '^data:' "$1" | sed 's/^data: //' | python3 -c "
import sys,json
k=[]
for l in sys.stdin:
    l=l.strip()
    if l=='[DONE]': k.append('DONE'); continue
    d=json.loads(l)
    if 'event' in d: k.append(d['event'])
    else:
        ch=d['choices'][0] if d['choices'] else None
        k.append('finish' if ch and ch.get('finish_reason') else ('role' if ch and (ch.get('delta') or {}).get('role') else 'delta'))
print(' '.join(dict.fromkeys(k)))"; }
  content() { grep '^data: {' "$1" | sed 's/^data: //' | python3 -c "
import sys,json
o=[]
for l in sys.stdin:
    d=json.loads(l)
    if d.get('choices'):
        c=(d['choices'][0].get('delta') or {}).get('content')
        if c: o.append(c)
print(''.join(o))"; }
  for p in "${prompts[@]}"; do
    local body; body=$(python3 -c "import json,sys;print(json.dumps({'model':'qwen','stream':True,'temperature':0,'top_p':1,'max_tokens':24,'messages':[{'role':'user','content':sys.argv[1]}]}))" "$p")
    curl -sN -m 300 http://127.0.0.1:8081/v1/chat/completions -H 'content-type: application/json' -d "$body" > /tmp/ab_a.sse
    curl -sN -m 300 "http://127.0.0.1:$PORT/v1/chat/completions" -H 'content-type: application/json' -d "$body" > /tmp/ab_b.sse
    if [[ "$(content /tmp/ab_a.sse)" == "$(content /tmp/ab_b.sse)" && "$(kinds /tmp/ab_a.sse)" == "$(kinds /tmp/ab_b.sse)" ]]; then
      pass=$((pass+1)); echo "  ✅ $p"
    else
      fail=$((fail+1)); echo "  ❌ $p"
      echo "     apc: $(content /tmp/ab_a.sse)"; echo "     new: $(content /tmp/ab_b.sse)"
      echo "     apc frames: $(kinds /tmp/ab_a.sse)"; echo "     new frames: $(kinds /tmp/ab_b.sse)"
    fi
  done
  echo "A/B: $pass passed, $fail failed"
  [[ $fail -eq 0 ]]
}

case "${1:-}" in
  build)       cmd_build ;;
  serve)       cmd_serve "${2:-real}" ;;
  chat)        cmd_chat "${2:-}" ;;
  test)        cmd_test ;;
  conformance) cmd_conformance ;;
  oracle)      cmd_oracle ;;
  ab)          cmd_ab ;;
  *) sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ; exit 1 ;;
esac
