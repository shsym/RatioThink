#!/bin/bash
# Live validation for #448 (Structured Quit). Two acceptance checks the
# unit/scenario tests cannot cover because they need the real signed,
# launchd-registered App + Helper + a running pie engine:
#
#   1. Idle persistence — a backgrounded engine STAYS ALIVE. The
#      startEngine reply-timeout fallback used to stop a healthy engine
#      exactly 60s after every App-driven start (the "engine dies after ~1
#      min idle" report); this proves a started engine survives well past
#      that window with no user interaction.
#
#   2. Full-product quit — `ratiothink://quit` (the same coordinated path
#      ⌘Q and the menu-bar "Quit Rational" take) leaves NO App, Helper, or
#      pie process behind, and the cleanly-exited Helper is NOT respawned.
#
# Crash recovery (unclean Helper death -> launchd relaunch) is covered by
# Scripts/verify-helper-respawn.sh and is intentionally NOT re-tested here.
#
# This path needs a code-signed, registered build with a model loaded, so it
# guides instead of failing blindly when prerequisites are missing
# (mirrors verify-helper-respawn.sh).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_GLOB="Rational.app/Contents/MacOS/Rational"
HELPER_GLOB="LoginItems/RationalHelper.app/Contents/MacOS/RationalHelper"
# pie is spawned as `pie serve --config <toml> ...` by the Helper.
PIE_GLOB="pie serve"

IDLE_S="${PIE_QUIT_IDLE_S:-75}"      # > the old 60s startEngine kill window
QUIT_DEADLINE_S="${PIE_QUIT_DEADLINE_S:-20}"

fail() { echo "FAIL: $*" >&2; exit 1; }
app_pid()    { pgrep -f "$APP_GLOB" | head -1 || true; }
helper_pid() { pgrep -f "$HELPER_GLOB" | head -1 || true; }
engine_pid() { pgrep -f "$PIE_GLOB" | head -1 || true; }

guide_if_missing() {
  local missing=0
  [ -z "$(app_pid)" ]    && { echo "  · Rational.app is not running" >&2; missing=1; }
  [ -z "$(helper_pid)" ] && { echo "  · RationalHelper is not running" >&2; missing=1; }
  [ -z "$(engine_pid)" ] && { echo "  · no 'pie serve' engine is running (load a model in the App)" >&2; missing=1; }
  if [ "$missing" -eq 1 ]; then
    cat >&2 <<EOF

Prerequisites missing. This live check needs the signed, registered build
with the engine running:
  1. Build + install signed (see Scripts/verify-helper-respawn.sh header).
  2. Launch /Applications/Rational.app, finish first-launch, and START the
     engine (load the default model) so 'pie serve' is running.
  3. Re-run this script.
EOF
    exit 2
  fi
}

guide_if_missing
echo "OK: App ($(app_pid)), Helper ($(helper_pid)), engine ($(engine_pid)) all running"

# ── Test 1: idle persistence ────────────────────────────────────────────
echo ""
echo "=== Test 1: engine stays alive across ${IDLE_S}s idle (#448 idle-death fix) ==="
before="$(engine_pid)"
[ -n "$before" ] || fail "no engine to observe"
echo "  engine pid before idle: $before — waiting ${IDLE_S}s with no interaction…"
sleep "$IDLE_S"
after="$(engine_pid)"
if [ -z "$after" ]; then
  fail "engine DIED during ${IDLE_S}s idle (pid $before -> gone) — idle-death regression"
fi
if [ "$before" != "$after" ]; then
  fail "engine was RESTARTED during ${IDLE_S}s idle (pid $before -> $after) — something is bouncing it"
fi
echo "PASS: engine pid $after unchanged after ${IDLE_S}s idle — background keeps the engine alive."

# ── Test 2: full-product quit leaves nothing ────────────────────────────
echo ""
echo "=== Test 2: ratiothink://quit tears down App + Helper + engine ==="
echo "  delivering ratiothink://quit (the coordinated full-quit path)…"
open "ratiothink://quit"

deadline=$(( $(date +%s) + QUIT_DEADLINE_S ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  if [ -z "$(app_pid)" ] && [ -z "$(helper_pid)" ] && [ -z "$(engine_pid)" ]; then
    break
  fi
  sleep 0.5
done

leftover=""
[ -n "$(app_pid)" ]    && leftover="$leftover App($(app_pid))"
[ -n "$(helper_pid)" ] && leftover="$leftover Helper($(helper_pid))"
[ -n "$(engine_pid)" ] && leftover="$leftover engine($(engine_pid))"
[ -z "$leftover" ] || fail "after ${QUIT_DEADLINE_S}s, unintended processes remain:$leftover"
echo "  no App / Helper / engine process remains."

# A clean Helper exit must NOT be respawned on-demand (nothing polls it now).
sleep 3
respawn=""
[ -n "$(helper_pid)" ] && respawn="$respawn Helper($(helper_pid))"
[ -n "$(engine_pid)" ] && respawn="$respawn engine($(engine_pid))"
[ -z "$respawn" ] || fail "a process respawned 3s after full quit:$respawn (relaunch loop not suppressed)"
echo "PASS: full quit left nothing running and nothing respawned."

echo ""
echo "PASS (#448): backgrounded engine persists across idle; ratiothink://quit"
echo "leaves no App/Helper/pie process and triggers no relaunch. (Crash recovery:"
echo "see Scripts/verify-helper-respawn.sh.)"
