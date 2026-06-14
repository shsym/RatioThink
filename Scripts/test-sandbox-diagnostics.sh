#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/sandbox-diagnostics.sh
. "$ROOT/Scripts/lib/sandbox-diagnostics.sh"

fails=0

fail() {
  echo "FAIL: $*" >&2
  fails=$((fails + 1))
}

require_contains() {
  local haystack="$1" needle="$2" label="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    fail "$label: expected output to contain: $needle"
    printf '%s\n' "--- output ---" "$haystack" >&2
  fi
}

expect_status() {
  local got="$1" want="$2" label="$3"
  if [ "$got" -ne "$want" ]; then
    fail "$label: got status $got, want $want"
  fi
}

capture_status_output() {
  local __status_var="$1" __output_var="$2"
  shift 2
  local captured_output captured_status
  set +e
  captured_output="$("$@" 2>&1)"
  captured_status=$?
  set -e
  printf -v "$__status_var" '%s' "$captured_status"
  printf -v "$__output_var" '%s' "$captured_output"
}

test_swiftpm_cache_permission_guidance() {
  local status output
  capture_status_output status output env SANDBOX_DIAG_SWIFTPM_MODULE_CACHE=/dev/null/ModuleCache \
    bash -c '. Scripts/lib/sandbox-diagnostics.sh; sandbox_diag_require_swiftpm_cache "unit-tests"'
  expect_status "$status" 2 "swiftpm cache preflight"
  require_contains "$output" "unit-tests: sandbox/cache permission preflight failed" "swiftpm cache preflight"
  require_contains "$output" "SwiftPM/clang ModuleCache" "swiftpm cache preflight"
  require_contains "$output" "Run outside the restricted sandbox" "swiftpm cache preflight"
  require_contains "$output" "grant write access" "swiftpm cache preflight"
}

test_xcodebuild_cache_permission_guidance() {
  local status output
  capture_status_output status output env SANDBOX_DIAG_XCODE_DERIVED_DATA=/dev/null/DerivedData \
    SANDBOX_DIAG_XCODE_CORESIM_LOGS=/tmp bash -c '. Scripts/lib/sandbox-diagnostics.sh; sandbox_diag_require_xcodebuild_caches "app-unit"'
  expect_status "$status" 2 "xcodebuild cache preflight"
  require_contains "$output" "app-unit: sandbox/cache permission preflight failed" "xcodebuild cache preflight"
  require_contains "$output" "Xcode DerivedData" "xcodebuild cache preflight"
  require_contains "$output" "xcodebuild" "xcodebuild cache preflight"
}

test_uv_cache_permission_guidance() {
  local status output
  capture_status_output status output env SANDBOX_DIAG_UV_CACHE=/dev/null/uv-cache \
    bash -c '. Scripts/lib/sandbox-diagnostics.sh; sandbox_diag_require_uv_cache "http-e2e"'
  expect_status "$status" 2 "uv cache preflight"
  require_contains "$output" "http-e2e: sandbox/cache permission preflight failed" "uv cache preflight"
  require_contains "$output" "uv cache" "uv cache preflight"
  require_contains "$output" "UV_CACHE_DIR" "uv cache preflight"
}

test_healthy_cache_preflights_pass() {
  local tmp status output
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  capture_status_output status output env SANDBOX_DIAG_SWIFTPM_MODULE_CACHE="$tmp/swift-module-cache" \
    SANDBOX_DIAG_XCODE_DERIVED_DATA="$tmp/DerivedData" \
    SANDBOX_DIAG_XCODE_SWIFTPM_CACHE="$tmp/org.swift.swiftpm" \
    SANDBOX_DIAG_XCODE_CORESIM_LOGS="$tmp/CoreSimulator" \
    SANDBOX_DIAG_UV_CACHE="$tmp/uv" \
    bash -c '. Scripts/lib/sandbox-diagnostics.sh; sandbox_diag_require_swiftpm_cache ok && sandbox_diag_require_xcodebuild_caches ok && sandbox_diag_require_uv_cache ok'
  expect_status "$status" 0 "healthy cache preflights"
  if [ -n "$output" ]; then
    fail "healthy cache preflights: expected no output, got: $output"
  fi
}

test_mach_ipc_classifier_guidance() {
  local tmp output status
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' RETURN
  cat >"$tmp" <<'LOG'
thread 'mock-device-0' panicked at runtime/tests/common/mock_device.rs:204: RpcServer::create failed: Unknown Mach error 44c
LOG
  capture_status_output status output bash -c '. Scripts/lib/sandbox-diagnostics.sh; sandbox_diag_report_from_log "pie mock-device e2e" "$0"' "$tmp"
  expect_status "$status" 0 "mach ipc classifier"
  require_contains "$output" "pie mock-device e2e: detected sandbox/IPC permission failure" "mach ipc classifier"
  require_contains "$output" "Mach IPC" "mach ipc classifier"
  require_contains "$output" "Run outside the restricted sandbox" "mach ipc classifier"
}

