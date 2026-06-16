#!/bin/bash
# Shared environment-prep helpers for the GUI/real-model E2E wrappers
#. Source this from a wrapper running under `set -euo
# pipefail`:
#
#   source "$ROOT/Scripts/e2e-prep.sh"
#   e2e_require_seated_gui "myscenario"
#   e2e_require_tcc        "myscenario"
#   e2e_require_chat_apc   "$ROOT" "myscenario"
#   PIE_BIN="$(e2e_ensure_pie "$ROOT" "myscenario")"
#
# (GGUF GUI-test fixtures are staged via Scripts/stage-test-model.sh, not a
# helper here — see that script's self-bootstrap-or-guide contract.)
#
# Each `ensure_*` either satisfies the prerequisite (building / downloading
# when cheap+safe) or prints the exact command to fix it and returns
# non-zero so the caller can `exit`. Set PIE_E2E_AUTOPREP=0 to turn the
# build/download off (verify-only) for deterministic CI.

# --- gates that cannot be auto-satisfied (need a human / seated session) ---

e2e_require_seated_gui() {
  local tag="$1"
  if ! pgrep -x Dock >/dev/null 2>&1; then
    echo "$tag: no seated GUI session detected (Dock not running)." >&2
    echo "$tag: run from the Mac console or a connected Screen Sharing session." >&2
    return 2
  fi
}

e2e_require_tcc() {
  local tag="$1"
  if [ "${PIE_TEST_TCC_GRANTED:-}" != "1" ]; then
    echo "$tag: Rational.app + XCTest-runner Automation/Accessibility permission required (cannot be auto-granted)." >&2
    echo "$tag: 1) System Settings → Privacy & Security → Accessibility AND Automation → enable Xcode + the test runner." >&2
    echo "$tag:    Open it with: open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility'" >&2
    echo "$tag: 2) Re-run with PIE_TEST_TCC_GRANTED=1 prefixed." >&2
    return 2
  fi
}

e2e_require_chat_apc() {
  local root="$1" tag="$2"
  if [ ! -f "$root/Inferlets/chat-apc/prebuilt/chat-apc.wasm" ] \
     || [ ! -f "$root/Inferlets/chat-apc/Pie.toml" ]; then
    echo "$tag: chat-apc prebuilt wasm or manifest missing (committed artifact)." >&2
    echo "$tag: restore it with: git -C \"$root\" checkout -- Inferlets/chat-apc/" >&2
    return 2
  fi
}

# --- uniform xcodebuild log capture + testmanagerd-wedge post-mortem --------
#
# Every GUI/E2E wrapper launches a focused RatioThinkGUITests suite under
# xcodebuild. When that run dies at runner-init with "Timed out while enabling
# automation mode", the build and tests compiled fine — it's a wedged
# `testmanagerd`, not a code regression (insight:489). This helper gives every
# wrapper ONE way to (1) stream xcodebuild output live AND capture it to <log>,
# (2) recover its REAL exit status (PIPESTATUS[0], never tee's), and (3) on
# failure scan the captured log for that wedge and print the bounce remedy
# (Scripts/gui-testmanagerd-hint.sh — always exits 0, advisory only). The
# caller keeps its own post-run assertions (skip/pass-line greps, DB checks,
# sha256, termination classification) and decides what to do with the status.
#
#   set +e
#   e2e_run_gui_xcodebuild "$XCODE_LOG" \
#     -project RatioThink.xcodeproj -scheme RatioThinkGUITests \
#     -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO \
#     test -only-testing:... ENABLE_CODE_COVERAGE=NO
#   status=$?
#   set -e
e2e_run_gui_xcodebuild() {
  local log="$1"; shift
  local rc
  xcodebuild "$@" 2>&1 | tee "$log"
  rc=${PIPESTATUS[0]}
  # Resolve the detector relative to THIS lib, not the caller's cwd, so it
  # works no matter where the wrapper is invoked from.
  [ "$rc" -ne 0 ] && "$(dirname "${BASH_SOURCE[0]}")/gui-testmanagerd-hint.sh" "$log"
  return "$rc"
}

# --- prerequisites that auto-prep can satisfy ---

# Echo a runnable pie binary path on stdout; logs to stderr. Resolves an
# existing build (explicit $PIE_BIN, triple path, or no-triple path); if
# none and autoprep is on, builds via `make engine-build`.
e2e_ensure_pie() {
  local root="$1" tag="$2"
  # Build output lands at the triple path or the no-triple path depending on
  # whether the build pins --target; accept either, both before and after
  # building (the post-build re-scan must mirror this list, not hardcode one).
  local built_candidates=(
    "$root/Vendor/pie/target/aarch64-apple-darwin/release/pie"
    "$root/Vendor/pie/target/release/pie"
  )
  local candidates=("${PIE_BIN:-}" "${built_candidates[@]}")
  local c
  for c in "${candidates[@]}"; do
    if [ -n "$c" ] && [ -x "$c" ]; then
      echo "$c"
      return 0
    fi
  done
  if [ "${PIE_E2E_AUTOPREP:-1}" != "1" ]; then
    echo "$tag: pie engine binary missing and autoprep disabled. Build: make engine-build" >&2
    return 1
  fi
  echo "$tag: pie engine binary not found — building (make engine-build), one-time, minutes…" >&2
  if make -C "$root" engine-build >&2; then
    for c in "${built_candidates[@]}"; do
      if [ -x "$c" ]; then
        echo "$c"
        return 0
      fi
    done
  fi
  echo "$tag: failed to build pie. Build manually: make engine-build (needs cargo on PATH)." >&2
  return 1
}

