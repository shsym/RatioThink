#!/usr/bin/env bash
# #473 review v1 F1 — engine-free unit test for run-matrix-e2e.sh's
# `aggregate_cell`. Sources the wrapper (its `main` is guarded behind a
# direct-execution check, so sourcing only loads the functions) and drives
# the aggregator with synthetic cell logs, asserting the fail-closed verdict
# logic. Hits the REAL function — no reimplementation — so a regression in
# the shipped aggregator fails here.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=Scripts/run-matrix-e2e.sh disable=SC1091
source "$ROOT/Scripts/run-matrix-e2e.sh"
set +e  # the sourced wrapper sets -e; regain explicit control for assertions

PROFILES="chat,tree-of-thought,fast-think"
rc=0

# Reset the globals aggregate_cell mutates + a fresh per-case SUMMARY.
reset_case() {
  SUMMARY="$(mktemp)"
  PASS_COUNT=0
  FAIL_COUNT=0
  overall_rc=0
}

check() {
  local desc="$1" cond="$2"
  if [ "$cond" = "1" ]; then
    echo "ok   — $desc"
  else
    echo "FAIL — $desc"
    echo "      SUMMARY was:"; sed 's/^/        /' "$SUMMARY"
    rc=1
  fi
}

write_pass_log() {  # <log> : three PASS cells
  printf 'MATRIX-CELL\tfoo.gguf\tchat\tPASS\n'            >  "$1"
  printf 'MATRIX-CELL\tfoo.gguf\ttree-of-thought\tPASS\n' >> "$1"
  printf 'MATRIX-CELL\tfoo.gguf\tfast-think\tPASS\n'      >> "$1"
}

# --- Case 1: all-PASS cells but the run exited non-zero (the F1 fail-open) --
reset_case; LOG="$(mktemp)"; write_pass_log "$LOG"
aggregate_cell "org/foo.gguf" "foo.gguf" "$PROFILES" "$LOG" 1
laundered=0; [ "$overall_rc" -eq 1 ] && grep -q "cell_rc=1 despite PASS cells" "$SUMMARY" && laundered=1
check "all-PASS + cell_rc=1 → recorded FAIL and overall_rc=1 (fail-closed)" "$laundered"
nofail=0; [ "$FAIL_COUNT" -eq 1 ] && [ "$PASS_COUNT" -eq 3 ] && nofail=1
check "all-PASS + cell_rc=1 → 3 PASS counted + exactly 1 row-level FAIL" "$nofail"

# --- Case 2: all-PASS cells, clean exit → no spurious failure --------------
reset_case; LOG="$(mktemp)"; write_pass_log "$LOG"
aggregate_cell "org/foo.gguf" "foo.gguf" "$PROFILES" "$LOG" 0
clean=0; [ "$overall_rc" -eq 0 ] && [ "$FAIL_COUNT" -eq 0 ] && [ "$PASS_COUNT" -eq 3 ] \
  && ! grep -q "despite PASS cells" "$SUMMARY" && clean=1
check "all-PASS + cell_rc=0 → all PASS, overall_rc=0, no spurious FAIL" "$clean"

# --- Case 3: a real per-cell FAIL + non-zero exit → counted once -----------
reset_case; LOG="$(mktemp)"
printf 'MATRIX-CELL\tfoo.gguf\tchat\tPASS\n'                                >  "$LOG"
printf 'MATRIX-CELL\tfoo.gguf\ttree-of-thought\tFAIL\ttot: no tree\n'       >> "$LOG"
printf 'MATRIX-CELL\tfoo.gguf\tfast-think\tPASS\n'                          >> "$LOG"
aggregate_cell "org/foo.gguf" "foo.gguf" "$PROFILES" "$LOG" 1
once=0; [ "$overall_rc" -eq 1 ] && [ "$FAIL_COUNT" -eq 1 ] && [ "$PASS_COUNT" -eq 2 ] \
  && ! grep -q "despite PASS cells" "$SUMMARY" && once=1
check "1 FAIL cell + cell_rc=1 → counted once, no double-count via F1 guard" "$once"

# --- Case 4: no cells at all (engine never booted) + non-zero exit ---------
reset_case; LOG="$(mktemp)"; : > "$LOG"
aggregate_cell "org/foo.gguf" "foo.gguf" "$PROFILES" "$LOG" 2
nocell=0; [ "$overall_rc" -eq 1 ] && [ "$FAIL_COUNT" -eq 3 ] && [ "$PASS_COUNT" -eq 0 ] \
  && ! grep -q "despite PASS cells" "$SUMMARY" && nocell=1
check "no cells + cell_rc=2 → 3 FAIL(no-cell), no spurious 'despite' row" "$nocell"

# --- #483 hollow-green guard: recognized_profile_count --------------------
# The wrapper fails closed (exit 2) when the resolved profile set has zero
# recognized profiles. Drive the extracted counter with the values that slip
# past `${VAR:-default}`: non-empty but profile-free overrides.
prof_eq() {  # <desc> <csv> <expected-count>
  local got; got="$(recognized_profile_count "$2")"
  check "$1 → count=$3" "$([ "$got" = "$3" ] && echo 1 || echo 0)"
}
prof_eq "full default set"                "chat,tree-of-thought,fast-think" 3
prof_eq "single profile"                  "chat"                            1
prof_eq "whitespace-padded subset"        " chat , fast-think "             2
prof_eq "empty string (hollow green)"     ""                                0
prof_eq "whitespace-only (hollow green)"  "   "                             0
prof_eq "all-commas (hollow green)"       ",,,"                             0
prof_eq "only an unrecognized profile"    "bogus"                           0
prof_eq "one recognized among typos"      "chat,bogus"                      1

echo ""
[ "$rc" -eq 0 ] && echo "matrix-aggregator self-test: PASS" || echo "matrix-aggregator self-test: FAIL"
exit "$rc"
