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

# A GUI wrapper whose code body is far larger than a pipe buffer (~64KB), with
# the GUI signature near the top and a gate (tcc) deliberately omitted. Under the
# old `echo "$code" | grep -q` the early GUI match SIGPIPEs the echo mid-write
# and pipefail flips the GUI detection to false, so the missing-gate check is
# skipped and the wrapper false-greens. The here-string fix must still flag it.
write_large_gui_wrapper_missing_tcc() {
  local name="$1"
  {
    echo '#!/bin/bash'
    echo 'set -euo pipefail'
    echo 'ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"'
    echo "$GUI_SOURCE"
    echo "$GUI_SEATED"
    echo "$GUI_DRIVE"   # RatioThinkGUITests signature near the top
    # ~240KB of non-comment filler (survives the comment strip) after the match.
    awk 'BEGIN{for(i=0;i<6000;i++) printf ": filler %06d aaaaaaaaaaaaaaaaaaaaaaaaaaaa\n", i}'
  } > "$SCRIPTS_DIR/$name"
}

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

# 13. FC1: a GUI wrapper larger than a pipe buffer, missing the tcc gate. The
#     here-string fix must still detect it as GUI and flag the missing gate;
#     the old echo|grep SIGPIPEs and false-greens → expect FAIL.
reset_fixture
write_large_gui_wrapper_missing_tcc "run-chat-gui-e2e.sh"
run "large GUI wrapper missing tcc still flagged (no SIGPIPE false-green)" FAIL

# 14. FC1 twin: the same large wrapper WITH all three gates present → PASS,
#     proving the here-string path doesn't spuriously fail big wrappers.
reset_fixture
{
  echo '#!/bin/bash'; echo 'set -euo pipefail'
  echo 'ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"'
  echo "$GUI_SOURCE"; echo "$GUI_SEATED"; echo "$GUI_TCC"; echo "$GUI_DRIVE"
  awk 'BEGIN{for(i=0;i<6000;i++) printf ": filler %06d aaaaaaaaaaaaaaaaaaaaaaaaaaaa\n", i}'
} > "$SCRIPTS_DIR/run-chat-gui-e2e.sh"
run "large GUI wrapper with all gates passes" PASS

# 15. FC2: an unreadable GUI wrapper must fail loudly, not be silently skipped as
#     gate-free (the old `|| true` swallowed grep rc>=2). Skipped under root,
#     which can read a chmod-000 file.
if [ "$(id -u)" -ne 0 ]; then
  reset_fixture
  write_wrapper "run-chat-gui-e2e.sh" "$GUI_SOURCE" "$GUI_SEATED" "$GUI_TCC" "$GUI_DRIVE"
  chmod 000 "$SCRIPTS_DIR/run-chat-gui-e2e.sh"
  run "unreadable GUI wrapper fails loudly" FAIL
  chmod 644 "$SCRIPTS_DIR/run-chat-gui-e2e.sh"
else
  echo "ok   [unreadable GUI wrapper] SKIP (running as root reads any file)"
fi

# 16. FC2: a TRAILING comment that merely names $PIE_TEST_TCC_GRANTED on a code
#     line must be stripped, not mistaken for a hand-rolled gate → PASS. Old
#     whole-line-only strip left the trailing mention and false-tripped → FAIL.
reset_fixture
write_wrapper "run-chat-gui-e2e.sh" "$GUI_SOURCE" "$GUI_SEATED" "$GUI_TCC" "$GUI_DRIVE" \
  'echo hi  # historically gated on $PIE_TEST_TCC_GRANTED before e2e-prep.sh'
run "trailing-comment mention of gate var ignored" PASS

# 17. FC2 twin: a REAL inline gate followed by a trailing comment is still
#     flagged — the comment strip removes the note but leaves `pgrep -x Dock`.
reset_fixture
write_wrapper "run-chat-gui-e2e.sh" "$GUI_SOURCE" "$GUI_SEATED" "$GUI_TCC" \
  'pgrep -x Dock >/dev/null || exit 2  # inline seated check, should be flagged' "$GUI_DRIVE"
run "inline gate with trailing comment still flagged" FAIL

