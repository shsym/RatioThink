#!/bin/bash
# #381 part 2: the no-model send gate's "Load default" affordance and its
# follow-through. Stages the chat profile's default model on disk so the gate
# offers Load, then drives Load through a helperless stub engine
# (PIE_TEST_ENGINE_START_TO_RUNNING) that starts stopped and flips to running on
# the start call — no real Helper / pie. After Load resolves, a send streams a
# reply from the mock the stub points at.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Must equal ProfileStore.defaultChatModelID (the seeded `chat` profile default).
SLUG="Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf"
REPLY="bluejay-381"
RUN_ROOT="${PIE_TEST_RUN_ROOT:-/tmp/p381-load-$$}"
GUI_HOME="$RUN_ROOT/g"
URL_FILE="$RUN_ROOT/harness.url"
HARNESS_LOG="$RUN_ROOT/load-harness.log"
CONFIG_FILE="/tmp/pie-load-default-gui-e2e.env"
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
  echo "load-default gui e2e: no seated GUI session detected (Dock not running)" >&2
  exit 2
fi
if [ "${PIE_TEST_TCC_GRANTED:-}" != "1" ]; then
  echo "load-default gui e2e: Rational.app Automation/Accessibility permissions required." >&2
  echo "load-default gui e2e: grant the XCTest runner and Rational.app Automation + Accessibility in System Settings, then rerun:" >&2
  echo "load-default gui e2e: PIE_TEST_TCC_GRANTED=1 Scripts/run-load-default-gui-e2e.sh" >&2
  exit 2
fi

mkdir -p "$GUI_HOME" "$RUN_ROOT"
rm -f "$URL_FILE" "$CONFIG_FILE"

# Stage the default model on disk (a regular file is all `isModelInstalled`
# checks — the stub fakes the engine, so the weight is never loaded) so the gate
# offers Load (needsDefaultLoad + .load), not Download.
MODEL_DEST="$GUI_HOME/models/$SLUG"
mkdir -p "$(dirname "$MODEL_DEST")"
printf 'gguf-stub-381' >"$MODEL_DEST"

echo "load-default gui e2e: starting mock engine (serves $SLUG)"
python3 Scripts/gui-chat-stream-harness.py \
  --port-file "$URL_FILE" \
  --model-id "$SLUG" \
  --mode normal \
  --reply "$REPLY" \
  >"$HARNESS_LOG" 2>&1 &
HARNESS_PID=$!

for _ in $(seq 1 30); do
  if [ -s "$URL_FILE" ]; then break; fi
  if ! kill -0 "$HARNESS_PID" >/dev/null 2>&1; then
    echo "load-default gui e2e: harness exited before publishing URL" >&2
    cat "$HARNESS_LOG" >&2 || true
    exit 1
  fi
  sleep 1
done
if [ ! -s "$URL_FILE" ]; then
  echo "load-default gui e2e: timed out waiting for harness URL" >&2
  cat "$HARNESS_LOG" >&2 || true
  exit 1
fi

BASE_URL="$(cat "$URL_FILE")"
cat >"$CONFIG_FILE" <<EOF
PIE_TEST_ENGINE_BASE_URL=$BASE_URL
PIE_TEST_GUI_HOME=$GUI_HOME
EOF

echo "load-default gui e2e: generating Xcode project"
Scripts/genproject.sh

echo "load-default gui e2e: engine=$BASE_URL gui PIE_HOME=$GUI_HOME model=$SLUG"
echo "load-default gui e2e: running XCUITest"
xcodebuild -project RatioThink.xcodeproj \
  -scheme RatioThinkGUITests \
  -destination 'platform=macOS,arch=arm64' \
  -parallel-testing-enabled NO \
  test \
  -only-testing:RatioThinkGUITests/S381_NoModelLoadDefaultGUITests/test_no_model_gate_load_default_resolves_and_send_succeeds \
  ENABLE_CODE_COVERAGE=NO

echo "load-default gui e2e: PASS"
