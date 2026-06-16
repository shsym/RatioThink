#!/bin/bash
# Static guard for the GUI/real-model E2E wrapper gating discipline (#682,
# insight:557; follow-up to #675).
#
# Every seated GUI E2E run needs two prerequisites that cannot be auto-granted:
# a logged-in window-server session (Dock running) and TCC Automation/
# Accessibility permission for the app + XCTest runner. Scripts/e2e-prep.sh
# owns these as e2e_require_seated_gui / e2e_require_tcc with a single,
# rename-agnostic error surface. The trap this guard closes: a wrapper that
# hand-rolls `pgrep -x Dock` or an `if [ "$PIE_TEST_TCC_GRANTED" != 1 ]` block
# inline. Such a copy silently drifts from the shared helper — it skips the
# remediation text, breaks on the next app rename (#445 Rational rebrand), or
# (worse) a half-applied refactor drops the gate entirely and the run launches
# XCUITest with no seated session, failing deep inside the runner with a
# misleading post-mortem instead of a clean "no seated GUI session" preflight.
#
# Invariants:
#
#   1. POSITIVE (GUI wrappers) — every Scripts/run-*e2e.sh that drives the
#      RatioThinkGUITests xcodebuild suite MUST `source` Scripts/e2e-prep.sh and
#      call BOTH e2e_require_seated_gui and e2e_require_tcc. A GUI wrapper is one
#      that references `RatioThinkGUITests` or calls `e2e_run_gui_xcodebuild`.
#
#   2. NEGATIVE (all wrappers) — NO Scripts/run-*e2e.sh may hand-roll the gate:
#      no `pgrep ... Dock` seated check, no `$PIE_TEST_TCC_GRANTED` /
#      `${PIE_TEST_TCC_GRANTED...}` parameter expansion (reading the var to gate
#      is the helper's job). Bare doc mentions like `PIE_TEST_TCC_GRANTED=1` in
#      a comment/usage block are fine — only a shell expansion of the value is
#      the hand-rolled-gate signature.
#
#   3. HELPER INTEGRITY — Scripts/e2e-prep.sh must still DEFINE both helpers,
#      and e2e_require_tcc must keep the rename-agnostic substring
#      "Automation/Accessibility permission required" so a future app rename
#      can't silently gut the remediation message (insight:557).
#
# Mirrors the contract style of Scripts/lint-gui-only-testing.sh (#666) and
# Scripts/lint-helper-side-effects.sh. Self-test: Scripts/test-lint-e2e-gui-gating.sh.
set -euo pipefail

# ROOT defaults to the repo root (this script lives in Scripts/). The self-test
# overrides it via $LINT_E2E_ROOT to point at a synthetic fixture tree.
ROOT="${LINT_E2E_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

SCRIPTS_DIR="$ROOT/Scripts"
PREP="$SCRIPTS_DIR/e2e-prep.sh"

fail=0
emit_fail() { echo "FAIL: $1" >&2; fail=1; }

if [ ! -d "$SCRIPTS_DIR" ]; then
  echo "lint-e2e-gui-gating: no $SCRIPTS_DIR — nothing to check"
  exit 0
fi

# --- 0. Helper integrity: e2e-prep.sh defines both gates + keeps the rename- --
#        agnostic TCC remediation phrase.
if [ ! -f "$PREP" ]; then
  emit_fail "Scripts/e2e-prep.sh missing — GUI wrappers have no shared gate to \
source. Restore it (it owns e2e_require_seated_gui / e2e_require_tcc)."
else
  grep -qE '^[[:space:]]*e2e_require_seated_gui[[:space:]]*\(\)' "$PREP" || \
    emit_fail "Scripts/e2e-prep.sh no longer defines e2e_require_seated_gui() — \
the seated-GUI gate every wrapper sources is gone."
  grep -qE '^[[:space:]]*e2e_require_tcc[[:space:]]*\(\)' "$PREP" || \
    emit_fail "Scripts/e2e-prep.sh no longer defines e2e_require_tcc() — the \
TCC-permission gate every wrapper sources is gone."
  grep -qF 'Automation/Accessibility permission required' "$PREP" || \
    emit_fail "Scripts/e2e-prep.sh: e2e_require_tcc lost the rename-agnostic \
substring 'Automation/Accessibility permission required'. Keep it app-name-free \
so the remediation survives an app rename (insight:557)."
fi

