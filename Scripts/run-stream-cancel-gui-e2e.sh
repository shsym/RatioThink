#!/bin/bash
# #381 part 1: cancel an in-flight chat stream and assert the partial bubble
# survives + the composer recovers. Drives Rational.app against a deterministic
# mock engine that streams one partial delta then HOLDS the connection open, so
# the mid-stream window is reproducible.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MODEL="gui-stream-deterministic"
HOLD_TOKEN="PARTIAL-HOLD-381"
RECOVERY_REPLY="Recovered reply after cancel."
RUN_ROOT="${PIE_TEST_RUN_ROOT:-/tmp/p381-cancel-$$}"
GUI_HOME="$RUN_ROOT/g"
URL_FILE="$RUN_ROOT/harness.url"
HARNESS_LOG="$RUN_ROOT/cancel-harness.log"
CONFIG_FILE="/tmp/pie-stream-cancel-gui-e2e.env"
HARNESS_PID=""

cleanup() {
  rm -f "$CONFIG_FILE"
  if [ -n "$HARNESS_PID" ] && kill -0 "$HARNESS_PID" >/dev/null 2>&1; then
    kill "$HARNESS_PID" >/dev/null 2>&1 || true
    wait "$HARNESS_PID" >/dev/null 2>&1 || true
  fi
  rm -rf "$RUN_ROOT"
}
trap cleanup EXIT

if ! pgrep -x Dock >/dev/null 2>&1; then
  echo "stream-cancel gui e2e: no seated GUI session detected (Dock not running)" >&2
  exit 2
fi
if [ "${PIE_TEST_TCC_GRANTED:-}" != "1" ]; then
  echo "stream-cancel gui e2e: Rational.app Automation/Accessibility permissions required." >&2
  echo "stream-cancel gui e2e: grant the XCTest runner and Rational.app Automation + Accessibility in System Settings, then rerun:" >&2
  echo "stream-cancel gui e2e: PIE_TEST_TCC_GRANTED=1 Scripts/run-stream-cancel-gui-e2e.sh" >&2
  exit 2
fi

mkdir -p "$GUI_HOME" "$RUN_ROOT"
rm -f "$URL_FILE" "$CONFIG_FILE"

echo "stream-cancel gui e2e: starting holding mock engine"
python3 Scripts/gui-chat-stream-harness.py \
  --port-file "$URL_FILE" \
  --model-id "$MODEL" \
  --mode hold \
  --hold-token "$HOLD_TOKEN" \
  --reply "$RECOVERY_REPLY" \
  >"$HARNESS_LOG" 2>&1 &
HARNESS_PID=$!

for _ in $(seq 1 30); do
  if [ -s "$URL_FILE" ]; then break; fi
  if ! kill -0 "$HARNESS_PID" >/dev/null 2>&1; then
    echo "stream-cancel gui e2e: harness exited before publishing URL" >&2
    cat "$HARNESS_LOG" >&2 || true
    exit 1
  fi
  sleep 1
done
if [ ! -s "$URL_FILE" ]; then
  echo "stream-cancel gui e2e: timed out waiting for harness URL" >&2
  cat "$HARNESS_LOG" >&2 || true
  exit 1
fi

BASE_URL="$(cat "$URL_FILE")"
cat >"$CONFIG_FILE" <<EOF
PIE_TEST_ENGINE_BASE_URL=$BASE_URL
PIE_TEST_GUI_HOME=$GUI_HOME
PIE_TEST_CHAT_MODEL_PIN=$MODEL
EOF

echo "stream-cancel gui e2e: generating Xcode project"
Scripts/genproject.sh

echo "stream-cancel gui e2e: engine=$BASE_URL gui PIE_HOME=$GUI_HOME"
echo "stream-cancel gui e2e: running XCUITest"
xcodebuild -project RatioThink.xcodeproj \
  -scheme RatioThinkGUITests \
  -destination 'platform=macOS,arch=arm64' \
  -parallel-testing-enabled NO \
  test \
  -only-testing:RatioThinkGUITests/S381_StreamCancelGUITests/test_cancel_mid_stream_keeps_partial_bubble_and_recovers_composer \
  ENABLE_CODE_COVERAGE=NO

echo "stream-cancel gui e2e: PASS"
