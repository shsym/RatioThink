#!/bin/bash
# Unit regression for Scripts/lib/proc-acceptance.sh ( F1).
#
# Verification must reject any pie/RationalHelper not PROVEN to be from this
# launch: a stale image whose argv still shows the (replaced) bundle path,
# AND — crucially — a respawn in the SAME wall-clock second as the
# acceptance epoch (whole-second `etimes` would otherwise compute it as
# starting exactly at the epoch). The lib uses STRICT `start > epoch`; the
# installer adds a one-second barrier so the genuine new process starts at
# epoch+1. `ps`/`date` are stubbed — no real processes touched.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/proc-acceptance.sh
. "$ROOT/Scripts/lib/proc-acceptance.sh"

APP="/Applications/Rational.app"
EPOCH=1000000
NOW=$EPOCH        # mutable; the date stub reads it

date() { echo "$NOW"; }
# ps -o args= -p <pid>  /  ps -o etimes= -p <pid> / ps -o pid=,comm=,etimes= -p <pid>
#   1xx: new-bundle path;  200: foreign path
ps() {
  local field="$2" pid="$4"
  case "$field" in
    args=)
      case "$pid" in
        100|101|102|103) echo "/Applications/Rational.app/Contents/Resources/pie-engine/pie serve --config x" ;;
        200|300)         echo "/Applications/Other.app/Contents/MacOS/Other" ;;
        *)               return 1 ;;
      esac ;;
    etimes=)
      case "$pid" in
        100) echo "7" ;;   # with NOW=EPOCH+5 -> start = EPOCH-2  (before)
        101) echo "5" ;;   # with NOW=EPOCH+5 -> start = EPOCH     (same-second boundary)
        103) echo "4" ;;   # with NOW=EPOCH+5 -> start = EPOCH+1   (after barrier)
        102) echo "0" ;;   # used in the NOW=EPOCH scenario -> start = EPOCH
        200|300) echo "0" ;;
        *)   return 1 ;;
      esac ;;
    pid=,comm=,etimes=)
      case "$pid" in
        100|101|102|103) echo "$pid RationalHelper 4" ;;
        200)             echo "$pid pie 0" ;;
        300)             echo "$pid RatioThinkHelper 0" ;;
        *)               return 1 ;;
      esac ;;
  esac
}
pgrep() {
  case "$2" in
    pie)              echo "200" ;;
    RationalHelper)   echo "103" ;;
    RatioThinkHelper) echo "300" ;;
  esac
}

fails=0
reject() { if proc_is_new_bundle "$1" "$APP" "$EPOCH"; then echo "FAIL: pid $1 should be REJECTED ($2)"; fails=$((fails+1)); else echo "ok:  pid $1 rejected  ($2)"; fi; }
accept() { if proc_is_new_bundle "$1" "$APP" "$EPOCH"; then echo "ok:  pid $1 accepted  ($2)"; else echo "FAIL: pid $1 should be ACCEPTED ($2)"; fails=$((fails+1)); fi; }

# Scenario A — barrier elapsed (now = epoch + 5).
NOW=$((EPOCH + 5))
reject 100 "new-bundle path, started 2s before epoch"
reject 101 "new-bundle path, started in the SAME second as epoch (strict > rejects)"
accept 103 "new-bundle path, started at epoch+1 (after the one-second barrier)"
reject 200 "foreign bundle path"

# Scenario B — same-second respawn with etimes=0 (now == epoch): a process
# that booted at the acceptance instant must NOT be trusted.
NOW=$EPOCH
reject 102 "etimes=0 respawn in the same second as the acceptance epoch"

NOW=$((EPOCH + 5))
stale="$(stale_procs "$APP" "$EPOCH")"
case "$stale" in
  *"200 pie"* ) echo "ok:  stale_procs reports foreign pie" ;;
  *) echo "FAIL: stale_procs did not report foreign pie ($stale)"; fails=$((fails+1)) ;;
esac
case "$stale" in
  *"300 RatioThinkHelper"* ) echo "ok:  stale_procs reports legacy RatioThinkHelper during rename migration" ;;
  *) echo "FAIL: stale_procs did not report legacy RatioThinkHelper ($stale)"; fails=$((fails+1)) ;;
esac
case "$stale" in
  *"103 RationalHelper"* ) echo "FAIL: stale_procs reported new RationalHelper ($stale)"; fails=$((fails+1)) ;;
  *) echo "ok:  stale_procs ignores accepted new RationalHelper" ;;
esac

if [ "$fails" -eq 0 ]; then echo "PASS: proc-acceptance"; exit 0; else echo "FAIL: $fails check(s)"; exit 1; fi