# --- crash-reporter suppression + termination-source classification --------
#
# These run in the unsandboxed wrapper, so unlike the XCTRunner (app-sandbox=
# true — can't read DiagnosticReports or exec pgrep) they can see crash reports
# and the live process tree. That makes the wrapper the right boundary to
# classify why Rational.app disappeared during a GUI/E2E run (#545; cf. insight
# #263 "classify GUI failures by harness boundary"). The shipped product is
# `Rational`/`RationalHelper` (#445 rebrand); the names below mirror the crash-
# report set Scripts/collect-diagnostics.sh greps (incl. the RatioThink compat
# window).

# Mark the current wall-clock as the run-start reference for
# `e2e_classify_app_termination` (crash reports older than this belong to a
# previous run and are ignored). Echoes the epoch; callers capture it.
e2e_run_start_epoch() { date +%s; }

# Suppress the macOS "Rational quit unexpectedly" CrashReporter modal for an
# unattended run. A genuine app crash mid-test would otherwise pop a window
# that wedges a headless/seated CI box forever (#545 / #549). Crash reports are
# still written (so classification below still works) — only the blocking
# dialog is muted. The prior DialogType is saved and restored by
# `e2e_restore_crash_reporter` so we never leave the session permanently muted.
e2e_silence_crash_reporter() {
  local tag="${1:-e2e}"
  E2E_CRASHREPORTER_PRIOR="$(defaults read com.apple.CrashReporter DialogType 2>/dev/null || echo __unset__)"
  defaults write com.apple.CrashReporter DialogType none >/dev/null 2>&1 || true
  echo "$tag: CrashReporter dialog muted for this run (prior DialogType: $E2E_CRASHREPORTER_PRIOR)" >&2
}

# Restore the DialogType captured by e2e_silence_crash_reporter. Idempotent;
# safe to call from a wrapper's cleanup/trap even if silence was never called.
e2e_restore_crash_reporter() {
  [ -n "${E2E_CRASHREPORTER_PRIOR:-}" ] || return 0
  if [ "$E2E_CRASHREPORTER_PRIOR" = "__unset__" ]; then
    defaults delete com.apple.CrashReporter DialogType >/dev/null 2>&1 || true
  else
    defaults write com.apple.CrashReporter DialogType "$E2E_CRASHREPORTER_PRIOR" >/dev/null 2>&1 || true
  fi
  E2E_CRASHREPORTER_PRIOR=""
}

# Classify why Rational.app / RationalHelper / the pie engine terminated, so a
# GUI/E2E failure reports the SOURCE instead of only "app gone". Pure
# diagnostic — always returns 0, only prints to stderr. Distinguishes:
#   · genuine crash      — a fresh .ips for Rational/Helper/pie since run start
#   · stray collision    — a Rational/Helper instance still alive (seated app,
#                          concurrent worker session) that the run didn't own
#   · clean teardown     — no fresh crash report, no stray instance
# For a full redacted bundle (Gatekeeper, launchd, Unified Log, app.log) point
# at Scripts/collect-diagnostics.sh — this stays lightweight and inline.
#
#   e2e_classify_app_termination <tag> <run_start_epoch>
e2e_classify_app_termination() {
  local tag="$1" since="${2:-0}"
  local crash_dir="${RATIOTHINK_DIAG_CRASH_DIR:-$HOME/Library/Logs/DiagnosticReports}"
  echo "$tag: --- termination classification (since epoch $since) ---" >&2

  local found_crash=0 r mtime
  if [ -d "$crash_dir" ]; then
    while IFS= read -r r; do
      [ -n "$r" ] || continue
      mtime="$(stat -f '%m' "$r" 2>/dev/null || echo 0)"
      if [ "$mtime" -ge "$since" ]; then
        echo "$tag:   CRASH: $(basename "$r") (genuine process crash — see $r)" >&2
        found_crash=1
      fi
    done <<EOF
$(find "$crash_dir" -type f \( -name 'Rational-*' -o -name 'RationalHelper-*' \
   -o -name 'RatioThink-*' -o -name 'RatioThinkHelper-*' -o -name 'pie-[0-9]*' \) 2>/dev/null)
EOF
  fi
  [ "$found_crash" -eq 0 ] && \
    echo "$tag:   no fresh Rational/Helper/pie crash report since run start — not a process crash" >&2

  # `|| true` is load-bearing: macOS /bin/bash is 3.2, where `var="$(pipeline)"`
  # aborts the whole script under `set -e` + `set -o pipefail` (the wrapper sets
  # both) when the pipeline's rc is non-zero — and `pgrep` exits 1 on NO match,
  # which is the common "no stray instance" case. Without the guard the
  # classifier dies mid-verdict exactly when it has the most to report (#545).
  local app_pids helper_pids engine_pids
  app_pids="$(pgrep -x Rational 2>/dev/null | tr '\n' ' ' || true)"
  helper_pids="$(pgrep -x RationalHelper 2>/dev/null | tr '\n' ' ' || true)"
  engine_pids="$(pgrep -f 'pie .*serve' 2>/dev/null | tr '\n' ' ' || true)"
  echo "$tag:   live Rational: ${app_pids:-none}  Helper: ${helper_pids:-none}  pie-serve: ${engine_pids:-none}" >&2
  [ -n "$app_pids" ] && \
    echo "$tag:   NOTE: a Rational instance is still alive — possible stray/seated collision (not this run's intentional terminate)" >&2

  echo "$tag:   deep bundle: Scripts/collect-diagnostics.sh --window 10m" >&2
  echo "$tag: --------------------------------------------------------" >&2
  return 0
}

