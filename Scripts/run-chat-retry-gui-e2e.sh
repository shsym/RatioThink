#!/bin/bash
# #513: retry a chat from a prior turn with a destructive truncation confirm.
# Drives Rational.app against the deterministic mock engine in normal mode
# with NUMBERED replies ("… [turn N]"), so the test can tell an erased reply
# from a regenerated one. The test exercises: earlier-turn retry → confirm
# dialog (Cancel = no-op, Retry = truncate + regenerate from the retained
# prefix) and latest-turn retry → no dialog, no duplicate assistant turns.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source "$ROOT/Scripts/e2e-prep.sh"

MODEL="gui-stream-deterministic"
REPLY_STEM="Deterministic reply"
RUN_ROOT="${PIE_TEST_RUN_ROOT:-/tmp/p513-retry-$$}"
GUI_HOME="$RUN_ROOT/g"
URL_FILE="$RUN_ROOT/harness.url"
HARNESS_LOG="$RUN_ROOT/retry-harness.log"
CONFIG_FILE="/tmp/pie-chat-retry-gui-e2e.env"
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

e2e_require_seated_gui "chat-retry gui e2e" || exit 2
e2e_require_tcc "chat-retry gui e2e" || exit 2

mkdir -p "$GUI_HOME" "$RUN_ROOT"
rm -f "$URL_FILE" "$CONFIG_FILE"

# Purge stale NSWindow frame autosave keys (saved under a different display
# arrangement they can restore the window partly offscreen, where XCUITest
# hit-testing fails for the composer) — same recipe as the S507 wrapper.
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

echo "chat-retry gui e2e: starting numbered-reply mock engine"
python3 Scripts/gui-chat-stream-harness.py \
  --port-file "$URL_FILE" \
  --model-id "$MODEL" \
  --mode normal \
  --number-replies \
  --reply "$REPLY_STEM" \
  >"$HARNESS_LOG" 2>&1 &
HARNESS_PID=$!

for _ in $(seq 1 30); do
  if [ -s "$URL_FILE" ]; then break; fi
  if ! kill -0 "$HARNESS_PID" >/dev/null 2>&1; then
    echo "chat-retry gui e2e: harness exited before publishing URL" >&2
    cat "$HARNESS_LOG" >&2 || true
    exit 1
  fi
  sleep 1
done
if [ ! -s "$URL_FILE" ]; then
  echo "chat-retry gui e2e: timed out waiting for harness URL" >&2
  cat "$HARNESS_LOG" >&2 || true
  exit 1
fi

BASE_URL="$(cat "$URL_FILE")"
cat >"$CONFIG_FILE" <<EOF
PIE_TEST_ENGINE_BASE_URL=$BASE_URL
PIE_TEST_GUI_HOME=$GUI_HOME
PIE_TEST_CHAT_MODEL_PIN=$MODEL
EOF

echo "chat-retry gui e2e: generating Xcode project"
Scripts/genproject.sh

echo "chat-retry gui e2e: engine=$BASE_URL gui PIE_HOME=$GUI_HOME"
echo "chat-retry gui e2e: running XCUITest"
XCODE_LOG="$RUN_ROOT/xcodebuild.log"
set +e
e2e_run_gui_xcodebuild "$XCODE_LOG" \
  -project RatioThink.xcodeproj \
  -scheme RatioThinkGUITests \
  -destination 'platform=macOS,arch=arm64' \
  -parallel-testing-enabled NO \
  test \
  -only-testing:RatioThinkGUITests/S513_ChatRetryGUITests/test_retry_prior_turn_confirms_truncation_and_latest_turn_skips_confirm \
  ENABLE_CODE_COVERAGE=NO
status=$?
set -e
if [ "$status" -ne 0 ]; then
  echo "chat-retry gui e2e: xcodebuild failed with status $status; harness log: $HARNESS_LOG" >&2
  cat "$HARNESS_LOG" >&2 || true
  exit "$status"
fi

echo "chat-retry gui e2e: PASS"
