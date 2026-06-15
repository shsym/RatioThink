#!/bin/bash
# #636 / GH #158: a single mouse drag must select continuous text ACROSS
# paragraph boundaries in one message bubble (the thing MarkdownUI's per-block
# Text rendering made structurally impossible — #515 worked around it with a
# Copy button). The bubble now renders into one selectable NSTextView. This
# drives Rational.app against the same deterministic stream harness as the #515
# copy E2E (mode=normal, multi-section Markdown reply), drags top→bottom across
# the rendered answer, copies, and asserts the pasteboard spans the first AND
# last paragraph.
#
# Mirrors Scripts/run-copy-gui-e2e.sh (same harness + answer fixture) but runs
# the drag-selection test; kept as a sibling so #515's verified copy script and
# its contract guard (Scripts/test-run-copy-gui-e2e.sh) stay untouched.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MODEL="gui-stream-deterministic"
RUN_ROOT="${PIE_TEST_RUN_ROOT:-/tmp/p636-select-$$}"
GUI_HOME="$RUN_ROOT/g"
URL_FILE="$RUN_ROOT/harness.url"
HARNESS_LOG="$RUN_ROOT/select-harness.log"
ANSWER_FILE="$RUN_ROOT/expected-answer.md"
CONFIG_FILE="/tmp/pie-copy-gui-e2e.env"
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
  echo "select gui e2e: no seated GUI session detected (Dock not running)" >&2
  exit 2
fi
if [ "${PIE_TEST_TCC_GRANTED:-}" != "1" ]; then
  echo "select gui e2e: Rational.app Automation/Accessibility permissions required." >&2
  echo "select gui e2e: grant the XCTest runner and Rational.app Automation + Accessibility in System Settings, then rerun:" >&2
  echo "select gui e2e: PIE_TEST_TCC_GRANTED=1 Scripts/run-select-gui-e2e.sh" >&2
  exit 2
fi

mkdir -p "$GUI_HOME" "$RUN_ROOT"
rm -f "$URL_FILE" "$CONFIG_FILE"

# The multi-section reply: the same shapes MarkdownUI split into separate
# selectable blocks. The drag-select test asserts the copied selection contains
# the first paragraph (copy515-intro), the last paragraph (copy515-tail), and a
# middle list item (copy515-item).
cat >"$ANSWER_FILE" <<'EOF'
Intro paragraph copy515-intro.

- copy515-item-one
- copy515-item-two

```swift
let copy515_code = 1 < 2
```

Tail paragraph copy515-tail.
EOF
REPLY="$(cat "$ANSWER_FILE")"
printf '%s' "$REPLY" >"$ANSWER_FILE"

echo "select gui e2e: starting deterministic mock engine"
python3 Scripts/gui-chat-stream-harness.py \
  --port-file "$URL_FILE" \
  --model-id "$MODEL" \
  --mode normal \
  --reply "$REPLY" \
  >"$HARNESS_LOG" 2>&1 &
HARNESS_PID=$!

for _ in $(seq 1 30); do
  if [ -s "$URL_FILE" ]; then break; fi
  if ! kill -0 "$HARNESS_PID" >/dev/null 2>&1; then
    echo "select gui e2e: harness exited before publishing URL" >&2
    cat "$HARNESS_LOG" >&2 || true
    exit 1
  fi
  sleep 1
done
if [ ! -s "$URL_FILE" ]; then
  echo "select gui e2e: timed out waiting for harness URL" >&2
  cat "$HARNESS_LOG" >&2 || true
  exit 1
fi

BASE_URL="$(cat "$URL_FILE")"
cat >"$CONFIG_FILE" <<EOF
PIE_TEST_ENGINE_BASE_URL=$BASE_URL
PIE_TEST_GUI_HOME=$GUI_HOME
PIE_TEST_CHAT_MODEL_PIN=$MODEL
PIE_TEST_EXPECTED_ANSWER_FILE=$ANSWER_FILE
EOF

echo "select gui e2e: generating Xcode project"
"${PIE_TEST_GENPROJECT:-Scripts/genproject.sh}"

echo "select gui e2e: engine=$BASE_URL gui PIE_HOME=$GUI_HOME"
echo "select gui e2e: running XCUITest"
TEST_NAME="test_drag_selection_spans_paragraphs"
XCODE_LOG="$RUN_ROOT/xcodebuild.log"
set +e
xcodebuild -project RatioThink.xcodeproj \
  -scheme RatioThinkGUITests \
  -destination 'platform=macOS,arch=arm64' \
  -parallel-testing-enabled NO \
  test \
  -only-testing:"RatioThinkGUITests/S515_CopyTranscriptGUITests/$TEST_NAME" \
  ENABLE_CODE_COVERAGE=NO 2>&1 | tee "$XCODE_LOG"
status=${PIPESTATUS[0]}
set -e
if [ "$status" -ne 0 ]; then
  echo "select gui e2e: FAIL (xcodebuild exit $status)" >&2
  exit "$status"
fi

# xcodebuild exits 0 when the only test ends in XCTSkip — require the positive
# per-test pass line and refuse any skip before claiming PASS (#427 trap).
if grep -q "Test Case .*$TEST_NAME.*skipped" "$XCODE_LOG"; then
  echo "select gui e2e: FAIL — test was SKIPPED, not run" >&2
  exit 1
fi
if ! grep -q "Test Case .*$TEST_NAME.*passed" "$XCODE_LOG"; then
  echo "select gui e2e: FAIL — no positive pass signal for $TEST_NAME" >&2
  exit 1
fi

echo "select gui e2e: PASS"
