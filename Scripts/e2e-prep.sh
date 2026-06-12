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
#   e2e_ensure_hf_model "$MODEL" "$HF_HOME_DIR" "myscenario"
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

# True only when the HF hub cache at $dir holds a fully-resolved model WEIGHT
# file. The hub dir, refs/, and the small metadata blobs (config.json,
# tokenizer*, .gitattributes) all resolve independently of the large weight
# blob, so an interrupted/aborted download (Ctrl-C, network drop, disk-full)
# commonly lands metadata-present but weights-missing — and a stray
# snapshots/.DS_Store would satisfy any "≥1 file" check. Requiring a resolved
# *weight* artifact rejects those partial states. `-L` follows symlinks, so a
# dangling weight symlink (blob absent) does NOT match.
#
# Assumes weights carry a known extension (.safetensors / .gguf / .bin); true
# for the pinned Qwen/Qwen3-0.6B (.safetensors). Revisit this list if the
# helper must stay format-agnostic for exotic weight formats.
_e2e_hf_model_cached() {
  local dir="$1"
  [ -d "$dir/snapshots" ] || return 1
  [ -n "$(find -L "$dir/snapshots" -type f \( -name '*.safetensors' -o -name '*.gguf' -o -name '*.bin' \) 2>/dev/null | head -n1)" ]
}

# Ensure the HF model is in the local cache; download it if missing.
e2e_ensure_hf_model() {
  local model="$1" hf_home="$2" tag="$3"
  local dir="$hf_home/hub/models--${model//\//--}"
  if _e2e_hf_model_cached "$dir"; then
    return 0
  fi
  if [ "${PIE_E2E_AUTOPREP:-1}" != "1" ]; then
    echo "$tag: model '$model' not cached and autoprep disabled. Download: hf download $model" >&2
    return 1
  fi
  echo "$tag: model '$model' not cached — downloading to $hf_home (one-time, ~GBs)…" >&2
  if command -v hf >/dev/null 2>&1; then
    if ! HF_HOME="$hf_home" hf download "$model" >&2; then
      echo "$tag: 'hf download $model' failed (see output above). Retry: HF_HOME=$hf_home hf download $model" >&2
      return 1
    fi
  elif command -v huggingface-cli >/dev/null 2>&1; then
    if ! HF_HOME="$hf_home" huggingface-cli download "$model" >&2; then
      echo "$tag: 'huggingface-cli download $model' failed (see output above). Retry: HF_HOME=$hf_home huggingface-cli download $model" >&2
      return 1
    fi
  elif python3 -c 'import huggingface_hub' >/dev/null 2>&1; then
    if ! HF_HOME="$hf_home" python3 -c \
        "from huggingface_hub import snapshot_download; snapshot_download('$model')" >&2; then
      echo "$tag: huggingface_hub snapshot_download('$model') failed (see output above)." >&2
      return 1
    fi
  else
    echo "$tag: no Hugging Face downloader found." >&2
    echo "$tag: install one — 'pip install huggingface_hub' (or 'uv pip install huggingface_hub') — then rerun." >&2
    return 1
  fi
  if _e2e_hf_model_cached "$dir"; then
    return 0
  fi
  echo "$tag: download reported success but the cache looks incomplete: $dir" >&2
  echo "$tag: expected a populated snapshots/ tree (resolved blobs). Re-run: HF_HOME=$hf_home hf download $model" >&2
  return 1
}
