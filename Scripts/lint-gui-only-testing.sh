#!/bin/bash
# Static guard for the RatioThinkGUITests `-only-testing` wiring (#666).
#
# Closes the #645 trap (insight:523): renaming a GUI suite leaves a dangling
# `-only-testing:RatioThinkGUITests/<Old>` ref that `xcodebuild` runs as ZERO
# tests and reports GREEN, while the renamed suite is wired nowhere in the
# focused path and silently stops running. Same failure shape as
# `swift test --filter` matching nothing.
#
# Two invariants over Tests/GUIScenarioTests/*.swift vs the focused
# `-only-testing` wiring in the Makefile + Scripts/*.sh:
#
#   1. DANGLING — every `-only-testing:RatioThinkGUITests/<Suite>` argument
#      must resolve to a real `class <Suite>: XCTestCase` on disk. A ref with
#      no matching suite runs 0 tests and false-greens.
#
#   2. ORPHAN — every GUI suite on disk must be reachable from the focused
#      path: either referenced as `RatioThinkGUITests/<Suite>` somewhere in
#      the Makefile/Scripts, OR explicitly declared full-matrix-only with an
#      in-file annotation (reason REQUIRED):
#
#        // gui-suite: full-matrix-only: <one-line reason>
#
#      `make test-gui` runs the ENTIRE matrix, so an unreferenced suite still
#      runs there — but the full matrix is slow/seated/local and is NOT the
#      routine runner, so a suite that falls out of every focused target
#      silently loses its day-to-day coverage. The annotation makes the
#      "runs only in the full matrix" decision EXPLICIT and rename-safe: a
#      future rename that drops a suite from its focused target without adding
#      the annotation fails this guard instead of vanishing.
#
# The reason text after the final colon is REQUIRED — a bare
# `// gui-suite: full-matrix-only` (no reason) does not pass, mirroring the
# `// lint:allow-side-effect: <reason>` contract in lint-helper-side-effects.sh.
set -euo pipefail

# ROOT defaults to the repo root (this script lives in Scripts/). The self-test
# (Scripts/test-lint-gui-only-testing.sh) overrides it via $LINT_GUI_ROOT to
# point at a synthetic fixture tree.
ROOT="${LINT_GUI_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

SUITE_DIR="$ROOT/Tests/GUIScenarioTests"
TEST_TARGET="RatioThinkGUITests"

# The guard's own source files name suites in comments/fixtures, so they must
# NOT be scanned as `-only-testing` wiring (they would inject phantom refs).
SELF="$(basename "$0")"
SELF_TEST="test-${SELF}"

fail=0
emit_fail() { echo "FAIL: $1" >&2; fail=1; }

if [ ! -d "$SUITE_DIR" ]; then
  echo "lint-gui-only-testing: no $SUITE_DIR — nothing to check"
  exit 0
fi

# --- 1. Enumerate GUI suites on disk (XCTestCase subclasses) ----------------
# Suite name in `-only-testing:<target>/<Suite>` IS the Swift class name.
disk_suites=""
disk_files=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  while IFS= read -r cls; do
    [ -n "$cls" ] || continue
    disk_suites="$disk_suites $cls"
    disk_files="$disk_files $cls:$f"
  done < <(grep -hoE '(final[[:space:]]+)?class[[:space:]]+[A-Za-z0-9_]+[[:space:]]*:[[:space:]]*XCTestCase' "$f" \
             | sed -E 's/.*class[[:space:]]+([A-Za-z0-9_]+).*/\1/')
done < <(find "$SUITE_DIR" -name '*.swift' | sort)

disk_suites="$(echo "$disk_suites" | tr ' ' '\n' | grep -v '^$' | sort -u)"

if [ -z "$disk_suites" ]; then
  echo "lint-gui-only-testing: no XCTestCase suites found under $SUITE_DIR — nothing to check"
  exit 0
fi

