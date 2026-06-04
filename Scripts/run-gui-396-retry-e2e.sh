#!/bin/bash
# #396 EXECUTED failure-recovery GUI E2E.
#
# Drives RatioThink.app's REAL load path against a loadviz harness started
# with `--fail-load-attempts 1`: the first POST /v1/models/load returns
# HTTP 500, so ModelLoadCenter goes `.failed` and the indicator shows the
# red "Load failed" pip. Then:
#   1. Retry -> retryLast re-invokes the stored factory; the second
#      attempt succeeds (hold -> model_ready) and the load recovers.
#   2. Return over the failed popover = Dismiss (the default key), NOT
#      Retry — the failure clears without reloading.
#
# Each test runs against its OWN freshly-started harness so the
# leading-failure window is deterministic per app session (a shared
# harness would let test 2's first load succeed). Test-only — no engine,
# no production code.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

HOLD_SECONDS="${PIE_TEST_LOAD_HOLD_SECONDS:-20}"
CONFIG_FILE="/tmp/pie-gui-396-retry.env"
HARNESS_PID=""
RUN_ROOT=""

cleanup() {
  rm -f "$CONFIG_FILE"
  if [ -n "$HARNESS_PID" ] && kill -0 "$HARNESS_PID" >/dev/null 2>&1; then
    kill "$HARNESS_PID" >/dev/null 2>&1 || true
    wait "$HARNESS_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if ! pgrep -x Dock >/dev/null 2>&1; then
  echo "gui 396 retry e2e: no seated GUI session detected (Dock not running)" >&2
  exit 2
fi
if [ "${PIE_TEST_TCC_GRANTED:-}" != "1" ]; then
  echo "gui 396 retry e2e: RatioThink.app Automation/Accessibility permissions required." >&2
  echo "gui 396 retry e2e: grant the XCTest runner + RatioThink.app Automation + Accessibility, then rerun:" >&2
  echo "gui 396 retry e2e: PIE_TEST_TCC_GRANTED=1 Scripts/run-gui-396-retry-e2e.sh" >&2
  exit 2
fi

echo "gui 396 retry e2e: generating Xcode project"
Scripts/genproject.sh

# Start a fresh fail-first harness, point the config at it, run ONE test
# method, then tear the harness down. $1 = test method name.
run_one() {
  local method="$1"
  RUN_ROOT="$(mktemp -d /tmp/p396-retry.XXXXXX)"
  local gui_home="$RUN_ROOT/g"
  local url_file="$RUN_ROOT/harness.url"
  local harness_log="$RUN_ROOT/loadviz-harness.log"
  mkdir -p "$gui_home"

  echo "gui 396 retry e2e: starting fail-first harness for $method (hold=${HOLD_SECONDS}s)"
  python3 Scripts/loadviz-harness.py \
    --port-file "$url_file" \
    --hold-seconds "$HOLD_SECONDS" \
    --fail-load-attempts 1 \
    >"$harness_log" 2>&1 &
  HARNESS_PID=$!

  local ok=""
  for _ in $(seq 1 30); do
    if [ -s "$url_file" ]; then ok=1; break; fi
    if ! kill -0 "$HARNESS_PID" >/dev/null 2>&1; then
      echo "gui 396 retry e2e: harness exited before publishing URL" >&2
      cat "$harness_log" >&2 || true
      return 1
    fi
    sleep 1
  done
  if [ -z "$ok" ]; then
    echo "gui 396 retry e2e: timed out waiting for harness URL" >&2
    cat "$harness_log" >&2 || true
    return 1
  fi

  cat >"$CONFIG_FILE" <<EOF
PIE_TEST_ENGINE_BASE_URL=$(cat "$url_file")
PIE_TEST_GUI_HOME=$gui_home
PIE_TEST_LOAD_HOLD_SECONDS=$HOLD_SECONDS
EOF

  echo "gui 396 retry e2e: running $method against $(cat "$url_file")"
  xcodebuild -project RatioThink.xcodeproj \
    -scheme RatioThinkGUITests \
    -destination 'platform=macOS,arch=arm64' \
    -parallel-testing-enabled NO \
    test \
    -only-testing:"RatioThinkGUITests/S396_RetryRecoveryGUITests/$method" \
    ENABLE_CODE_COVERAGE=NO

  kill "$HARNESS_PID" >/dev/null 2>&1 || true
  wait "$HARNESS_PID" >/dev/null 2>&1 || true
  HARNESS_PID=""
}

run_one test_failed_load_offers_retry_and_recovers
run_one test_failed_load_dismiss_clears_without_reloading

echo "gui 396 retry e2e: PASS"
