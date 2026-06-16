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
#   4. OUT-OF-GLOB GUI DRIVERS — invariants 1-2 only enumerate run-*e2e.sh, so a
#      script that both names the GUI suite AND launches xcodebuild from outside
#      that glob would escape gating entirely. Any such driver must either follow
#      the run-*e2e.sh contract or be explicitly allow-listed as a deliberate
#      non-wrapper (the shared helper, a manual screenshot tool).
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

# Code-only view of a wrapper: strip `#` comments — whole-line AND trailing —
# so a doc line OR a trailing note that merely names PIE_TEST_TCC_GRANTED /
# `pgrep Dock` is not mistaken for a hand-rolled gate. The strip is QUOTE-AWARE:
# it walks each line tracking single/double-quote state and cuts only at a `#`
# that is (a) OUTSIDE quotes and (b) at a comment boundary (line start, or
# preceded by whitespace). A `#` inside a quoted string is kept verbatim.
#
# The same walk also NEUTRALISES a `;`/`&`/`|` that sits INSIDE a quoted string
# (replacing it with a space): such a char is string data, not a command
# separator, so CMD_ANCHOR must not treat it as a command boundary. Without this
# a gate token named inside `echo "…; e2e_require_tcc"` (or, with CMD_KW,
# `echo "…; then e2e_require_tcc"`) would anchor off the in-string separator and
# be mis-counted as a real CALL — the exact false-green this guard exists to stop.
#
# A blind `sed 's/[[:space:]]+#.*//'` cut is wrong here: it would truncate at the
# first whitespace-preceded `#` regardless of quoting, so a line like
#   [ "$x" = "a # b" ] && [ "$PIE_TEST_TCC_GRANTED" = 1 ]
# loses its gate-var expansion (the NEGATIVE rule false-greens a hand-rolled
# gate), and `log "step #3" && e2e_require_tcc "fix"` loses a real gate CALL (the
# POSITIVE rule false-fails) — net-new instances of the exact bug this guard
# exists to catch.
#
# awk succeeds on any readable file; a non-zero exit is a READ error (unreadable
# wrapper, chmod 000, vanished mid-scan). The old `|| true` swallowed that into
# an empty result, so an unreadable GUI wrapper was silently treated as gate-free
# and skipped. Propagate the failure (return rc) so the caller fails loudly.
code_lines() {
  local out rc
  out=$(awk -v SQ="'" -v DQ='"' '
    {
      s=0; d=0; res="";
      for (i=1; i<=length($0); i++) {
        c=substr($0,i,1);
        if (c==SQ && d==0)      { s=1-s }
        else if (c==DQ && s==0) { d=1-d }
        else if (c=="#" && s==0 && d==0) {
          p=(i==1)?"":substr($0,i-1,1);
          if (i==1 || p==" " || p=="\t") break;
        }
        else if ((c==";" || c=="&" || c=="|") && (s==1 || d==1)) {
          res=res " "; continue;   # in-quote separator → not a command boundary
        }
        res=res c;
      }
      print res;
    }
  ' "$1") && rc=0 || rc=$?
  if [ "$rc" -ne 0 ]; then return "$rc"; fi
  printf '%s\n' "$out"
}

# Signatures of a hand-rolled gate (must live ONLY in e2e-prep.sh).
SEATED_INLINE_RE='pgrep[[:space:]].*Dock'
TCC_INLINE_RE='\$\{?PIE_TEST_TCC_GRANTED'

# A wrapper drives the GUI suite if it names the test target or the shared
# xcodebuild helper.
GUI_WRAPPER_RE='RatioThinkGUITests|e2e_run_gui_xcodebuild'

# Command-position anchor: a token is a real CALL (not a mention inside an echo
# string or other argument) only when it begins a simple command — at line start
# after indentation, or right after a `;`, `&`, `|`, `&&`, or `||` separator. The
# positive rule matches the gate/source tokens through this anchor so a wrapper
# that merely NAMES both gates inside a string (e.g. `echo "needs
# e2e_require_tcc"`) without ever calling them no longer satisfies the rule.
#
# A command can also open with a shell test keyword and/or a `!` negation —
# `if ! e2e_require_seated_gui "tag"; then …` — which still places the gate at
# command position. The optional keyword/negation tail (CMD_KW) accepts that form
# so an if/!-guarded gate call is recognised; without it the positive rule would
# false-fail a wrapper that is in fact correctly gated (#692). The tail sits AFTER
# the line-start/separator base, so a gate token inside a string is still rejected:
# code_lines() neutralises in-quote `;`/`&`/`|` separators (and strips `#`), so an
# in-string mention — bare `echo "…; e2e_require_tcc"` OR keyword-bridged
# `echo "…; then e2e_require_tcc"` — has no command boundary left to anchor off.
CMD_KW='((if|elif|while|until|then|do|else)[[:space:]]+)?(![[:space:]]+)?'
CMD_ANCHOR="(^[[:space:]]*|[;&|][[:space:]]*|&&[[:space:]]*|\|\|[[:space:]]*)${CMD_KW}"
SOURCE_CALL_RE="${CMD_ANCHOR}(source|\.)[[:space:]]+[^#]*Scripts/e2e-prep\.sh"
SEATED_CALL_RE="${CMD_ANCHOR}e2e_require_seated_gui([[:space:]]|;|\$)"
TCC_CALL_RE="${CMD_ANCHOR}e2e_require_tcc([[:space:]]|;|\$)"

# grep over a code string via a here-string, never `echo "$code" | grep`: under
# `set -o pipefail` a `grep -q` that matches closes the pipe early, the upstream
# `echo` takes SIGPIPE (exit 141), and pipefail surfaces THAT as the pipeline
# status — flipping a real match to the false branch on any wrapper large enough
# for echo to still be writing. A here-string feeds grep from a temp fd with no
# upstream process, so the pipeline status is grep's own.
n_gui=0
for w in "${wrappers[@]}"; do
  rel="Scripts/$(basename "$w")"
  if ! code="$(code_lines "$w")"; then
    emit_fail "$rel could not be read (comment-strip failed) — an unreadable \
wrapper would otherwise be silently treated as gate-free and skipped, dropping \
its gating check. Fix its permissions/contents."
    continue
  fi

  # --- 2. NEGATIVE: no inline hand-rolled gate in ANY wrapper ---------------
  if grep -qE "$SEATED_INLINE_RE" <<<"$code"; then
    emit_fail "$rel hand-rolls the seated-GUI check (\`pgrep … Dock\`). Remove \
it and call e2e_require_seated_gui \"<tag>\" from Scripts/e2e-prep.sh instead."
  fi
  if grep -qE "$TCC_INLINE_RE" <<<"$code"; then
    emit_fail "$rel hand-rolls the TCC gate (expands \$PIE_TEST_TCC_GRANTED). \
Remove it and call e2e_require_tcc \"<tag>\" from Scripts/e2e-prep.sh instead."
  fi

  # --- 1. POSITIVE: GUI wrappers must source the helper + call both gates ----
  if grep -qE "$GUI_WRAPPER_RE" <<<"$code"; then
    n_gui=$((n_gui + 1))
    grep -qE "$SOURCE_CALL_RE" <<<"$code" || \
      emit_fail "$rel drives RatioThinkGUITests but never \`source\`s \
Scripts/e2e-prep.sh — it cannot reach the shared gates."
    grep -qE "$SEATED_CALL_RE" <<<"$code" || \
      emit_fail "$rel drives RatioThinkGUITests but never CALLS \
e2e_require_seated_gui — a headless/SSH run would launch XCUITest with no \
seated session and fail deep in the runner instead of preflighting."
    grep -qE "$TCC_CALL_RE" <<<"$code" || \
      emit_fail "$rel drives RatioThinkGUITests but never CALLS e2e_require_tcc \
— a run without Automation/Accessibility permission would fail mid-test with no \
remediation hint."
  fi
done

# --- 4. OUT-OF-GLOB GUI DRIVERS ----------------------------------------------
# Invariants 1-2 only see Scripts/run-*e2e.sh. A script that both names the GUI
# suite AND launches xcodebuild itself, yet lives outside that glob (an ad-hoc
# tool, a fragment-assembled name), escapes every gate check. Flag any such
# driver unless it is a known, deliberate non-wrapper.
GUI_DRIVE_RE="${CMD_ANCHOR}(xcodebuild|e2e_run_gui_xcodebuild)([[:space:]]|\$)"
# Allow-listed non-wrapper GUI drivers (leading/trailing spaces for word-match):
#   e2e-prep.sh                   — DEFINES the shared e2e_run_gui_xcodebuild helper
#   capture-readme-screenshots.sh — manual, non-CI screenshot tool (ungated by design)
#   test-lint-e2e-gui-gating.sh   — THIS guard's self-test; it emits driver fixtures
#                                   as string data, not a real GUI run (self-exclude,
#                                   mirroring lint-gui-only-testing.sh #666).
OUT_OF_GLOB_ALLOW=" e2e-prep.sh capture-readme-screenshots.sh test-lint-e2e-gui-gating.sh "
for f in "$SCRIPTS_DIR"/*.sh; do
  [ -f "$f" ] || continue
  base="$(basename "$f")"
  case "$base" in run-*e2e.sh) continue ;; esac          # covered by invariants 1-2
  case "$OUT_OF_GLOB_ALLOW" in *" $base "*) continue ;; esac
  if ! body="$(code_lines "$f")"; then
    emit_fail "Scripts/$base could not be read (comment-strip failed) — cannot \
verify whether it is an out-of-glob GUI driver. Fix its permissions/contents."
    continue
  fi
  grep -qE "$GUI_WRAPPER_RE" <<<"$body" || continue        # not GUI-related
  grep -qE "$GUI_DRIVE_RE"  <<<"$body" || continue         # names but doesn't drive
  emit_fail "Scripts/$base drives a GUI xcodebuild run (names the GUI suite + \
launches xcodebuild) but is not a Scripts/run-*e2e.sh wrapper and is not \
allow-listed, so invariants 1-2 never gate it. Rename it to Scripts/run-*e2e.sh \
(so it sources e2e-prep.sh + gates) or add it to OUT_OF_GLOB_ALLOW with a reason."
done

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "lint-e2e-gui-gating: OK — ${#wrappers[@]} run-*e2e.sh wrappers, ${n_gui} \
GUI wrappers all source e2e-prep.sh + gate via e2e_require_seated_gui/e2e_require_tcc, \
no inline Dock/TCC"
