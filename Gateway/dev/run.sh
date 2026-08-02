#!/usr/bin/env bash
# Dev driver for the gateway stack. No Xcode and no code signing required.
#
#   ./Gateway/dev/run.sh build            build gateway + inferlets
#   ./Gateway/dev/run.sh serve [real|dummy]   run gateway (default: real / Qwen2.5-7B)
#   ./Gateway/dev/run.sh chat "prompt"    one chat request against a running gateway
#   ./Gateway/dev/run.sh test             all Rust test suites
#   ./Gateway/dev/run.sh conformance      phase-1 transport gate (needs `serve dummy`)
#   ./Gateway/dev/run.sh reload-test      B1 gate: hot-reload echo (needs `serve`)
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

INFERLET_DIR="${INFERLET_DIR:-$REPO/Gateway/dev/inferlets}"
ADMIN_TOKEN="${RATIO_ADMIN_TOKEN:-dev-reload-token}"

# Stage the same `{name}.wasm` + `{name}.Pie.toml` layout the app bundle uses, so
# dev and production exercise one code path in the gateway instead of two.
stage() {
  mkdir -p "$INFERLET_DIR"
  local i
  for i in "$@"; do
    cp "$REPO/Inferlets/$i/target/wasm32-wasip2/release/$i.wasm" "$INFERLET_DIR/$i.wasm"
    cp "$REPO/Inferlets/$i/Pie.toml" "$INFERLET_DIR/$i.Pie.toml"
  done
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
  stage chat echo
  echo "✅ built → $INFERLET_DIR"
}

cmd_serve() {
  local which_model="${1:-real}"
  local cfg="$REPO/Gateway/dev/pie.$which_model.toml"
  [[ -f "$cfg" ]] || { echo "error: no config $cfg (use real|dummy)" >&2; exit 1; }
  [[ -x "$PIE" ]] || { echo "error: pie engine not found at $PIE" >&2; exit 1; }
  [[ -x "$REPO/Gateway/target/release/ratio-gateway" ]] || cmd_build
  [[ -d "$INFERLET_DIR" ]] || cmd_build
  echo "==> gateway on :$PORT  (model: $which_model)   Ctrl-C to stop"
  exec "$REPO/Gateway/target/release/ratio-gateway" \
    --listen "127.0.0.1:$PORT" \
    --spawn-engine --pie-bin "$PIE" --pie-config "$cfg" \
    --pie-home "${PIE_HOME:-/tmp/ratio-gateway-home}" \
    --inferlet-dir "$INFERLET_DIR" \
    --admin-token "$ADMIN_TOKEN"
}