# --- 2. Collect the `-only-testing` wiring (Makefile + Scripts/*.sh) ---------
ref_sources=()
[ -f "$ROOT/Makefile" ] && ref_sources+=("$ROOT/Makefile")
if [ -d "$ROOT/Scripts" ]; then
  while IFS= read -r s; do
    case "$(basename "$s")" in
      "$SELF"|"$SELF_TEST") continue ;;  # never scan the guard's own files
    esac
    ref_sources+=("$s")
  done < <(find "$ROOT/Scripts" -maxdepth 1 -name '*.sh' | sort)
fi

# `only_testing_refs` = suites named in an actual `-only-testing:` argument
# (these are the ones that silently run 0 tests when stale → DANGLING check).
# `referenced` = any `<target>/<Suite>` mention (also catches a suite passed via
# a shell var default, e.g. READMESHOTS_ONLY) → ORPHAN coverage.
only_testing_refs=""
referenced=""
if [ ${#ref_sources[@]} -gt 0 ]; then
  only_testing_refs="$(grep -rhoE -- "-only-testing:\"?${TEST_TARGET}/[A-Za-z0-9_]+" "${ref_sources[@]}" 2>/dev/null \
    | sed -E "s#.*${TEST_TARGET}/##" | sort -u || true)"
  referenced="$(grep -rhoE -- "${TEST_TARGET}/[A-Za-z0-9_]+" "${ref_sources[@]}" 2>/dev/null \
    | sed -E "s#.*${TEST_TARGET}/##" | sort -u || true)"
fi

contains() { echo "$1" | grep -qxF "$2"; }

# --- 3. DANGLING: every `-only-testing` ref must resolve to a disk suite -----
while IFS= read -r ref; do
  [ -n "$ref" ] || continue
  if ! contains "$disk_suites" "$ref"; then
    emit_fail "dangling -only-testing ref: ${TEST_TARGET}/${ref} matches no \
'class ${ref}: XCTestCase' under Tests/GUIScenarioTests — xcodebuild would run \
0 tests and report GREEN. Update the ref to the suite's current name (renamed?) \
or remove it."
  fi
done < <(echo "$only_testing_refs")

# --- 4. ORPHAN: every disk suite is referenced OR annotated full-matrix-only -
# Required-reason annotation (bare marker w/o a reason does NOT satisfy it).
ANNOT_RE='//[[:space:]]*gui-suite:[[:space:]]*full-matrix-only:[[:space:]]*[^[:space:]]'
ANNOT_BARE_RE='//[[:space:]]*gui-suite:[[:space:]]*full-matrix-only'

file_for_suite() { echo "$disk_files" | tr ' ' '\n' | grep -E "^$1:" | head -1 | cut -d: -f2-; }

while IFS= read -r suite; do
  [ -n "$suite" ] || continue
  contains "$referenced" "$suite" && continue
  file="$(file_for_suite "$suite")"
  if [ -n "$file" ] && grep -qE "$ANNOT_RE" "$file"; then
    continue
  fi
  if [ -n "$file" ] && grep -qE "$ANNOT_BARE_RE" "$file"; then
    emit_fail "suite ${suite} carries a bare '// gui-suite: full-matrix-only' \
annotation with no reason — a reason after the final colon is REQUIRED."
    continue
  fi
  emit_fail "orphaned GUI suite: ${suite} is referenced by no \
'-only-testing:${TEST_TARGET}/...' in the Makefile/Scripts and is not declared \
full-matrix-only. Wire it into a focused 'make test-gui-*' target, or add \
'// gui-suite: full-matrix-only: <reason>' above its class to declare it runs \
only in the full 'make test-gui' matrix."
done < <(echo "$disk_suites")

if [ "$fail" -ne 0 ]; then
  exit 1
fi

n_disk="$(echo "$disk_suites" | grep -c . || true)"
echo "lint-gui-only-testing: OK — ${n_disk} GUI suites, all -only-testing refs resolve, no orphans"
