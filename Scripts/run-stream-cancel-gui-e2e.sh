#!/bin/bash
# #507: an in-flight chat stream survives switching chats (it used to be the
# #381 navigate-away CANCEL path). Drives Rational.app against a deterministic
# mock engine that streams one partial delta then HOLDS the connection open.
# Two phases, each with a FRESH harness (the harness's hold window is keyed on
# its request counter, so test methods must not share one instance):
#   1. single-stream continuity + stop affordance (hold-count 2)
#   2. five chats streaming CONCURRENTLY with per-row indicators (hold-count 5)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source "$ROOT/Scripts/e2e-prep.sh"

MODEL="gui-stream-deterministic"
HOLD_TOKEN="PARTIAL-HOLD-507"
RECOVERY_REPLY="Released reply after background switch."
RUN_ROOT="${PIE_TEST_RUN_ROOT:-/tmp/p381-cancel-$$}"
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

mkdir -p "$RUN_ROOT"
rm -f "$URL_FILE" "$CONFIG_FILE"

# Window-frame autosave keys live in the REAL com.ratiothink.app defaults
# domain (not PIE_HOME), so a frame saved under a previous display
# arrangement (e.g. a portrait monitor) can restore the test window TALLER
# than the current screen — bottom-anchored controls (composer) and the
# above-screen header then fail XCUITest hit-testing. Purge them so the
# test window opens at the in-bounds default size.
/usr/bin/python3 - <<'PURGE_FRAMES'
import plistlib
import subprocess

export = subprocess.run(
    ["defaults", "export", "com.ratiothink.app", "-"],
    capture_output=True,
)
if export.returncode == 0 and export.stdout:
    for key in plistlib.loads(export.stdout):
        if key.startswith("NSWindow Frame "):
            subprocess.run(["defaults", "delete", "com.ratiothink.app", key],
                           capture_output=True)
PURGE_FRAMES

echo "stream-cancel gui e2e: generating Xcode project"
Scripts/genproject.sh

# Start a fresh harness with the given hold-count and (re)write the env
# config the test reads. Each phase gets its own GUI_HOME so chats from
# phase 1 never appear in phase 2's sidebar.
start_harness() {
  local hold_count="$1"
  local gui_home="$2"
  if [ -n "$HARNESS_PID" ] && kill -0 "$HARNESS_PID" >/dev/null 2>&1; then
    kill "$HARNESS_PID" >/dev/null 2>&1 || true
    wait "$HARNESS_PID" >/dev/null 2>&1 || true
  fi
  mkdir -p "$gui_home"
  rm -f "$URL_FILE" "$CONFIG_FILE"

  echo "stream-cancel gui e2e: starting holding mock engine (hold-count=$hold_count)"
  python3 Scripts/gui-chat-stream-harness.py \
    --port-file "$URL_FILE" \
    --model-id "$MODEL" \
    --mode hold \
    --hold-count "$hold_count" \
    --hold-token "$HOLD_TOKEN" \
    --reply "$RECOVERY_REPLY" \
    >>"$HARNESS_LOG" 2>&1 &
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

  local base_url
  base_url="$(cat "$URL_FILE")"
  cat >"$CONFIG_FILE" <<EOF
PIE_TEST_ENGINE_BASE_URL=$base_url
PIE_TEST_GUI_HOME=$gui_home
PIE_TEST_CHAT_MODEL_PIN=$MODEL
EOF
  echo "stream-cancel gui e2e: engine=$base_url gui PIE_HOME=$gui_home"
}

run_test() {
  local method="$1"
  echo "stream-cancel gui e2e: running XCUITest $method"
  local status
  set +e
  e2e_run_gui_xcodebuild "$RUN_ROOT/xcodebuild-$method.log" \
    -project RatioThink.xcodeproj \
    -scheme RatioThinkGUITests \
    -destination 'platform=macOS,arch=arm64' \
    -parallel-testing-enabled NO \
    test \
    "-only-testing:RatioThinkGUITests/S507_StreamContinuityGUITests/$method" \
    ENABLE_CODE_COVERAGE=NO
  status=$?
  set -e
  [ "$status" -ne 0 ] && exit "$status"
}

start_harness 2 "$RUN_ROOT/g1"
run_test test_stream_survives_chat_switch_with_row_indicator_and_finishes_in_background

start_harness 5 "$RUN_ROOT/g2"
run_test test_five_chats_stream_concurrently_with_per_row_indicators

echo "stream-cancel gui e2e: PASS"
