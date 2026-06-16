#!/bin/bash
# Self-test for lint-gui-only-testing.sh (#666). Drives the guard against
# synthetic fixture trees (a fake Tests/GUIScenarioTests + Makefile + Scripts)
# and asserts it (a) passes clean wiring and (b) trips on each failure mode:
# dangling -only-testing ref, orphaned suite, and a full-matrix-only annotation
# missing its required reason. Mutation-proven: every PASS fixture has a FAIL
# twin one edit away, so a no-op guard would fail this self-test.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LINT="$ROOT/Scripts/lint-gui-only-testing.sh"

TMP=$(mktemp -d -t pie-lint-gui-self-test.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

SUITE_DIR="$TMP/Tests/GUIScenarioTests"

reset_fixture() {
  rm -rf "$TMP/Tests" "$TMP/Makefile" "$TMP/Scripts"
  mkdir -p "$SUITE_DIR" "$TMP/Scripts"
  : > "$TMP/Makefile"
}

# Write a GUI suite file. $1=ClassName, $2=optional extra line placed ABOVE the
# class decl (e.g. a full-matrix-only annotation).
write_suite() {
  local cls="$1" annot="${2:-}"
  {
    echo "import XCTest"
    [ -n "$annot" ] && echo "$annot"
    echo "final class ${cls}: XCTestCase {"
    echo "  func test_x() {}"
    echo "}"
  } > "$SUITE_DIR/${cls}.swift"
}

makefile_ref() { echo "	xcodebuild -only-testing:RatioThinkGUITests/$1 test" >> "$TMP/Makefile"; }

run() {
  local label="$1" expect="$2"; shift 2
  local output rc result
  set +e
  output=$(LINT_GUI_ROOT="$TMP" "$LINT" 2>&1); rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then result=PASS; else result=FAIL; fi
  if [ "$result" != "$expect" ]; then
    echo "SELF-TEST FAIL [$label]: expected $expect got $result (rc=$rc)"
    echo "--- guard output:"; echo "$output"
    echo "--- suite dir:"; ls -1 "$SUITE_DIR"
    echo "--- Makefile:"; cat "$TMP/Makefile"
    exit 1
  fi
  echo "ok   [$label] $result"
}

# 1. Clean: suite referenced via -only-testing → PASS.
reset_fixture
write_suite "S1_AlphaGUITests"
makefile_ref "S1_AlphaGUITests"
run "clean referenced suite" PASS

# 2. Dangling: ref to a suite that does NOT exist on disk → FAIL (the #645 bug).
reset_fixture
write_suite "S2_RenamedGUITests"          # disk has the NEW name
makefile_ref "S2_OldNameGUITests"         # ref still points at the OLD name
run "dangling -only-testing ref" FAIL

# 3. Orphan: disk suite with no ref and no annotation → FAIL.
reset_fixture
write_suite "S3_OrphanGUITests"
run "orphan suite (no ref, no annotation)" FAIL

# 4. Orphan resolved by full-matrix-only annotation (with reason) → PASS.
reset_fixture
write_suite "S4_FullMatrixGUITests" "// gui-suite: full-matrix-only: deterministic, runs in the full matrix"
run "full-matrix-only annotation with reason" PASS

# 5. Bare annotation without a reason → FAIL (reason is required).
reset_fixture
write_suite "S5_BareGUITests" "// gui-suite: full-matrix-only"
run "full-matrix-only annotation missing reason" FAIL

# 6. Referenced via a shell-var default literal in Scripts/*.sh → PASS
#    (covers the ReadmeScreenshots READMESHOTS_ONLY mechanism, no -only-testing).
reset_fixture
write_suite "S6_ScreenshotGUITests"
echo 'ONLY="${OVERRIDE:-RatioThinkGUITests/S6_ScreenshotGUITests}"' > "$TMP/Scripts/shots.sh"
run "suite wired via shell-var default literal" PASS

# 7. Ref carrying a /method suffix and quotes still resolves to the suite → PASS.
reset_fixture
write_suite "S7_MethodGUITests"
echo '	xcodebuild -only-testing:"RatioThinkGUITests/S7_MethodGUITests/test_x" test' >> "$TMP/Makefile"
run "quoted ref with /method suffix" PASS

# 8. A non-XCTestCase helper class in the suite dir must NOT be treated as a
#    suite (no false orphan) while the real suite is still enforced.
reset_fixture
write_suite "S8_RealGUITests"
makefile_ref "S8_RealGUITests"
cat > "$SUITE_DIR/Helpers.swift" <<'EOF'
import XCTest
final class GUIHelpersBox { func noop() {} }
EOF
run "non-XCTestCase helper class ignored" PASS

# 9. The guard's OWN files (Scripts/lint-gui-only-testing.sh and this self-test)
#    name suites in fixtures/comments; scanning them as wiring would inject
#    phantom refs. Here the self-test FILE mentions the on-disk orphan's exact
#    `RatioThinkGUITests/S9_SelfRefGUITests` literal — without self-exclusion the
#    guard would count that mention and wrongly mark the suite referenced (PASS).
#    Self-exclusion drops the guard's own files from the scan, so the suite stays
#    an orphan → FAIL. (Flip the exclusion off and this scenario flips to PASS,
#    proving the assertion is load-bearing.)
reset_fixture
write_suite "S9_SelfRefGUITests"
echo '# example wiring: RatioThinkGUITests/S9_SelfRefGUITests' \
  > "$TMP/Scripts/test-lint-gui-only-testing.sh"
run "guard self-files excluded from ref scan" FAIL

echo "lint-gui-only-testing self-test: all scenarios pass"
