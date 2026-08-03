#!/usr/bin/env bash
# Dev driver for the gateway stack. No Xcode and no code signing required.
#
#   ./Gateway/dev/run.sh build            build gateway + inferlets
#   ./Gateway/dev/run.sh serve [real|dummy]   run gateway (default: real / Qwen2.5-7B)
#   ./Gateway/dev/run.sh chat "prompt"    one chat request against a running gateway
#   ./Gateway/dev/run.sh tot "prompt"     one tree-of-thought request
#   ./Gateway/dev/run.sh test             all Rust test suites
#   ./Gateway/dev/run.sh conformance      phase-1 transport gate (needs `serve dummy`)
#   ./Gateway/dev/run.sh reload-test      B1 gate: hot-reload echo (needs `serve`)
#   ./Gateway/dev/run.sh crossmode        B2 gate: chat -> ToT -> chat KV reuse
#   ./Gateway/dev/run.sh bon              C gate: chat -> BoN -> pick -> commit -> chat
#   ./Gateway/dev/run.sh view-commit      the view's commit body, end to end
#   ./Gateway/dev/run.sh endpoints        parity: the app's URL vs the gates' URL
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

# DERIVED the same way Scripts/build-gateway.sh derives it, so the dev stack and
# the shipped bundle cannot register different sets. They did: this list read
# `chat echo tot bestofn` while the bundle script read `chat echo`, so every
# gate was green against routes the real app would 404.
inferlets() {
  local m
  for m in "$REPO"/Inferlets/*/Pie.toml; do
    grep -q '^\[ratio\]' "$m" || continue
    basename "$(dirname "$m")"
  done
}

cmd_build() {
  need_cargo
  rustup target list --installed | grep -q wasm32-wasip2 || rustup target add wasm32-wasip2
  local list; list=($(inferlets))
  echo "==> inferlets → wasm: ${list[*]}"
  local i
  for i in "${list[@]}"; do
    ( cd "$REPO/Inferlets/$i" && cargo build --release --target wasm32-wasip2 )
  done
  echo "==> gateway"
  ( cd "$REPO/Gateway" && cargo build --release )
  stage "${list[@]}"
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

# One ToT request, printing the raw tree frames. `-N` so the stream is not
# buffered: the interleaving of sibling node_deltas is the point.
cmd_tot() {
  local prompt="${1:-Name one prime number.}"
  local body
  body=$(python3 -c "
import json,sys
print(json.dumps({'inferlet':'tree-of-thought','input':{
  'model':'qwen','messages':[{'role':'user','content':sys.argv[1]}],
  'breadth':2,'depth':1,'beam_width':1,'max_tokens_per_node':96,'thinking':False,
  'boundary':{'key':'tot-dev-conv','turn':1,'compat':'1'}}}))" "$prompt")
  curl -sN -m 900 "http://127.0.0.1:$PORT/v1/inferlet" \
    -H 'content-type: application/json' -d "$body"
}

# B2 exit gate: chat -> ToT -> chat must reuse KV ACROSS the mode switch.
# Legacy ToT could not do this at all (tot/ has no Context::save|open and no
# prefix_cache reference), so this measures a capability that did not exist.
#
# Asserts on `reused_tokens`, NOT on `open()` succeeding and NOT on
# OpenOutcome.exact:
#   * eviction calls suspend, not delete, so an evicted snapshot still OPENS
#     and silently replays — success there proves nothing;
#   * `exact` is unsatisfiable by construction. The exact name covers the new
#     turn's user message, which nothing has saved yet, so a cross-mode hit is
#     always a ladder rung at cut = len-1. Demanding `exact` would fail 100% of
#     the time even when reuse works perfectly.
cmd_crossmode() {
  local key="${1:-b2-crossmode-$$}"
  local log="${GATEWAY_LOG:-/tmp/tot2.log}"
  local before
  # TOTAL lines, not matching lines — the offset feeds `tail -n +N`.
  before=$(wc -l < "$log" 2>/dev/null || echo 0)
  python3 "$REPO/Gateway/dev/crossmode.py" "$key" || return 1
  echo
  echo "==> reuse across the mode switch"
  # Strip ANSI once, then both display and assertions read the same text — the
  # tracing output is colourized, so a literal grep on the raw log never matches.
  local slice
  slice=$(tail -n +$((before + 1)) "$log" | sed $'s/\033\[[0-9;]*m//g' | grep -E "kv reuse" || true)
  echo "$slice"
  # turn 2 (ToT) must have REUSED, and turn 3 (chat) must have reused MORE than
  # turn 2 did — more means it hit the boundary ToT wrote, not a fallback to
  # the shallower one chat left in turn 1.
  #
  # TODO(kv-residency): this proves the NAMING is right, not that the KV was
  # resident. An evicted boundary opens and replays, producing these exact
  # numbers. The gate also runs on a quiet engine with one short conversation —
  # the regime where eviction never fires — so it has never once exercised the
  # failure it cannot detect. A pressure gate (fill KV, then assert the run
  # still answers correctly and only gets slower) would cover that without
  # needing anything from pie.
  local tot_reused chat_reused
  tot_reused=$(echo "$slice" | grep "tree kv reuse" | tail -1 | grep -oE "reused_tokens=[0-9]+" | cut -d= -f2)
  chat_reused=$(echo "$slice" | grep "chat: kv reuse" | tail -1 | grep -oE "reused_tokens=[0-9]+" | cut -d= -f2)
  [[ -n "$tot_reused" && "$tot_reused" -gt 0 ]] || { echo "❌ ToT did not reuse chat's boundary (entry half)"; return 1; }
  [[ -n "$chat_reused" && "$chat_reused" -gt "$tot_reused" ]] || {
    echo "❌ chat reused ${chat_reused:-none} <= ToT's $tot_reused — it fell back to turn 1's boundary, so ToT's exit save did not land"; return 1; }
  echo "✅ B2 gate passed: ToT reused $tot_reused (entry), chat then reused $chat_reused (exit)"
}

# C exit gate: a full Best-of-N lifecycle, ending in KV reuse across the mode
# switch. Also exercises the destructive path's guards, which are the only
# reason this milestone is riskier than the others.
cmd_bon() {
  local key="${1:-c-gate-$$}"
  local log="${GATEWAY_LOG:-/tmp/bon2.log}"
  local before
  before=$(wc -l < "$log" 2>/dev/null || echo 0)
  python3 "$REPO/Gateway/dev/bon.py" "$key" || return 1
  echo
  echo "==> reuse across the mode switch"
  local slice bon_reused chat_reused
  slice=$(tail -n +$((before + 1)) "$log" | sed $'s/\033\[[0-9;]*m//g' | grep -E "kv reuse" || true)
  echo "$slice"
  # Round 1 must have entered on chat's boundary, and the chat turn after the
  # commit must have reused MORE than that — more means it hit the boundary the
  # COMMIT wrote, not a fallback to the one chat left before the round.
  #
  # TODO(kv-residency): same limit as the crossmode gate — name-level, not
  # residency-level. See gen_core::boundary::OpenOutcome.
  bon_reused=$(echo "$slice" | grep "route=best-of-n" | head -1 | grep -oE "reused_tokens=[0-9]+" | cut -d= -f2)
  chat_reused=$(echo "$slice" | grep "chat: kv reuse" | tail -1 | grep -oE "reused_tokens=[0-9]+" | cut -d= -f2)
  [[ -n "$bon_reused" && "$bon_reused" -gt 0 ]] || { echo "❌ round 1 did not reuse chat's boundary (entry half)"; return 1; }
  [[ -n "$chat_reused" && "$chat_reused" -gt "$bon_reused" ]] || {
    echo "❌ chat reused ${chat_reused:-none} <= round 1's $bon_reused — it fell back to the pre-round boundary, so the commit's save did not land"; return 1; }
  # The think-more hop must WARM-START. A resume that silently falls back to a
  # cold rebuild looks identical from outside the guest, so this is the only
  # place it can be caught — and a scope that is not carried forward does not
  # even reach the cold path, it 400s.
  echo "$slice" | grep -q 'resume="warm" resume_validated=true' || {
    echo "❌ no warm resume: the think-more hop did not carry its round scope, or the pick failed to verify"; return 1; }
  echo "✅ C gate passed: round 1 reused $bon_reused (entry), warm think-more, chat after commit reused $chat_reused (exit)"
}

# The view's commit path, using SWIFT'S OWN BYTES.
#
# `bon-commit-body` runs `ChatSendController.prepareBestOfNCommit` — the code
# path the view runs — and prints the complete dispatch envelope; the gate POSTs
# it verbatim and derives the follow-up turn from the `messages`/`boundary` it
# contains. Python contributes two prompt strings and the URL, nothing more.
#
# The earlier version hand-wrote an equivalent body in Python, so it and the
# encoder were pinned together only by someone having read both — the same
# construct-your-own-input gap that hid a think-more outage and a total
# ToT/Best-of-N outage behind green gates.
cmd_view_commit() {
  local key="${1:-view-commit-$$}"
  local log="${GATEWAY_LOG:-/tmp/view.log}"
  local before
  before=$(wc -l < "$log" 2>/dev/null || echo 0)
  # The body comes from Swift, not from Python, so the emitter must be current.
  command -v swift >/dev/null || { echo "error: swift not on PATH" >&2; return 1; }
  ( cd "$REPO" && swift build --product bon-commit-body ) >/dev/null || {
    echo "❌ could not build bon-commit-body"; return 1; }
  python3 "$REPO/Gateway/dev/view-commit.py" "$key" || return 1
  local slice reused
  slice=$(tail -n +$((before + 1)) "$log" | sed $'s/\033\[[0-9;]*m//g' | grep -E "kv reuse" || true)
  echo "$slice"
  reused=$(echo "$slice" | grep "chat: kv reuse" | tail -1 | grep -oE "reused_tokens=[0-9]+" | cut -d= -f2)
  [[ -n "$reused" && "$reused" -gt 0 ]] || {
    echo "❌ the chat turn after the commit reused nothing — the commit named a boundary it does not ask for"; return 1; }
  echo "✅ view-commit gate passed: the next chat turn reused $reused tokens"
}

# Endpoint parity. Every other gate posts to /v1/inferlet; the app posts
# streaming ToT/Best-of-N — and Best-of-N release — to /v1/chat/completions.
# That divergence hid a total ToT/Best-of-N outage behind four green gates.
cmd_endpoints() {
  python3 "$REPO/Gateway/dev/endpoints.py"
}

cmd_test() {
  need_cargo
  echo "==> ratio-wire (golden + forward-compat)"; ( cd "$REPO/Inferlets/ratio-wire" && cargo test )
  echo "==> gen-core (schema/demux/prompt/boundary)"; ( cd "$REPO/Inferlets/gen-core"  && cargo test --lib )
  echo "==> ratio-names";                            ( cd "$REPO/Inferlets/ratio-names" && cargo test )
  # Both feature states: the exec-strategies gate changes which `exec` values
  # `resolve` accepts, and only the OFF build is what ships.
  echo "==> tot-core (search/tree/diversity/schema/stream)";       ( cd "$REPO/Inferlets/tot-core" && cargo test --lib && cargo test --lib --features exec-strategies )
  echo "==> bestofn-core (round/resume/commit/release)"; ( cd "$REPO/Inferlets/bestofn-core" && cargo test --lib )
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
  tot)         cmd_tot "${2:-}" ;;
  crossmode)   cmd_crossmode "${2:-}" ;;
  bon)         cmd_bon "${2:-}" ;;
  view-commit) cmd_view_commit "${2:-}" ;;
  endpoints)   cmd_endpoints ;;
  test)        cmd_test ;;
  conformance) cmd_conformance ;;
  reload-test) cmd_reload_test ;;
  oracle)      cmd_oracle ;;
  ab)          cmd_ab ;;
  *) sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ; exit 1 ;;
esac