# 17a. F1: the comment strip is QUOTE-AWARE. A hand-rolled gate whose line carries
#      a quoted `#` BEFORE the gate expansion must still be flagged — a blind
#      ` #…` cut would truncate at the quoted `#`, drop $PIE_TEST_TCC_GRANTED, and
#      false-green the negative rule.
reset_fixture
write_wrapper "run-chat-gui-e2e.sh" "$GUI_SOURCE" "$GUI_SEATED" "$GUI_TCC" \
  '[ "$mode" = "x # y" ] && [ "$PIE_TEST_TCC_GRANTED" = "1" ] || exit 2' "$GUI_DRIVE"
run "hand-rolled gate behind quoted # still flagged (negative rule)" FAIL

# 17b. F1 twin: a COMPLIANT wrapper whose gate CALL follows a quoted `#` on the
#      same line must not false-fail — a blind cut would drop the `&& e2e_require_tcc`
#      call and trip the positive rule.
reset_fixture
write_wrapper "run-chat-gui-e2e.sh" "$GUI_SOURCE" "$GUI_SEATED" \
  'echo "step #3 done" && e2e_require_tcc "fix"' "$GUI_DRIVE"
run "compliant gate call behind quoted # not false-failed" PASS

# 18. FC3: a GUI wrapper that NAMES both gates only inside an echo string, never
#     calling them, must FAIL — the call-anchored positive rule rejects the
#     mention. The old unanchored token match false-greened it → expect FAIL.
reset_fixture
# Both gate tokens are followed by whitespace inside the string, so an UNanchored
# token match would false-green; only the command-position anchor rejects them.
write_wrapper "run-chat-gui-e2e.sh" "$GUI_SOURCE" \
  'echo "would call e2e_require_seated_gui then e2e_require_tcc here"' "$GUI_DRIVE"
run "gates named only inside a string, never called" FAIL

# 19. FC4: an out-of-glob script (not run-*e2e.sh, not allow-listed) that both
#     names the GUI suite and drives e2e_run_gui_xcodebuild → FAIL.
reset_fixture
write_wrapper "run-chat-gui-e2e.sh" "$GUI_SOURCE" "$GUI_SEATED" "$GUI_TCC" "$GUI_DRIVE"
write_wrapper "gui-screenshot.sh" 'e2e_run_gui_xcodebuild "$LOG" test'
run "out-of-glob GUI driver flagged" FAIL

# 20. FC4 twin: an out-of-glob script that only MENTIONS the suite without
#     launching xcodebuild is not a driver → PASS (no false positive on helpers,
#     linters, self-tests that merely reference the token).
reset_fixture
write_wrapper "run-chat-gui-e2e.sh" "$GUI_SOURCE" "$GUI_SEATED" "$GUI_TCC" "$GUI_DRIVE"
write_wrapper "gui-notes.sh" 'echo "see the RatioThinkGUITests scheme docs"'
run "out-of-glob mention without xcodebuild not flagged" PASS

# 21. FC4: e2e-prep.sh DEFINES the shared e2e_run_gui_xcodebuild helper (a
#     command-position xcodebuild) — a GUI driver by signature, but the canonical
#     allow-listed non-wrapper → PASS. Proves the allow-list is load-bearing:
#     dropping it would flag the very helper every wrapper sources.
reset_fixture
{
  echo '#!/bin/bash'
  echo 'e2e_require_seated_gui() { pgrep -x Dock >/dev/null 2>&1 || return 2; }'
  echo 'e2e_require_tcc() { [ "${PIE_TEST_TCC_GRANTED:-}" = "1" ] || { echo "Automation/Accessibility permission required" >&2; return 2; }; }'
  echo 'e2e_run_gui_xcodebuild() { local log="$1"; shift; xcodebuild "$@" 2>&1 | tee "$log"; }'
} > "$SCRIPTS_DIR/e2e-prep.sh"
write_wrapper "run-chat-gui-e2e.sh" "$GUI_SOURCE" "$GUI_SEATED" "$GUI_TCC" "$GUI_DRIVE"
run "allow-listed e2e-prep driver not flagged" PASS

echo "lint-e2e-gui-gating self-test: all scenarios pass"
