#!/bin/bash
# Self-test for assert-gui-tests-executed.sh (#680). Drives the gui_suite_run
# zero-tests-executed backstop against synthetic xcodebuild logs and asserts it
# (a) passes when real tests executed, (b) trips when a seated run executed
# nothing (the dangling/empty -only-testing filter bug), and (c) stays a no-op
# when no seated session is present (legit XCTSkip-all). Mutation-proven: every
# PASS fixture has a FAIL twin one input away, so a no-op backstop fails here.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASSERT="$ROOT/Scripts/assert-gui-tests-executed.sh"

TMP=$(mktemp -d -t pie-assert-gui-self-test.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

LOG="$TMP/run.log"

# $1=label $2=expect(PASS|FAIL) $3=seated(0|1)
run() {
  local label="$1" expect="$2" seated="$3"
  local output rc result
  set +e
  output=$("$ASSERT" "selftest" "$LOG" "$seated" 2>&1); rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then result=PASS; else result=FAIL; fi
  if [ "$result" != "$expect" ]; then
    echo "SELF-TEST FAIL [$label]: expected $expect got $result (rc=$rc, seated=$seated)"
    echo "--- backstop output:"; echo "$output"
    echo "--- log:"; cat "$LOG"
    exit 1
  fi
  echo "ok   [$label] $result"
}

# 1. Seated + real tests executed → PASS (the normal green path).
cat > "$LOG" <<'EOF'
Test Suite 'S260_ChatModelMenuGUITests' started
Test Case '-[... test_x]' passed (1.2 seconds).
Test Suite 'S260_ChatModelMenuGUITests' passed
	 Executed 3 tests, with 0 failures (0 unexpected) in 3.4 (3.5) seconds
EOF
run "seated, tests executed" PASS 1

# 2. Seated + zero tests executed (dangling/empty filter) → FAIL (the #680 bug).
#    xcodebuild exited 0 but no class matched, so no executed-test summary.
cat > "$LOG" <<'EOF'
Test Suite 'Selected tests' started
Test Suite 'Selected tests' passed
	 Executed 0 tests, with 0 failures (0 unexpected) in 0.0 (0.0) seconds
** TEST SUCCEEDED **
EOF
run "seated, zero tests executed" FAIL 1

# 3. Seated but log has no executed summary at all → FAIL (defensive).
cat > "$LOG" <<'EOF'
** TEST SUCCEEDED **
EOF
run "seated, no executed summary" FAIL 1

# 4. NOT seated + zero tests executed → PASS (legit XCTSkip-all, gate is a no-op).
#    Same empty log as #2; the ONLY difference is seated=0. This proves the Dock
#    gate is load-bearing: flip seated to 1 and this fixture becomes scenario #2.
cat > "$LOG" <<'EOF'
Test Suite 'Selected tests' started
Test Suite 'Selected tests' passed
	 Executed 0 tests, with 0 failures (0 unexpected) in 0.0 (0.0) seconds
** TEST SUCCEEDED **
EOF
run "unseated, zero tests executed (gated off)" PASS 0

# 5. Multi-suite log where at least one bundle executed tests → PASS.
cat > "$LOG" <<'EOF'
Test Suite 'S285_ZeroStateGUITests' passed
	 Executed 0 tests, with 0 failures (0 unexpected) in 0.0 (0.0) seconds
Test Suite 'S286_NoModelSendGateGUITests' passed
	 Executed 2 tests, with 0 failures (0 unexpected) in 2.1 (2.2) seconds
EOF
run "seated, mixed bundles, some executed" PASS 1

# 6. Seated + exactly one test executed → PASS. xcodebuild emits the SINGULAR
#    "Executed 1 test, with 0 failures" for a one-test bundle/total; a plural-only
#    regex would false-FAIL this legit run (review F1). Mirrors the sibling guards'
#    `tests?` pattern at Makefile:321,377.
cat > "$LOG" <<'EOF'
Test Suite 'S279_LifecycleRecoveryGUITests' passed
	 Executed 1 test, with 0 failures (0 unexpected) in 1.0 (1.1) seconds
EOF
run "seated, single test executed" PASS 1

echo "assert-gui-tests-executed self-test: all scenarios pass"
