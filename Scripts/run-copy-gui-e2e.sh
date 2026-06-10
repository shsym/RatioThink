#!/bin/bash
# #515: context-menu Copy Answer must copy the canonical Markdown source of a
# multi-section assistant message (paragraph + list + fenced code) even though
# MarkdownUI renders it as multiple independently selectable Text blocks.
# Drives Rational.app against the deterministic stream harness (mode=normal)
# whose reply IS the multi-section Markdown, then asserts NSPasteboard.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MODEL="gui-stream-deterministic"
RUN_ROOT="${PIE_TEST_RUN_ROOT:-/tmp/p515-copy-$$}"
GUI_HOME="$RUN_ROOT/g"
URL_FILE="$RUN_ROOT/harness.url"
HARNESS_LOG="$RUN_ROOT/copy-harness.log"
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
  echo "copy gui e2e: no seated GUI session detected (Dock not running)" >&2
  exit 2
fi
if [ "${PIE_TEST_TCC_GRANTED:-}" != "1" ]; then
  echo "copy gui e2e: Rational.app Automation/Accessibility permissions required." >&2
  echo "copy gui e2e: grant the XCTest runner and Rational.app Automation + Accessibility in System Settings, then rerun:" >&2
  echo "copy gui e2e: PIE_TEST_TCC_GRANTED=1 Scripts/run-copy-gui-e2e.sh" >&2
  exit 2
fi

mkdir -p "$GUI_HOME" "$RUN_ROOT"
rm -f "$URL_FILE" "$CONFIG_FILE"

# The multi-section reply: exactly the Markdown shapes MarkdownUI splits into
# separate selectable blocks. The test asserts the pasteboard equals this file
# byte-for-byte, so it is written once here and read by both harness and test.
cat >"$ANSWER_FILE" <<'EOF'
Intro paragraph copy515-intro.

- copy515-item-one
- copy515-item-two

```swift
let copy515_code = 1 < 2
```

Tail paragraph copy515-tail.
EOF
# The SSE reply must match the file with no trailing newline drift: strip the
# heredoc's final newline so pasteboard == file contents exactly.
REPLY="$(cat "$ANSWER_FILE")"
printf '%s' "$REPLY" >"$ANSWER_FILE"

echo "copy gui e2e: starting deterministic mock engine"
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
    echo "copy gui e2e: harness exited before publishing URL" >&2
    cat "$HARNESS_LOG" >&2 || true
    exit 1
  fi
  sleep 1
done
if [ ! -s "$URL_FILE" ]; then
  echo "copy gui e2e: timed out waiting for harness URL" >&2
  cat "$HARNESS_LOG" >&2 || true
  exit 1
fi

BASE_URL="$(cat "$URL_FILE")"
cat >"$CONFIG_FILE" <<EOF
PIE_TEST_ENGINE_BASE_URL=$BASE_URL
PIE_TEST_GUI_HOME=$GUI_HOME
PIE_TEST_CHAT_MODEL=$MODEL
PIE_TEST_EXPECTED_ANSWER_FILE=$ANSWER_FILE
EOF

echo "copy gui e2e: generating Xcode project"
Scripts/genproject.sh

echo "copy gui e2e: engine=$BASE_URL gui PIE_HOME=$GUI_HOME"
echo "copy gui e2e: running XCUITest"
xcodebuild -project RatioThink.xcodeproj \
  -scheme RatioThinkGUITests \
  -destination 'platform=macOS,arch=arm64' \
  -parallel-testing-enabled NO \
  test \
  -only-testing:RatioThinkGUITests/S515_CopyTranscriptGUITests/test_context_menu_copy_answer_spans_all_markdown_sections \
  ENABLE_CODE_COVERAGE=NO

echo "copy gui e2e: PASS"
