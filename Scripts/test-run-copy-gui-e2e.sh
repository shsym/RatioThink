#!/bin/bash
# Contract tests for run-copy-gui-e2e.sh (#515 review F1): the wrapper must
# never print PASS when the test was skipped — xcodebuild exits 0 on an
# XCTSkip-only run (#427's trap), so PASS requires the positive per-test
# pass line.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/Scripts/run-copy-gui-e2e.sh"
MAKEFILE="$ROOT/Makefile"
TEST_NAME="test_context_menu_copy_answer_spans_all_markdown_sections"

require_contains() {
  local haystack="$1"
  local needle="$2"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "FAIL: expected output to contain: $needle" >&2
    echo "--- output ---" >&2
    printf '%s\n' "$haystack" >&2
    exit 1
  fi
}

test_make_target_does_not_inject_tcc_attestation() {
  if grep -F "PIE_TEST_TCC_GRANTED=1 Scripts/run-copy-gui-e2e.sh" "$MAKEFILE" >/dev/null; then
    echo "FAIL: the make target must not inject PIE_TEST_TCC_GRANTED=1; the caller must attest TCC readiness" >&2
    exit 1
  fi
}

test_requires_tcc_before_starting_harness() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  mkdir -p "$tmp/bin"
  cat >"$tmp/bin/pgrep" <<'FAKE_PGREP'
#!/bin/bash
exit 0
FAKE_PGREP
  chmod +x "$tmp/bin/pgrep"

  set +e
  local output
  output="$(
    PATH="$tmp/bin:$PATH" \
    PIE_TEST_TCC_GRANTED= \
    PIE_TEST_RUN_ROOT="$tmp/run" \
    "$SCRIPT" 2>&1
  )"
  local status=$?
  set -e

  if [[ "$status" -ne 2 ]]; then
    echo "FAIL: expected missing TCC preflight to exit 2, got $status" >&2
    echo "--- output ---" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
  require_contains "$output" "Rational.app Automation/Accessibility permissions required"
  require_contains "$output" "PIE_TEST_TCC_GRANTED=1"
  if [[ "$output" == *"starting deterministic mock engine"* ]]; then
    echo "FAIL: TCC preflight must happen before starting the mock engine" >&2
    exit 1
  fi
}

# Run the wrapper with every external stage stubbed and xcodebuild emitting
# the given XCTest result line. Prints the wrapper's output; returns its exit.
run_wrapper_with_xcodebuild_emitting() {
  local result_line="$1"
  local tmp="$2"

  mkdir -p "$tmp/bin"
  cat >"$tmp/bin/pgrep" <<'FAKE_PGREP'
#!/bin/bash
exit 0
FAKE_PGREP
  # Fake harness: honor --port-file so the wrapper's URL wait succeeds, then
  # idle until the wrapper's cleanup kills us.
  cat >"$tmp/bin/python3" <<'FAKE_PYTHON3'
#!/bin/bash
port_file=""
while [ $# -gt 0 ]; do
  if [ "$1" = "--port-file" ]; then port_file="$2"; shift; fi
  shift
done
echo "http://127.0.0.1:1" >"$port_file"
exec sleep 600
FAKE_PYTHON3
  cat >"$tmp/bin/xcodebuild" <<FAKE_XCODEBUILD
#!/bin/bash
echo "$result_line"
echo "** TEST SUCCEEDED **"
exit 0
FAKE_XCODEBUILD
  chmod +x "$tmp/bin/pgrep" "$tmp/bin/python3" "$tmp/bin/xcodebuild"

  PATH="$tmp/bin:$PATH" \
  PIE_TEST_TCC_GRANTED=1 \
  PIE_TEST_RUN_ROOT="$tmp/run" \
  PIE_TEST_GENPROJECT=/usr/bin/true \
  "$SCRIPT" 2>&1
}

test_skipped_test_fails_loudly() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  set +e
  local output
  output="$(run_wrapper_with_xcodebuild_emitting \
    "Test Case '-[RatioThinkGUITests.S515_CopyTranscriptGUITests $TEST_NAME]' skipped (0.001 seconds)." \
    "$tmp")"
  local status=$?
  set -e

  if [[ "$status" -eq 0 ]]; then
    echo "FAIL: a skipped test must not produce a zero exit" >&2
    echo "--- output ---" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
  require_contains "$output" "SKIPPED"
  if [[ "$output" == *"copy gui e2e: PASS"* ]]; then
    echo "FAIL: wrapper printed PASS for a skipped test" >&2
    exit 1
  fi
}

test_missing_pass_signal_fails_loudly() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  set +e
  local output
  output="$(run_wrapper_with_xcodebuild_emitting "Testing started" "$tmp")"
  local status=$?
  set -e

  if [[ "$status" -eq 0 ]]; then
    echo "FAIL: missing per-test pass line must not produce a zero exit" >&2
    echo "--- output ---" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
  require_contains "$output" "no positive pass signal"
}

test_passed_test_passes() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  set +e
  local output
  output="$(run_wrapper_with_xcodebuild_emitting \
    "Test Case '-[RatioThinkGUITests.S515_CopyTranscriptGUITests $TEST_NAME]' passed (1.0 seconds)." \
    "$tmp")"
  local status=$?
  set -e

  if [[ "$status" -ne 0 ]]; then
    echo "FAIL: a passed test must exit 0, got $status" >&2
    echo "--- output ---" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
  require_contains "$output" "copy gui e2e: PASS"
}

test_make_target_does_not_inject_tcc_attestation
test_requires_tcc_before_starting_harness
test_skipped_test_fails_loudly
test_missing_pass_signal_fails_loudly
test_passed_test_passes
echo "test-run-copy-gui-e2e: PASS"
