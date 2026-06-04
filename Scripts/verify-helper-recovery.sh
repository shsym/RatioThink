#!/bin/bash
# Live validation for #412 — App-side background-helper recovery.
#
# What #320 covered (verify-helper-respawn.sh): launchd's OWN recovery —
# KeepAlive respawn on unclean death + on-demand relaunch on App reconnect.
#
# What #412 adds, and this script exercises: when the helper becomes
# unreachable in a way launchd does NOT self-heal (a stale/lost launchd job,
# e.g. after an in-place bundle replacement), the running App must detect the
# sustained unreachability and RE-REGISTER the job at RUNTIME (the
# HelperHealthController restart ladder → HelperRegistrationRepair →
# unregister()+register()) — instead of requiring a full app restart.
#
# This cannot run on unsigned CI (SMAppService refuses an unsigned agent), and
# the user-facing half (toolbar pip ring white→amber→green, and the
# "Background helper isn't responding" escalation banner) is SwiftUI a shell
# can't observe — so this script does the deterministic launchd-side check and
# GUIDES the operator through the visual half rather than failing blindly.
#
# Pure RatioThinkCore coverage of the ladder/reducer/classifier lives in the
# always-on unit tests (HelperHealthReducerTests, HelperHealthControllerTests,
# HelperEngineIndicatorTests, EngineDeathRecoveryTests, HelperUnreachableBannerTests).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

UID_NUM="$(id -u)"
LABEL="com.ratiothink.app.helper"
SERVICE="com.ratiothink.helper"
HELPER_GLOB="LoginItems/RatioThinkHelper.app/Contents/MacOS/RatioThinkHelper"
APP_GLOB="RatioThink.app/Contents/MacOS/RatioThink"
# The App ladder waits ~12 failed polls (~12s, > launchd's ~10s throttle)
# before the FIRST runtime repair, then a reconcile probe (~5s). Give the full
# first attempt plus margin.
RECOVER_DEADLINE_S="${PIE_RECOVER_DEADLINE_S:-40}"

fail() { echo "FAIL: $*" >&2; exit 1; }

guide_if_unregistered() {
  if ! launchctl print "gui/$UID_NUM/$LABEL" >/dev/null 2>&1; then
    cat >&2 <<EOF
Helper agent '$LABEL' is not registered with launchd.

Set up the signed, registered build first (see verify-helper-respawn.sh for
the full signing recipe), then launch /Applications/RatioThink.app and
complete the first-launch wizard so SMAppService.agent registers the plist.
Re-run this script with RatioThink.app running.
EOF
    exit 2
  fi
}

assert_service_owned() {
  launchctl print "gui/$UID_NUM/$LABEL" 2>/dev/null \
    | grep -A1 "endpoints" | grep -q "$SERVICE" \
    || fail "launchd job '$LABEL' does not declare endpoint '$SERVICE'"
}

guide_if_unregistered
assert_service_owned
echo "OK: baseline — launchd owns '$SERVICE' under agent '$LABEL'"

if ! pgrep -f "$APP_GLOB" >/dev/null 2>&1; then
  cat >&2 <<EOF

SKIP: RatioThink.app is not running. The #412 runtime recovery is driven BY
the running App (it polls the helper, detects sustained unreachability, and
re-registers the launchd job). Launch /Applications/RatioThink.app and re-run.
EOF
  echo "PARTIAL: baseline launchd ownership verified; runtime-recovery NOT exercised (App not running)."
  exit 3
fi

echo ""
echo "=== runtime recovery: App re-registers a lost launchd job (#412 GAP B) ==="
echo "Simulating a stale/lost registration launchd won't self-heal: bootout the"
echo "helper job + kill the process. The RUNNING App must re-register it within"
echo "~${RECOVER_DEADLINE_S}s via its restart ladder (no app restart)."
echo ""
echo ">>> WATCH THE APP WHILE THIS RUNS:"
echo "    · toolbar pip: the OUTER ring should blink white (reconnecting) then"
echo "      amber (repairing); the inner engine dot dims while repairing."
echo "    · if recovery succeeds the ring goes quiet + the engine dot returns"
echo "      to green; if the ladder exhausts you'll see the red ring + the"
echo "      'Background helper isn't responding' banner with Restart Helper /"
echo "      Open Login Items / Collect Diagnostics."
echo ""

# Tear the job down so launchd's own KeepAlive/on-demand path cannot mask the
# App-side repair: bootout removes the loaded job entirely.
launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
pkill -9 -f "$HELPER_GLOB" 2>/dev/null || true
echo "  booted out '$LABEL' + killed helper; the launchd job is now gone."

# Confirm it is actually gone (else the test proves nothing).
if launchctl print "gui/$UID_NUM/$LABEL" >/dev/null 2>&1; then
  echo "  NOTE: launchd still lists '$LABEL' immediately after bootout (it may"
  echo "        re-bootstrap on the App's next connect). Proceeding to watch for"
  echo "        a live helper either way."
fi

start="$(date +%s.%N)"
recovered=0
deadline_iters=$(printf '%.0f' "$(echo "$RECOVER_DEADLINE_S / 0.5" | bc -l)")
for _ in $(seq 1 "$deadline_iters"); do
  sleep 0.5
  # Recovery = the launchd job is back AND a helper process is live AND it
  # answers (a live process under the owned service endpoint).
  if launchctl print "gui/$UID_NUM/$LABEL" >/dev/null 2>&1 \
     && pgrep -f "$HELPER_GLOB" >/dev/null 2>&1; then
    recovered=1
    break
  fi
done
elapsed="$(echo "$(date +%s.%N) - $start" | bc)"

if [ "$recovered" -eq 1 ]; then
  assert_service_owned
  printf "PASS: App re-registered '%s' + helper is live again in %.1fs (<= %ss) — runtime recovery works WITHOUT an app restart.\n" \
    "$SERVICE" "$elapsed" "$RECOVER_DEADLINE_S"
  echo "      (Confirm the toolbar pip returned to a quiet ring + green engine dot.)"
else
  cat >&2 <<EOF
FAIL: '$LABEL' did not come back within ${RECOVER_DEADLINE_S}s.
Expected the running App's HelperHealthController ladder to fire
HelperRegistrationRepair (unregister()+register()) and re-bootstrap the job.
Check app.log for 'helper.health' / 'helper.runtime_repair' breadcrumbs.
If the escalation banner appeared instead, the ladder exhausted — try its
'Restart Helper' button (that path is the manual half of the same repair).
EOF
  exit 1
fi
