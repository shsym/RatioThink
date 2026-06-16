#!/bin/bash
# Self-test for lint-e2e-gui-gating.sh (#682). Drives the guard against
# synthetic fixture trees (a fake Scripts/ holding an e2e-prep.sh + run-*e2e.sh
# wrappers) and asserts it (a) passes a clean GUI/headless mix and (b) trips on
# each failure mode: a GUI wrapper that doesn't source the prep, omits either
# gate, or hand-rolls `pgrep Dock` / `$PIE_TEST_TCC_GRANTED`; plus the helper-
# integrity regressions. Mutation-proven: every PASS fixture has a FAIL twin one
# edit away, so a no-op guard would fail this self-test.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LINT="$ROOT/Scripts/lint-e2e-gui-gating.sh"

TMP=$(mktemp -d -t pie-lint-e2e-self-test.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

SCRIPTS_DIR="$TMP/Scripts"

reset_fixture() {
  rm -rf "$SCRIPTS_DIR"
  mkdir -p "$SCRIPTS_DIR"
  write_prep
}

# A minimal but faithful e2e-prep.sh: defines both gates and carries the
# rename-agnostic TCC phrase the guard checks for. $1, if "broken", drops a
# piece to exercise the helper-integrity invariant.
write_prep() {
  local mode="${1:-good}"
  {
    echo '#!/bin/bash'
    [ "$mode" != "no-seated" ] && cat <<'EOF'
e2e_require_seated_gui() {
  pgrep -x Dock >/dev/null 2>&1 || return 2
}
EOF
    if [ "$mode" != "no-tcc" ]; then
      echo 'e2e_require_tcc() {'
      if [ "$mode" = "no-phrase" ]; then
        echo '  [ "${PIE_TEST_TCC_GRANTED:-}" = "1" ] || { echo "permission needed" >&2; return 2; }'
      else
        echo '  [ "${PIE_TEST_TCC_GRANTED:-}" = "1" ] || { echo "Automation/Accessibility permission required" >&2; return 2; }'
      fi
      echo '}'
    fi
  } > "$SCRIPTS_DIR/e2e-prep.sh"
}

# Write a wrapper. $1=name (run-*e2e.sh), remaining args are extra body lines.
write_wrapper() {
  local name="$1"; shift
  {
    echo '#!/bin/bash'
    echo 'set -euo pipefail'
    echo 'ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"'
    local line
    for line in "$@"; do echo "$line"; done
  } > "$SCRIPTS_DIR/$name"
}

# Canonical clean GUI wrapper body lines.
GUI_SOURCE='source "$ROOT/Scripts/e2e-prep.sh"'
GUI_SEATED='e2e_require_seated_gui "fix"'
GUI_TCC='e2e_require_tcc "fix"'
# Bare RatioThinkGUITests token marks the wrapper as GUI for our detector.
# Deliberately NOT the `-only-testing:RatioThinkGUITests/<Suite>` form: that
# would look like a dangling suite ref to lint-gui-only-testing.sh (#666), which
# scans Scripts/*.sh and does not self-exclude this file.
GUI_DRIVE='echo "drives the RatioThinkGUITests scheme via xcodebuild"'

run() {
  local label="$1" expect="$2"; shift 2
  local output rc result
  set +e
  output=$(LINT_E2E_ROOT="$TMP" "$LINT" 2>&1); rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then result=PASS; else result=FAIL; fi
  if [ "$result" != "$expect" ]; then
    echo "SELF-TEST FAIL [$label]: expected $expect got $result (rc=$rc)"
    echo "--- guard output:"; echo "$output"
    echo "--- Scripts dir:"; ls -1 "$SCRIPTS_DIR"
    exit 1
  fi
  echo "ok   [$label] $result"
}

# 1. Clean: a GUI wrapper (sources prep + both gates + drives the suite) plus a
#    headless wrapper that needs no gate → PASS.
reset_fixture
write_wrapper "run-chat-gui-e2e.sh" "$GUI_SOURCE" "$GUI_SEATED" "$GUI_TCC" "$GUI_DRIVE"
write_wrapper "run-http-e2e.sh" 'curl -s localhost:8000/v1/models'
run "clean GUI + headless mix" PASS

# 2. GUI wrapper missing the source line → FAIL.
reset_fixture
write_wrapper "run-chat-gui-e2e.sh" "$GUI_SEATED" "$GUI_TCC" "$GUI_DRIVE"
run "GUI wrapper does not source e2e-prep" FAIL

# 3. GUI wrapper missing e2e_require_seated_gui → FAIL.
reset_fixture
write_wrapper "run-chat-gui-e2e.sh" "$GUI_SOURCE" "$GUI_TCC" "$GUI_DRIVE"
run "GUI wrapper omits seated-gui gate" FAIL

# 4. GUI wrapper missing e2e_require_tcc → FAIL.
reset_fixture
write_wrapper "run-chat-gui-e2e.sh" "$GUI_SOURCE" "$GUI_SEATED" "$GUI_DRIVE"
run "GUI wrapper omits tcc gate" FAIL

# 5. Wrapper hand-rolls the seated check (`pgrep -x Dock`) → FAIL, even though
#    it also calls the helpers (the inline copy is the regression).
reset_fixture
write_wrapper "run-chat-gui-e2e.sh" "$GUI_SOURCE" "$GUI_SEATED" "$GUI_TCC" \
  'pgrep -x Dock >/dev/null || exit 2' "$GUI_DRIVE"
run "inline pgrep Dock seated check" FAIL

# 6. Wrapper hand-rolls the TCC gate (expands $PIE_TEST_TCC_GRANTED) → FAIL.
reset_fixture
write_wrapper "run-chat-gui-e2e.sh" "$GUI_SOURCE" "$GUI_SEATED" "$GUI_TCC" \
  '[ "${PIE_TEST_TCC_GRANTED:-}" = "1" ] || exit 2' "$GUI_DRIVE"
run "inline PIE_TEST_TCC_GRANTED expansion" FAIL

# 7. A bare DOC mention of PIE_TEST_TCC_GRANTED in a comment/usage block (no
#    shell expansion) must NOT trip the negative rule → PASS. Guards against the
#    real-tree false positive (run-resume / run-first-launch usage blocks).
reset_fixture
write_wrapper "run-chat-gui-e2e.sh" \
  '# Usage: PIE_TEST_TCC_GRANTED=1 Scripts/run-chat-gui-e2e.sh' \
  "$GUI_SOURCE" "$GUI_SEATED" "$GUI_TCC" "$GUI_DRIVE"
run "doc mention of PIE_TEST_TCC_GRANTED ignored" PASS

# 8. A headless wrapper (no RatioThinkGUITests / e2e_run_gui_xcodebuild ref) is
#    NOT required to gate → PASS even with no source/gate lines.
reset_fixture
write_wrapper "run-engine-e2e.sh" 'echo "pie serve --headless"'
run "headless wrapper not required to gate" PASS

# 9. GUI wrapper detected via e2e_run_gui_xcodebuild (not the literal target
#    name) is still held to the positive rule → FAIL when it omits a gate.
reset_fixture
write_wrapper "run-copy-gui-e2e.sh" "$GUI_SOURCE" "$GUI_SEATED" \
  'e2e_run_gui_xcodebuild "$LOG" test'
run "GUI detected via e2e_run_gui_xcodebuild, missing tcc" FAIL

# 10. Helper integrity: e2e-prep.sh drops e2e_require_seated_gui → FAIL.
reset_fixture
write_prep "no-seated"
write_wrapper "run-http-e2e.sh" 'echo headless'
run "e2e-prep missing e2e_require_seated_gui def" FAIL

# 11. Helper integrity: e2e-prep.sh drops e2e_require_tcc → FAIL.
reset_fixture
write_prep "no-tcc"
write_wrapper "run-http-e2e.sh" 'echo headless'
run "e2e-prep missing e2e_require_tcc def" FAIL

# 12. Helper integrity: e2e_require_tcc loses the rename-agnostic phrase → FAIL.
reset_fixture
write_prep "no-phrase"
write_wrapper "run-http-e2e.sh" 'echo headless'
run "e2e-prep tcc lost rename-agnostic phrase" FAIL

echo "lint-e2e-gui-gating self-test: all scenarios pass"