# --- enumerate the wrappers in scope -----------------------------------------
wrappers=()
while IFS= read -r w; do
  wrappers+=("$w")
done < <(find "$SCRIPTS_DIR" -maxdepth 1 -name 'run-*e2e.sh' | sort)

if [ ${#wrappers[@]} -eq 0 ]; then
  echo "lint-e2e-gui-gating: no Scripts/run-*e2e.sh wrappers — nothing to check"
  [ "$fail" -ne 0 ] && exit 1
  exit 0
fi

# Code-only view of a wrapper: drop whole-line `#` comments so a doc line that
# merely names PIE_TEST_TCC_GRANTED (usage block) is not mistaken for a gate.
# A real hand-rolled gate is a shell EXPANSION of the var, which survives this.
# `|| true`: grep -v exits 1 when EVERY line is a comment (no code lines), which
# under the wrapper's `set -e` would abort the command substitution below.
code_lines() { grep -vE '^[[:space:]]*#' "$1" || true; }

# Signatures of a hand-rolled gate (must live ONLY in e2e-prep.sh).
SEATED_INLINE_RE='pgrep[[:space:]].*Dock'
TCC_INLINE_RE='\$\{?PIE_TEST_TCC_GRANTED'

# A wrapper drives the GUI suite if it names the test target or the shared
# xcodebuild helper.
GUI_WRAPPER_RE='RatioThinkGUITests|e2e_run_gui_xcodebuild'

n_gui=0
for w in "${wrappers[@]}"; do
  rel="Scripts/$(basename "$w")"
  code="$(code_lines "$w")"

  # --- 2. NEGATIVE: no inline hand-rolled gate in ANY wrapper ---------------
  if echo "$code" | grep -qE "$SEATED_INLINE_RE"; then
    emit_fail "$rel hand-rolls the seated-GUI check (\`pgrep … Dock\`). Remove \
it and call e2e_require_seated_gui \"<tag>\" from Scripts/e2e-prep.sh instead."
  fi
  if echo "$code" | grep -qE "$TCC_INLINE_RE"; then
    emit_fail "$rel hand-rolls the TCC gate (expands \$PIE_TEST_TCC_GRANTED). \
Remove it and call e2e_require_tcc \"<tag>\" from Scripts/e2e-prep.sh instead."
  fi

  # --- 1. POSITIVE: GUI wrappers must source the helper + call both gates ----
  if echo "$code" | grep -qE "$GUI_WRAPPER_RE"; then
    n_gui=$((n_gui + 1))
    echo "$code" | grep -qE 'source[[:space:]].*Scripts/e2e-prep\.sh' || \
      emit_fail "$rel drives RatioThinkGUITests but never \`source\`s \
Scripts/e2e-prep.sh — it cannot reach the shared gates."
    echo "$code" | grep -qE 'e2e_require_seated_gui([[:space:]]|$)' || \
      emit_fail "$rel drives RatioThinkGUITests but never calls \
e2e_require_seated_gui — a headless/SSH run would launch XCUITest with no \
seated session and fail deep in the runner instead of preflighting."
    echo "$code" | grep -qE 'e2e_require_tcc([[:space:]]|$)' || \
      emit_fail "$rel drives RatioThinkGUITests but never calls e2e_require_tcc \
— a run without Automation/Accessibility permission would fail mid-test with no \
remediation hint."
  fi
done

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "lint-e2e-gui-gating: OK — ${#wrappers[@]} run-*e2e.sh wrappers, ${n_gui} \
GUI wrappers all source e2e-prep.sh + gate via e2e_require_seated_gui/e2e_require_tcc, \
no inline Dock/TCC"
