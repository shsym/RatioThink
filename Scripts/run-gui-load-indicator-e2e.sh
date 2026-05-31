#!/bin/bash
# production path-1 model-load indicator GUI E2E.
#
# Drives RatioThink.app's REAL load path: model menu -> confirm gate ("Switch")
# -> ProfileSwapCoordinator -> ModelLoadCenter.load -> HTTPEngineClient
# .loadModel -> POST /v1/models/load against a mock harness that HOLDS
# the load SSE (no model_loading frame — exactly pie-control v1's shape)
# before model_ready. center.load sets .loading locally, so the toolbar
# lights up deterministically for the hold window. Two scenarios:
#   1. load shows "Loading model …" then clears to "Model loaded:".
#   2. mid-load Cancel (indicator popover → Cancel → center.cancel())
#      clears the indicator and the load does not complete.
# Test-only: no engine, no production code involved. ( relocated the
# indicator into the content ContentToolbar so its popover is reliably
# driveable under XCUITest.)
#
#
# The hold is the deterministic observable window: long enough for
# XCUITest to catch "Loading model" AND complete the slower interaction
# dance (dismiss the Switch popover → open the indicator popover → click
# Cancel to ARM the confirm) before model_ready lands and the popover's
# action swaps Cancel→Unload. 30s gives comfortable margin over the
# worst-case open path (~18s); the per-test "Model loaded:" waits are all
# derived from this hold, not hardcoded. Override with
# PIE_TEST_LOAD_HOLD_SECONDS.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

HOLD_SECONDS="${PIE_TEST_LOAD_HOLD_SECONDS:-30}"
RUN_ROOT="${PIE_TEST_RUN_ROOT:-/tmp/p302-loadviz-$$}"
GUI_HOME="$RUN_ROOT/g"
URL_FILE="$RUN_ROOT/harness.url"
HARNESS_LOG="$RUN_ROOT/loadviz-harness.log"
CONFIG_FILE="/tmp/pie-gui-load-indicator-e2e.env"
HARNESS_PID=""

cleanup() {
  rm -f "$CONFIG_FILE"
  if [ -n "$HARNESS_PID" ] && kill -0 "$HARNESS_PID" >/dev/null 2>&1; then
    kill "$HARNESS_PID" >/dev/null 2>&1 || true
    wait "$HARNESS_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if ! pgrep -x Dock >/dev/null 2>&1; then
  echo "gui load-indicator e2e: no seated GUI session detected (Dock not running)" >&2
  exit 2
fi
if [ "${PIE_TEST_TCC_GRANTED:-}" != "1" ]; then
  echo "gui load-indicator e2e: RatioThink.app Automation/Accessibility permissions required." >&2
  echo "gui load-indicator e2e: grant Xcode/XCTest runner and RatioThink.app Automation + Accessibility in System Settings, then rerun:" >&2
  echo "gui load-indicator e2e: PIE_TEST_TCC_GRANTED=1 Scripts/run-gui-load-indicator-e2e.sh" >&2
  exit 2
fi

mkdir -p "$GUI_HOME" "$RUN_ROOT"
rm -f "$URL_FILE" "$CONFIG_FILE"

echo "gui load-indicator e2e: starting path-1 load harness (hold=${HOLD_SECONDS}s)"
python3 Scripts/loadviz-harness.py \
  --port-file "$URL_FILE" \
  --hold-seconds "$HOLD_SECONDS" \
  >"$HARNESS_LOG" 2>&1 &
HARNESS_PID=$!

for _ in $(seq 1 30); do
  if [ -s "$URL_FILE" ]; then
    break
  fi
  if ! kill -0 "$HARNESS_PID" >/dev/null 2>&1; then
    echo "gui load-indicator e2e: harness exited before publishing URL" >&2
    cat "$HARNESS_LOG" >&2 || true
    exit 1
  fi
  sleep 1
done

if [ ! -s "$URL_FILE" ]; then
  echo "gui load-indicator e2e: timed out waiting for harness URL" >&2
  cat "$HARNESS_LOG" >&2 || true
  exit 1
fi

BASE_URL="$(cat "$URL_FILE")"
cat >"$CONFIG_FILE" <<EOF
PIE_TEST_ENGINE_BASE_URL=$BASE_URL
PIE_TEST_GUI_HOME=$GUI_HOME
PIE_TEST_LOAD_HOLD_SECONDS=$HOLD_SECONDS
EOF

echo "gui load-indicator e2e: generating Xcode project"
Scripts/genproject.sh

echo "gui load-indicator e2e: engine=$BASE_URL"
echo "gui load-indicator e2e: gui PIE_HOME=$GUI_HOME"
echo "gui load-indicator e2e: retained run root: $RUN_ROOT"
echo "gui load-indicator e2e: running XCUITest"

xcodebuild -project RatioThink.xcodeproj \
  -scheme RatioThinkGUITests \
  -destination 'platform=macOS,arch=arm64' \
  -parallel-testing-enabled NO \
  test \
  -only-testing:RatioThinkGUITests/S302_ModelLoadIndicatorPath1GUITests \
  ENABLE_CODE_COVERAGE=NO

echo "gui load-indicator e2e: PASS"