# B1 exit criterion: change echo's bytes, reload, serve the new version — with
# no gateway restart and no gateway rebuild.
cmd_reload_test() {
  need_cargo
  local base="http://127.0.0.1:$PORT"
  local before after
  digest_of() {
    curl -sf "$base/v1/inferlets" \
      | python3 -c "import sys,json;print([d for d in json.load(sys.stdin)['data'] if d['route']=='$1'][0]['digest'])"
  }

  # Baseline from committed source, so an interrupted earlier run cannot leave a
  # modified wasm staged and make the change-detection assertion vacuous.
  ( cd "$REPO/Inferlets/echo" && cargo build --release --target wasm32-wasip2 ) >/dev/null
  stage echo
  curl -sf -X POST "$base/v1/admin/reload" -H "authorization: Bearer $ADMIN_TOKEN" >/dev/null
  before=$(digest_of echo)
  echo "echo digest before: $before"

  echo "==> unauthenticated reload must be refused"
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$base/v1/admin/reload")
  [[ "$code" == "401" ]] || { echo "❌ expected 401, got $code"; return 1; }
  echo "   ✅ 401"

  echo "==> a broken manifest must not replace the live registry"
  printf 'not [[[ toml' > "$INFERLET_DIR/broken.Pie.toml"
  printf '\0asm' > "$INFERLET_DIR/broken.wasm"
  code=$(curl -s -o /tmp/reload_bad.json -w '%{http_code}' -X POST "$base/v1/admin/reload" \
           -H "authorization: Bearer $ADMIN_TOKEN")
  rm -f "$INFERLET_DIR/broken.Pie.toml" "$INFERLET_DIR/broken.wasm"
  [[ "$code" == "400" ]] || { echo "❌ expected 400, got $code"; return 1; }
  curl -sf "$base/v1/echo" -d '{"count":1}' >/dev/null || { echo "❌ echo died after a rejected reload"; return 1; }
  echo "   ✅ 400, and echo still serves"

  echo "==> unknown route must 404 and say what exists"
  curl -s "$base/v1/inferlet" -d '{"inferlet":"nope"}' | python3 -m json.tool

  # A real source edit, not `touch`: the wasm build is deterministic, so
  # recompiling unchanged source produces identical bytes and an unchanged
  # digest — correct behaviour, but it proves nothing about reload.
  local src="$REPO/Inferlets/echo/src/lib.rs"
  cp "$src" "$src.b1bak"
  # `touch` is required: mv restores the original mtime, which is older than the
  # last build, so cargo would call the edited artifact fresh and skip the rebuild.
  restore() { mv "$src.b1bak" "$src" 2>/dev/null && touch "$src"; true; }
  trap restore RETURN

  echo "==> edit echo to emit a marker, rebuild, reload"
  sed -i '' 's/{{"t":"echo","i":{i}}}/{{"t":"echo","i":{i},"b1":"reloaded"}}/' "$src"
  grep -q '"b1":"reloaded"' "$src" || { echo "❌ sed did not apply"; return 1; }
  ( cd "$REPO/Inferlets/echo" && cargo build --release --target wasm32-wasip2 ) >/dev/null
  stage echo
  curl -sf -X POST "$base/v1/admin/reload" -H "authorization: Bearer $ADMIN_TOKEN" | python3 -m json.tool

  after=$(curl -sf "$base/v1/inferlets" | python3 -c "import sys,json;print([d for d in json.load(sys.stdin)['data'] if d['route']=='echo'][0]['digest'])")
  echo "echo digest after:  $after"
  [[ "$before" != "$after" ]] || { echo "❌ digest unchanged"; return 1; }

  # The load-bearing assertion: the NEW bytes are actually executing. A digest
  # change alone would still pass if the engine kept serving the old program.
  curl -sf "$base/v1/echo" -d '{"count":1}' > /tmp/b1_after.sse
  cat /tmp/b1_after.sse
  grep -q '"b1":"reloaded"' /tmp/b1_after.sse || { echo "❌ old wasm still serving"; return 1; }
  echo "   ✅ new wasm is executing"

  echo "==> revert and reload back"
  restore; trap - RETURN
  ( cd "$REPO/Inferlets/echo" && cargo build --release --target wasm32-wasip2 ) >/dev/null
  stage echo
  curl -sf -X POST "$base/v1/admin/reload" -H "authorization: Bearer $ADMIN_TOKEN" >/dev/null
  curl -sf "$base/v1/echo" -d '{"count":1}' > /tmp/b1_reverted.sse
  grep -q '"b1"' /tmp/b1_reverted.sse && { echo "❌ revert did not take"; return 1; }
  local reverted
  reverted=$(curl -sf "$base/v1/inferlets" | python3 -c "import sys,json;print([d for d in json.load(sys.stdin)['data'] if d['route']=='echo'][0]['digest'])")
  [[ "$reverted" == "$before" ]] || { echo "❌ digest did not return to $before (got $reverted)"; return 1; }
  echo "   ✅ back to $reverted"

  echo "==> chat still serves (reload must not disturb other routes)"
  curl -sf "$base/v1/inferlets" | python3 -c "import sys,json;[print(' ',d['route'],d['digest'],'installed' if d['installed'] else 'lazy') for d in json.load(sys.stdin)['data']]"
  echo "✅ B1 gate passed: reloaded echo with changed bytes, no restart, no gateway rebuild"
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
  echo "==> gen-core (schema/demux/prompt/boundary)"; ( cd "$REPO/Inferlets/gen-core"  && cargo test --lib )
  echo "==> ratio-names";                            ( cd "$REPO/Inferlets/ratio-names" && cargo test )
  # Both feature states: the exec-strategies gate changes which `exec` values
  # `resolve` accepts, and only the OFF build is what ships.
  echo "==> tot-core (tree/diversity/schema)";       ( cd "$REPO/Inferlets/tot-core" && cargo test --lib && cargo test --lib --features exec-strategies )
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
  reload-test) cmd_reload_test ;;
  oracle)      cmd_oracle ;;
  ab)          cmd_ab ;;
  *) sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ; exit 1 ;;
esac