test_cpm_classifier_guidance() {
  local tmp output status
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' RETURN
  cat >"$tmp" <<'LOG'
CMake Error at driver/portable/cmake/CPM.cmake:25 (file):
  file DOWNLOAD failed: Couldn't resolve host name
CMake Error at driver/portable/CMakeLists.txt:31 (cpmaddpackage):
  Unknown CMake command "cpmaddpackage".
LOG
  capture_status_output status output bash -c '. Scripts/lib/sandbox-diagnostics.sh; sandbox_diag_report_from_log "engine-build" "$0"' "$tmp"
  expect_status "$status" 0 "cpm classifier"
  require_contains "$output" "engine-build: detected missing CPM.cmake bootstrap" "cpm classifier"
  require_contains "$output" "prefetch CPM.cmake" "cpm classifier"
  require_contains "$output" "CPM_SOURCE_CACHE" "cpm classifier"
}

test_swift_wrapper_classifies_runtime_modulecache_failure() {
  local tmp status output
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "$tmp/bin" "$tmp/module-cache"
  cat >"$tmp/bin/xcrun" <<'FAKE_XCRUN'
#!/usr/bin/env bash
printf 'Invalid manifest: clang ModuleCache Operation not permitted\n' >&2
exit 44
FAKE_XCRUN
  chmod +x "$tmp/bin/xcrun"

  capture_status_output status output env PATH="$tmp/bin:$PATH" \
    SANDBOX_DIAG_SWIFTPM_MODULE_CACHE="$tmp/module-cache" \
    "$ROOT/Scripts/run-swift-test.sh" --filter RatioThinkCoreTests
  expect_status "$status" 44 "swift wrapper runtime classifier preserves status"
  require_contains "$output" "Invalid manifest: clang ModuleCache Operation not permitted" "swift wrapper runtime classifier"
  require_contains "$output" "swift-test: detected SwiftPM/clang ModuleCache permission failure" "swift wrapper runtime classifier"
  require_contains "$output" "Run outside the restricted sandbox" "swift wrapper runtime classifier"
}

test_xcode_make_recipe_classifies_runtime_mach_ipc_failure() {
  local tmp status output
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "$tmp/bin" "$tmp/DerivedData" "$tmp/swiftpm" "$tmp/CoreSimulator" "$tmp/logs"
  cat >"$tmp/bin/xcodebuild" <<'FAKE_XCODEBUILD'
#!/usr/bin/env bash
printf 'RpcServer::create failed: Unknown Mach error 44c\n' >&2
exit 45
FAKE_XCODEBUILD
  chmod +x "$tmp/bin/xcodebuild"

  capture_status_output status output env PATH="$tmp/bin:$PATH" \
    SANDBOX_DIAG_XCODE_DERIVED_DATA="$tmp/DerivedData" \
    SANDBOX_DIAG_XCODE_SWIFTPM_CACHE="$tmp/swiftpm" \
    SANDBOX_DIAG_XCODE_CORESIM_LOGS="$tmp/CoreSimulator" \
    make -C "$ROOT" LOGDIR="$tmp/logs" test-gui-shell
  expect_status "$status" 2 "xcode make recipe runtime classifier make status"
  require_contains "$output" "RpcServer::create failed: Unknown Mach error 44c" "xcode make recipe runtime classifier"
  require_contains "$output" "Error 45" "xcode make recipe runtime classifier preserves recipe status"
  require_contains "$output" "test-gui-shell: detected sandbox/IPC permission failure" "xcode make recipe runtime classifier"
  require_contains "$output" "Run outside the restricted sandbox" "xcode make recipe runtime classifier"
}

test_swiftpm_cache_permission_guidance
test_xcodebuild_cache_permission_guidance
test_uv_cache_permission_guidance
test_healthy_cache_preflights_pass
test_mach_ipc_classifier_guidance
test_cpm_classifier_guidance
test_swift_wrapper_classifies_runtime_modulecache_failure
test_xcode_make_recipe_classifies_runtime_mach_ipc_failure

if [ "$fails" -eq 0 ]; then
  echo "sandbox-diagnostics self-test: PASS"
else
  echo "sandbox-diagnostics self-test: FAIL ($fails failure(s))" >&2
  exit 1
fi
