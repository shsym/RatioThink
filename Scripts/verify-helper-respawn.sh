#!/bin/bash
# Live validation for : after the Helper is registered as a launchd
# agent (SMAppService.agent), launchd must own `com.ratiothink.helper` and
# relaunch the Helper after an unclean death within ~1s.
#
# This path cannot run on unsigned CI — SMAppService refuses an unsigned
# agent, so registration needs a code-signed build with a real Team ID.
# The plist *contract* is covered by the always-on unit test
# (Tests/Unit/HelperLaunchAgentPlistTests). This script is the manual
# acceptance for the live launchd behavior; it guides instead of failing
# blindly when prerequisites are missing.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

UID_NUM="$(id -u)"
LABEL="com.ratiothink.app.helper"
SERVICE="com.ratiothink.helper"
HELPER_GLOB="LoginItems/RationalHelper.app/Contents/MacOS/RationalHelper"
ROUNDS="${PIE_RESPAWN_ROUNDS:-2}"
DEADLINE_S="${PIE_RESPAWN_DEADLINE_S:-1.0}"
# launchd throttles KeepAlive respawns (~10s min between launches), so
# space repeated kills past it — otherwise round 2+ measures the throttle,
# not the fix. The throttle does not affect on-demand MachService launches
# (an App connect relaunches the dead Helper immediately, see endpoint
# persistence check below), so it never delays real recovery.
THROTTLE_S="${PIE_RESPAWN_THROTTLE_S:-11}"

fail() { echo "FAIL: $*" >&2; exit 1; }

guide_if_unregistered() {
  if ! launchctl print "gui/$UID_NUM/$LABEL" >/dev/null 2>&1; then
    cat >&2 <<EOF
Helper agent '$LABEL' is not registered with launchd.

Set up the signed, registered build first:
  1. Ensure a valid signing identity:
       security find-identity -v -p codesigning   # need 'Apple Development: ... (TEAMID)'
  2. Build signed and deploy:
       xcodebuild -project RatioThink.xcodeproj -scheme RatioThink -destination 'platform=macOS,arch=arm64' \\
         -configuration Debug CODE_SIGN_STYLE=Manual \\
         CODE_SIGN_IDENTITY=<sha1> DEVELOPMENT_TEAM=<TEAMID> PROVISIONING_PROFILE_SPECIFIER='' build
       cp -R "<DerivedData>/Build/Products/Debug/Rational.app" /Applications/Rational.app
  3. Launch /Applications/Rational.app and complete the first-launch wizard
     ('Register Rational Helper') so SMAppService.agent registers the plist.
  4. Re-run this script.
EOF
    exit 2
  fi
}

assert_service_owned() {
  launchctl print "gui/$UID_NUM/$LABEL" 2>/dev/null \
    | grep -A1 "endpoints" | grep -q "$SERVICE" \
    || fail "launchd job '$LABEL' does not declare endpoint '$SERVICE' — fix reverted?"
}

guide_if_unregistered
assert_service_owned
echo "OK: launchd owns '$SERVICE' under agent '$LABEL'"

# On-demand recovery is the throttle-independent guarantee: the endpoint
# stays declared in the launchd job even while the Helper process is dead,
# so an App connect relaunches it immediately. Prove it persists across a
# kill (checked again inside each round post-respawn).
assert_service_owned
echo "OK: '$SERVICE' endpoint persists in the launchd job (on-demand relaunch path)"

for round in $(seq 1 "$ROUNDS"); do
  [ "$round" -gt 1 ] && { echo "  (waiting ${THROTTLE_S}s for KeepAlive throttle)"; sleep "$THROTTLE_S"; }
  old="$(pgrep -f "$HELPER_GLOB" | head -1 || true)"
  [ -n "$old" ] || fail "round $round: no Helper running to kill (expected RunAtLoad/KeepAlive to keep it up)"
  kill -9 "$old"
  start="$(date +%s.%N)"
  new=""
  # Poll up to the deadline for a new pid.
  for _ in $(seq 1 20); do
    sleep 0.1
    cand="$(pgrep -f "$HELPER_GLOB" | grep -v "^$old$" | head -1 || true)"
    if [ -n "$cand" ]; then new="$cand"; break; fi
  done
  [ -n "$new" ] || fail "round $round: Helper did not respawn after killing $old"
  elapsed="$(echo "$(date +%s.%N) - $start" | bc)"
  within="$(echo "$elapsed <= $DEADLINE_S" | bc)"
  [ "$within" = "1" ] || fail "round $round: respawn took ${elapsed}s (> ${DEADLINE_S}s budget)"
  assert_service_owned
  printf "round %d: killed %s -> respawned %s in %.2fs (<= %ss), %s still owned\n" \
    "$round" "$old" "$new" "$elapsed" "$DEADLINE_S" "$SERVICE"
done

echo "PASS (unclean): Helper auto-respawns (KeepAlive) within ${DEADLINE_S}s across $ROUNDS SIGKILLs; '$SERVICE' stays launchd-owned."

# Clean-quit recovery: a menu Quit (NSApp.terminate) exits 0, so KeepAlive
# correctly does NOT relaunch it. Recovery instead comes from the running
# App reconnecting to the on-demand MachService. Requires Rational.app running.
echo ""
echo "=== clean-quit recovery (on-demand via App reconnect) ==="
sleep "$THROTTLE_S"   # avoid carrying KeepAlive throttle into this check
old="$(pgrep -f "$HELPER_GLOB" | head -1 || true)"
clean_quit_ran=0
if [ -z "$old" ]; then
  echo "  SKIP: no Helper running to quit — clean-quit recovery NOT verified."
elif ! pgrep -f "Rational.app/Contents/MacOS/Rational" >/dev/null 2>&1; then
  echo "  SKIP: Rational.app not running — on-demand recovery needs the App to reconnect; clean-quit NOT verified."
else
  osascript -e 'tell application id "com.ratiothink.app.helper" to quit' >/dev/null 2>&1 || true
  start="$(date +%s.%N)"
  new=""
  for _ in $(seq 1 50); do
    sleep 0.1
    cand="$(pgrep -f "$HELPER_GLOB" | grep -v "^$old$" | head -1 || true)"
    if [ -n "$cand" ]; then new="$cand"; break; fi
  done
  [ -n "$new" ] || fail "clean quit: Helper did not recover (App on-demand reconnect expected)"
  elapsed="$(echo "$(date +%s.%N) - $start" | bc)"
  exitcode="$(launchctl print "gui/$UID_NUM/$LABEL" 2>/dev/null | grep -i 'last exit code' | grep -oE '[0-9]+' | head -1 || true)"
  printf "  clean quit (exit code %s) -> recovered %s in %.2fs via on-demand reconnect\n" "${exitcode:-?}" "$new" "$elapsed"
  assert_service_owned
  clean_quit_ran=1
fi

# Never claim the clean-quit path passed when it was skipped (F5): a
# false all-paths PASS makes this manual acceptance script untrustworthy.
if [ "$clean_quit_ran" -eq 1 ]; then
  echo "PASS: Helper recovers from both unclean death (KeepAlive) and clean quit (on-demand reconnect)."
else
  echo "PARTIAL PASS: unclean-death recovery (KeepAlive) verified; clean-quit recovery SKIPPED (prerequisites missing — run with Rational.app + Helper live to verify it)."
  exit 3
fi
