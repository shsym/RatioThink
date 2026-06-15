#!/bin/bash
# Deterministic regression for the GUI test wrapper's testmanagerd-wedge
# detector (Scripts/gui-testmanagerd-hint.sh). Pure log parsing — no seated
# session, no xcodebuild — so it runs in CI alongside the other GUI-wrapper
# preflights under `make test-gui-script`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HINT="$ROOT/Scripts/gui-testmanagerd-hint.sh"

REMEDY="sudo killall testmanagerd"

# Run the detector against a log whose content is $1; capture stdout+stderr and
# the exit status. The detector is advisory, so it must ALWAYS exit 0.
run_hint() {
  local content="$1" log out status
  log="$(mktemp)"
  printf '%s\n' "$content" >"$log"
  set +e
  out="$("$HINT" "$log" 2>&1)"
  status=$?
  set -e
  rm -f "$log"
  if [ "$status" -ne 0 ]; then
    echo "FAIL: detector must exit 0 (advisory), got $status" >&2
    exit 1
  fi
  printf '%s' "$out"
}

assert_contains() {
  case "$1" in
    *"$2"*) : ;;
    *) echo "FAIL: $3 — expected output to contain: $2" >&2
       echo "--- output ---" >&2; printf '%s\n' "$1" >&2; exit 1 ;;
  esac
}

assert_absent() {
  case "$1" in
    *"$2"*) echo "FAIL: $3 — output should NOT contain: $2" >&2
            echo "--- output ---" >&2; printf '%s\n' "$1" >&2; exit 1 ;;
    *) : ;;
  esac
}

# 1) The real runner-init failure → remedy printed.
out="$(run_hint 'Failed to initialize for UI testing: Timed out while enabling automation mode')"
assert_contains "$out" "$REMEDY" "automation-mode timeout"
assert_contains "$out" "wedged testmanagerd" "automation-mode timeout"

# 2) Case-insensitive: a re-phrased line still trips the detector.
out="$(run_hint 'ERROR: ENABLING AUTOMATION MODE timed out after 60s')"
assert_contains "$out" "$REMEDY" "uppercase variant"

# 3) An ordinary test failure → no false remedy.
out="$(run_hint 'Test Case ... failed: XCTAssertEqual mismatch')"
assert_absent "$out" "$REMEDY" "ordinary assertion failure"

# 4) A genuinely passing log → no remedy.
out="$(run_hint '** TEST SUCCEEDED **')"
assert_absent "$out" "$REMEDY" "passing run"

# 5) Missing / nonexistent log argument → silent no-op, exit 0.
set +e
out="$("$HINT" 2>&1)"; status=$?
out2="$("$HINT" /no/such/log 2>&1)"; status2=$?
set -e
if [ "$status" -ne 0 ] || [ "$status2" -ne 0 ]; then
  echo "FAIL: missing/absent log must exit 0, got $status / $status2" >&2
  exit 1
fi
assert_absent "$out$out2" "$REMEDY" "missing log arg"

echo "test-gui-testmanagerd-hint: PASS"
