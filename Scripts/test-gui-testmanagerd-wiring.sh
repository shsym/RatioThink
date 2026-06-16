#!/bin/bash
# Regression for #656: the testmanagerd-wedge detector must be attached to
# EVERY GUI/E2E wrapper, uniformly, via the shared e2e_run_gui_xcodebuild
# helper (Scripts/e2e-prep.sh). Two guarantees:
#
#   1. Structural (breadth) — every Scripts/run-*gui*e2e*.sh routes its
#      xcodebuild through e2e_run_gui_xcodebuild and carries NO bare
#      `xcodebuild` launch. A new wrapper that forgets the helper, or an old
#      one that drifts back to a bare launch, fails here. This is what keeps
#      the detector "attached to ALL wrappers" instead of a hand-maintained
#      list.
#   2. Behavioral (depth) — the helper actually fires the detector: given an
#      xcodebuild that dies with the "enabling automation mode" runner-init
#      timeout, the helper prints the `sudo killall testmanagerd` remedy AND
#      returns xcodebuild's real non-zero status (never tee's), and captures
#      the log it scanned.
#
# Pure shell + a stubbed xcodebuild — no seated session, no real build — so it
# runs in CI under `make test-gui-script`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REMEDY="sudo killall testmanagerd"

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- 1. Structural: all wrappers route through the helper, none bare ---------
shopt -s nullglob
wrappers=("$ROOT"/Scripts/run-*gui*e2e*.sh)
[ "${#wrappers[@]}" -ge 1 ] || fail "found no run-*gui*e2e*.sh wrappers to check"

for w in "${wrappers[@]}"; do
  grep -q 'e2e_run_gui_xcodebuild' "$w" \
    || fail "$(basename "$w") does not route xcodebuild through e2e_run_gui_xcodebuild"
  grep -q 'source "\$ROOT/Scripts/e2e-prep.sh"' "$w" \
    || fail "$(basename "$w") does not source Scripts/e2e-prep.sh (helper undefined)"
  # A bare `xcodebuild …` launch bypasses the capture+detector entirely.
  if grep -nE '^[[:space:]]*xcodebuild[[:space:]]' "$w" >/dev/null; then
    fail "$(basename "$w") still launches xcodebuild directly (bypasses the detector)"
  fi
done
echo "test-gui-testmanagerd-wiring: ${#wrappers[@]} wrappers route through the helper"

# --- 2. Behavioral: the helper fires the detector on the wedge ---------------
source "$ROOT/Scripts/e2e-prep.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/run"

# Stub xcodebuild: emit the runner-init wedge line and exit non-zero, exactly
# as a wedged testmanagerd makes the real tool behave.
cat >"$tmp/bin/xcodebuild" <<'STUB'
#!/bin/bash
echo "Failed to initialize for UI testing: Timed out while enabling automation mode"
exit 65
STUB
chmod +x "$tmp/bin/xcodebuild"

log="$tmp/run/xcodebuild.log"
set +e
out="$(PATH="$tmp/bin:$PATH" e2e_run_gui_xcodebuild "$log" test 2>&1)"
rc=$?
set -e

[ "$rc" -eq 65 ] || fail "helper must return xcodebuild's real status (65), got $rc"
case "$out" in
  *"$REMEDY"*) : ;;
  *) fail "helper did not print the testmanagerd bounce remedy on the wedge" ;;
esac
[ -f "$log" ] || fail "helper did not capture the xcodebuild log"
grep -q "enabling automation mode" "$log" \
  || fail "captured log is missing the xcodebuild output"

# Control: a clean pass must NOT print the remedy and must return 0.
cat >"$tmp/bin/xcodebuild" <<'STUB'
#!/bin/bash
echo "** TEST SUCCEEDED **"
exit 0
STUB
chmod +x "$tmp/bin/xcodebuild"

set +e
out="$(PATH="$tmp/bin:$PATH" e2e_run_gui_xcodebuild "$tmp/run/ok.log" test 2>&1)"
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "helper must return 0 on a passing run, got $rc"
case "$out" in
  *"$REMEDY"*) fail "helper printed the remedy for a passing run (false positive)" ;;
  *) : ;;
esac

echo "test-gui-testmanagerd-wiring: PASS"
