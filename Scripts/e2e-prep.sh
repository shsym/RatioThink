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
# Each `ensure_*` either satisfies the prerequisite (building when cheap+safe)
# or prints the exact command to fix it and returns non-zero so the caller can
# `exit`. Set PIE_E2E_AUTOPREP=0 to turn the build off (verify-only) for
# deterministic CI.

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
    echo "$tag: RatioThink.app + XCTest-runner Automation/Accessibility permission required (cannot be auto-granted)." >&2
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
