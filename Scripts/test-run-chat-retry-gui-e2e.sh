#!/bin/bash
#
# Fast, non-GUI preflight regressions for run-chat-retry-gui-e2e.sh. Drives the
# REAL wrapper to assert its preflight gating and contract without a seated
# session. Runs in `make test-gui-script`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/Scripts/run-chat-retry-gui-e2e.sh"
MAKEFILE="$ROOT/Makefile"

require_contains() {
  local haystack="$1"
  local needle="$2"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "FAIL: expected output to contain: $needle" >&2
    echo "--- output ---" >&2
    printf '%s\n' "$haystack" >&2
    exit 1
  fi
}

test_make_target_does_not_inject_tcc_attestation() {
  if grep -F "PIE_TEST_TCC_GRANTED=1 Scripts/run-chat-retry-gui-e2e.sh" "$MAKEFILE" >/dev/null; then
    echo "FAIL: make test-gui-chat-retry must not inject PIE_TEST_TCC_GRANTED=1; the caller must attest TCC readiness" >&2
    exit 1
  fi
}

test_requires_tcc_before_starting_harness() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  mkdir -p "$tmp/bin"
  cat >"$tmp/bin/pgrep" <<'FAKE_PGREP'
#!/bin/bash
exit 0
FAKE_PGREP
  chmod +x "$tmp/bin/pgrep"

  set +e
  local output
  output="$(
    PATH="$tmp/bin:$PATH" \
    PIE_TEST_TCC_GRANTED= \
    PIE_TEST_RUN_ROOT="$tmp/run" \
    "$SCRIPT" 2>&1
  )"
  local status=$?
  set -e

  if [[ "$status" -ne 2 ]]; then
    echo "FAIL: expected missing TCC preflight to exit 2, got $status" >&2
    echo "--- output ---" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
  require_contains "$output" "Automation/Accessibility permission required"
  require_contains "$output" "PIE_TEST_TCC_GRANTED=1"
  if [[ "$output" == *"starting numbered-reply mock engine"* ]]; then
    echo "FAIL: TCC preflight must happen before starting the mock engine" >&2
    exit 1
  fi
}

test_dumps_harness_log_when_xcodebuild_fails() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  mkdir -p "$tmp/bin"
  cat >"$tmp/bin/pgrep" <<'FAKE_PGREP'
#!/bin/bash
exit 0
FAKE_PGREP
  cat >"$tmp/bin/xcodegen" <<'FAKE_XCODEGEN'
#!/bin/bash
exit 0
FAKE_XCODEGEN
  cat >"$tmp/bin/xcodebuild" <<'FAKE_XCODEBUILD'
#!/bin/bash
echo "simulated xcodebuild failure" >&2
exit 42
FAKE_XCODEBUILD
  cat >"$tmp/bin/defaults" <<'FAKE_DEFAULTS'
#!/bin/bash
case "${1:-}" in
  export|delete)
    exit 0
    ;;
  *)
    echo "unexpected defaults invocation: $*" >&2
    exit 1
    ;;
esac
FAKE_DEFAULTS
  cat >"$tmp/bin/python3" <<'FAKE_PYTHON3'
#!/bin/bash
port_file=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --port-file)
      port_file="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
echo "retry harness diagnostic before xcodebuild failure"
printf 'http://127.0.0.1:54321\n' >"$port_file"
trap 'exit 0' TERM INT
while true; do sleep 1; done
FAKE_PYTHON3
  chmod +x "$tmp/bin/pgrep" "$tmp/bin/xcodegen" "$tmp/bin/xcodebuild" "$tmp/bin/defaults" "$tmp/bin/python3"

  set +e
  local output
  output="$(
    PATH="$tmp/bin:$PATH" \
    PIE_TEST_TCC_GRANTED=1 \
    PIE_TEST_RUN_ROOT="$tmp/run" \
    "$SCRIPT" 2>&1
  )"
  local status=$?
  set -e

  if [[ "$status" -ne 42 ]]; then
    echo "FAIL: expected xcodebuild status 42 to propagate, got $status" >&2
    echo "--- output ---" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
  require_contains "$output" "simulated xcodebuild failure"
  require_contains "$output" "retry harness diagnostic before xcodebuild failure"
}

test_make_target_does_not_inject_tcc_attestation
test_requires_tcc_before_starting_harness
test_dumps_harness_log_when_xcodebuild_fails
echo "test-run-chat-retry-gui-e2e: PASS"
