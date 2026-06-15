#!/bin/bash
# GUI test wrapper post-mortem: detect a wedged `testmanagerd` and print the
# one known recovery.
#
# When a seated XCUITest run dies at runner-init with
#   "Failed to initialize for UI testing: Timed out while enabling automation mode"
# the build and the test *compiled* fine and the same command passed earlier —
# the failure is a wedged `testmanagerd`, not a code bug (insight:489). The fix
# is to bounce the daemon (it auto-respawns); `caffeinate` and lone re-runs do
# not help. This scanner reads a captured xcodebuild log and, if it sees the
# automation-mode timeout, prints that remedy so the operator isn't left
# chasing a phantom regression.
#
# Usage: Scripts/gui-testmanagerd-hint.sh <xcodebuild-log-file>
#
# Always exits 0: this is an advisory printed *after* the real test status has
# already been captured by the caller, so it must never mask that status.
set -euo pipefail

LOG="${1:-}"
if [ -z "$LOG" ] || [ ! -f "$LOG" ]; then
  exit 0
fi

# The distinctive substring of the runner-init failure. Matched
# case-insensitively so a change in xcodebuild's surrounding phrasing
# ("Failed to initialize for UI testing: ...") still trips it.
if ! grep -qi "enabling automation mode" "$LOG"; then
  exit 0
fi

cat >&2 <<'HINT'

────────────────────────────────────────────────────────────────────────────
GUI test wrapper: detected "Timed out while enabling automation mode".
This is a wedged testmanagerd, NOT a code or test failure — the build and
tests compiled, and the same command passes once the daemon is bounced.

Recover, then re-run:

    sudo killall testmanagerd     # auto-respawns

`caffeinate` and lone re-runs do not clear this wedge.
────────────────────────────────────────────────────────────────────────────
HINT

exit 0
