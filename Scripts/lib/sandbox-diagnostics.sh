#!/usr/bin/env bash
# Shared preflight + recovery diagnostics for test wrappers that otherwise fail
# with low-level sandbox/cache/IPC errors before project code is exercised.
# Source from bash scripts or Make recipes running under bash.

_sandbox_diag_tag() {
  local tag="$1"
  printf '%s' "${tag:-test-wrapper}"
}

_sandbox_diag_check_writable_dir() {
  local tag="$1" label="$2" path="$3" hint="${4:-}"
  local probe
  if [ -z "$path" ]; then
    return 0
  fi
  if ! mkdir -p "$path" >/dev/null 2>&1; then
    _sandbox_diag_print_cache_failure "$tag" "$label" "$path" "$hint"
    return 2
  fi
  probe="$path/.sandbox-diagnostics.$$.$RANDOM"
  if ! ( umask 077 && : >"$probe" ) >/dev/null 2>&1; then
    _sandbox_diag_print_cache_failure "$tag" "$label" "$path" "$hint"
    return 2
  fi
  rm -f "$probe" >/dev/null 2>&1 || true
  return 0
}

_sandbox_diag_print_cache_failure() {
  local tag="$(_sandbox_diag_tag "$1")" label="$2" path="$3" hint="${4:-}"
  echo "$tag: sandbox/cache permission preflight failed for $label." >&2
  echo "$tag: path: $path" >&2
  echo "$tag: recovery: Run outside the restricted sandbox, or grant write access to this cache path and retry." >&2
  if [ -n "$hint" ]; then
    echo "$tag: recovery: $hint" >&2
  fi
}

sandbox_diag_require_swiftpm_cache() {
  local tag="$(_sandbox_diag_tag "${1:-swift-test}")"
  local module_cache="${SANDBOX_DIAG_SWIFTPM_MODULE_CACHE:-${CLANG_MODULE_CACHE_PATH:-$HOME/.cache/clang/ModuleCache}}"
  _sandbox_diag_check_writable_dir "$tag" "SwiftPM/clang ModuleCache" "$module_cache" \
    "If sandboxing is required, grant the wrapper write access to the ModuleCache location before running swift test."
}

sandbox_diag_require_xcodebuild_caches() {
  local tag="$(_sandbox_diag_tag "${1:-xcodebuild}")"
  local derived_data="${SANDBOX_DIAG_XCODE_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData}"
  local swiftpm_cache="${SANDBOX_DIAG_XCODE_SWIFTPM_CACHE:-$HOME/Library/Caches/org.swift.swiftpm}"
  local coresim_logs="${SANDBOX_DIAG_XCODE_CORESIM_LOGS:-$HOME/Library/Logs/CoreSimulator}"
  _sandbox_diag_check_writable_dir "$tag" "Xcode DerivedData" "$derived_data" \
    "xcodebuild writes package-resolution diagnostics and build products here; run unsandboxed or grant this path." || return 2
  _sandbox_diag_check_writable_dir "$tag" "xcodebuild SwiftPM cache" "$swiftpm_cache" \
    "xcodebuild package resolution writes SwiftPM cache/diagnostic files here; run unsandboxed or grant this path." || return 2
  _sandbox_diag_check_writable_dir "$tag" "CoreSimulator logs" "$coresim_logs" \
    "xcodebuild may initialize CoreSimulator logging even for app-unit runs; run unsandboxed or grant this path." || return 2
}

sandbox_diag_require_uv_cache() {
  local tag="$(_sandbox_diag_tag "${1:-uv}")"
  local uv_cache="${SANDBOX_DIAG_UV_CACHE:-${UV_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/uv}}"
  _sandbox_diag_check_writable_dir "$tag" "uv cache" "$uv_cache" \
    "Set UV_CACHE_DIR to a writable directory, or run outside the restricted sandbox / grant the uv cache path."
}

sandbox_diag_report_from_log() {
  local tag="$(_sandbox_diag_tag "${1:-test-wrapper}")" log="$2" matched=1
  [ -f "$log" ] || return 0

  if grep -Eqi 'Unknown Mach error 44c|RpcServer.*Unknown Mach error|RpcServer.*Mach|IpcOneShotServer.*Operation not permitted' "$log"; then
    echo "$tag: detected sandbox/IPC permission failure (Mach IPC / RpcServer)." >&2
    echo "$tag: recovery: Run outside the restricted sandbox; the pie mock-device/RpcServer path needs Mach IPC permissions that sandboxed wrappers may deny." >&2
    matched=0
  fi

  if grep -Eqi 'ModuleCache.*Operation not permitted|Operation not permitted.*ModuleCache|Invalid manifest.*ModuleCache' "$log"; then
    echo "$tag: detected SwiftPM/clang ModuleCache permission failure." >&2
    echo "$tag: recovery: Run outside the restricted sandbox, or grant write access to $HOME/.cache/clang/ModuleCache (or CLANG_MODULE_CACHE_PATH if overridden)." >&2
    matched=0
  fi

  if grep -Eqi 'uv cache|UV_CACHE_DIR|\.cache/uv|Operation not permitted.*uv|uv.*Operation not permitted' "$log"; then
    echo "$tag: detected uv cache permission failure." >&2
    echo "$tag: recovery: Run outside the restricted sandbox, grant the uv cache path, or set UV_CACHE_DIR to a writable directory." >&2
    matched=0
  fi

  if grep -Eqi 'CoreSimulator.*Operation not permitted|DerivedData.*Operation not permitted|\.dia.*Operation not permitted|xcodebuild.*package.*Operation not permitted' "$log"; then
    echo "$tag: detected xcodebuild cache/log permission failure." >&2
    echo "$tag: recovery: Run outside the restricted sandbox, or grant xcodebuild write access to DerivedData, SwiftPM caches, and CoreSimulator logs." >&2
    matched=0
  fi

  if grep -Eqi 'Unknown CMake command[[:space:]]+"?cpmaddpackage|file DOWNLOAD failed|CPM\.cmake.*(download|DOWNLOAD|failed|not found)' "$log" \
     && grep -Eqi 'CPM|cpmaddpackage' "$log"; then
    echo "$tag: detected missing CPM.cmake bootstrap after download/cache failure." >&2
    echo "$tag: recovery: prefetch CPM.cmake or provide a writable prefilled CPM_SOURCE_CACHE, then retry the build." >&2
    echo "$tag: recovery: example: mkdir -p \"\$CPM_SOURCE_CACHE/cpm\" && curl -L https://github.com/cpm-cmake/CPM.cmake/releases/download/v0.42.0/CPM.cmake -o \"\$CPM_SOURCE_CACHE/cpm/CPM_0.42.0.cmake\"" >&2
    matched=0
  fi

  return 0
}

sandbox_diag_run_with_recovery() {
  local tag="$1"
  shift
  local safe_tag tmp status
  safe_tag="${tag//[^A-Za-z0-9_.-]/_}"
  tmp="${TMPDIR:-/tmp}/sandbox-diagnostics.${safe_tag}.$$.$RANDOM.log"

  set +e
  "$@" 2>&1 | tee "$tmp"
  status=${PIPESTATUS[0]}
  set -e

  if [ "$status" -ne 0 ]; then
    sandbox_diag_report_from_log "$tag" "$tmp" || true
  fi
  rm -f "$tmp" >/dev/null 2>&1 || true
  return "$status"
}
