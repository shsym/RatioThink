#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MODEL="${PIE_TEST_CHAT_MODEL:-resume-deterministic}"
RUN_ROOT="${PIE_TEST_RUN_ROOT:-/tmp/p275-history-$$}"
GUI_HOME="$RUN_ROOT/g"
URL_FILE="$RUN_ROOT/harness.url"
REQUEST_LOG="$RUN_ROOT/chat-requests.jsonl"
HARNESS_LOG="$RUN_ROOT/history-harness.log"
CONFIG_FILE="/tmp/pie-resume-gui-history-e2e.env"
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
  echo "resume gui history e2e: no seated GUI session detected (Dock not running)" >&2
  exit 2
fi
if [ "${PIE_TEST_TCC_GRANTED:-}" != "1" ]; then
  echo "resume gui history e2e: Rational.app Automation/Accessibility permissions required." >&2
  echo "resume gui history e2e: grant Xcode/XCTest runner and Rational.app Automation + Accessibility in System Settings, then rerun:" >&2
  echo "resume gui history e2e: PIE_TEST_TCC_GRANTED=1 Scripts/run-resume-gui-history-e2e.sh" >&2
  exit 2
fi

mkdir -p "$GUI_HOME" "$RUN_ROOT"
rm -f "$URL_FILE" "$REQUEST_LOG" "$CONFIG_FILE"

echo "resume gui history e2e: starting deterministic HTTP harness"
python3 Scripts/resume-history-harness.py \
  --port-file "$URL_FILE" \
  --request-log "$REQUEST_LOG" \
  >"$HARNESS_LOG" 2>&1 &
HARNESS_PID=$!

for _ in $(seq 1 30); do
  if [ -s "$URL_FILE" ]; then
    break
  fi
  if ! kill -0 "$HARNESS_PID" >/dev/null 2>&1; then
    echo "resume gui history e2e: harness exited before publishing URL" >&2
    cat "$HARNESS_LOG" >&2 || true
    exit 1
  fi
  sleep 1
done

if [ ! -s "$URL_FILE" ]; then
  echo "resume gui history e2e: timed out waiting for harness URL" >&2
  cat "$HARNESS_LOG" >&2 || true
  exit 1
fi

BASE_URL="$(cat "$URL_FILE")"
cat >"$CONFIG_FILE" <<EOF
PIE_TEST_ENGINE_BASE_URL=$BASE_URL
PIE_TEST_GUI_HOME=$GUI_HOME
PIE_TEST_CHAT_MODEL=$MODEL
PIE_TEST_REQUEST_LOG=$REQUEST_LOG
EOF

echo "resume gui history e2e: generating Xcode project"
Scripts/genproject.sh

echo "resume gui history e2e: engine=$BASE_URL"
echo "resume gui history e2e: model=$MODEL"
echo "resume gui history e2e: gui PIE_HOME=$GUI_HOME"
echo "resume gui history e2e: request log=$REQUEST_LOG"
echo "resume gui history e2e: retained run root: $RUN_ROOT"
echo "resume gui history e2e: running XCUITest"

xcodebuild -project RatioThink.xcodeproj \
  -scheme RatioThinkGUITests \
  -destination 'platform=macOS,arch=arm64' \
  -parallel-testing-enabled NO \
  test \
  -only-testing:RatioThinkGUITests/S275_MultiTurnResumeGUITests/test_multi_turn_history_survives_relaunch_and_is_sent_to_engine \
  ENABLE_CODE_COVERAGE=NO

python3 - "$GUI_HOME/chats.sqlite" <<'PY'
import sqlite3
import sys

db = sys.argv[1]
expected = [
    ("user", "Remember this code word: cerulean-275"),
    ("assistant", "I will remember cerulean-275."),
    ("user", "What code word did I give you?"),
    ("assistant", "The code word is cerulean-275."),
    ("user", "Repeat the code word again."),
    ("assistant", "Again: cerulean-275."),
]
rows = sqlite3.connect(db).execute(
    "select ZROLE, ZCONTENT from ZMESSAGE order by ZTS"
).fetchall()
if rows != expected:
    print(f"resume gui history e2e: sqlite rows mismatch in {db}", file=sys.stderr)
    print(f"expected={expected!r}", file=sys.stderr)
    print(f"actual={rows!r}", file=sys.stderr)
    sys.exit(1)
PY

echo "resume gui history e2e: request log contains ordered turn-2 and turn-3 histories"
echo "resume gui history e2e: sqlite contains all 6 expected message rows in order"
echo "resume gui history e2e: PASS"
