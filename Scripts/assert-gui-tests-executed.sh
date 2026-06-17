#!/bin/bash
# Zero-tests-executed backstop for the gui_suite_run Make recipe (#680).
#
# xcodebuild exits 0 even when an `-only-testing:` filter matches ZERO test
# classes — e.g. a GUI suite was renamed and a Makefile ref went dangling. The
# gui_suite_run recipe keyed pass/fail on that exit status alone, so a target
# whose every ref matched nothing would false-green at the target layer. The
# #666 static guard (lint-gui-only-testing.sh) catches dangling refs, but a bare
# `make test-gui-chat` does not run it; this is the runtime safety net that
# fires inside the test recipe itself. The sibling non-GUI unit targets
# (test-app-unit, test-xcode-chat-scaffold) already assert this; mirror it here.
#
# Gating: only meaningful when a seated GUI session is present. Without one,
# RatioThinkGUITests legitimately XCTSkip and a target can report zero executed
# tests for an entirely valid reason, so the caller passes seated=1 only when
# `pgrep -x Dock` succeeded. When not seated, the assertion is a no-op.
#
# Usage: assert-gui-tests-executed.sh <label> <log-file> <seated 0|1>
# Exit:  0 when not seated, or when the log shows >=1 executed test.
#        1 when seated and the log shows no executed-test summary.
set -euo pipefail

label="$1"
log="$2"
seated="$3"

if [ "$seated" != "1" ]; then
  exit 0
fi

# xcodebuild's per-bundle/total summary line reads
#   "Executed N tests, with 0 failures (0 unexpected) in ..."
# and, when some tests XCTSkip, interpolates a skipped-count clause
#   "Executed N tests, with M tests skipped and 0 failures (0 unexpected) in ..."
# A seated run with an unmet runtime gate (PIE_TEST_TCC_GRANTED unset, partial
# Helper TCC) legitimately skips its tests yet still EXECUTED them — the classes
# matched, so N>=1. We only reach this backstop after a status==0 run, so
# failures are already 0; the sole question is whether N is non-zero. A
# dangling/empty filter yields either no such line or "Executed 0 tests", so an
# [1-9]-leading count is the tell that real tests ran. The optional skipped
# clause (singular "1 test"/plural "N tests") must be tolerated so a fully
# skipped-but-matched run does not false-fail (#707).
if grep -Eq 'Executed [1-9][0-9]* tests?, with ([0-9]+ tests? skipped and )?0 failures' "$log"; then
  exit 0
fi

echo "FAIL [test-gui-${label}]: no GUI tests executed — xcodebuild exited 0 but"
echo "  reported zero executed tests. An -only-testing filter likely matched no"
echo "  class (a renamed or deleted GUI suite). See Scripts/lint-gui-only-testing.sh (#666) and #680."
echo "  log: ${log}"
exit 1
