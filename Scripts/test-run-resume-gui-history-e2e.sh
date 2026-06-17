#!/bin/bash
#
# Fast, non-GUI preflight regressions for run-resume-gui-history-e2e.sh. Drives
# the REAL wrapper to assert its TCC preflight runs before the deterministic
# harness starts, without a seated session. Runs in `make test-gui-script`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/Scripts/run-resume-gui-history-e2e.sh"
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
  if grep -F "PIE_TEST_TCC_GRANTED=1 Scripts/run-resume-gui-history-e2e.sh" "$MAKEFILE" >/dev/null; then
    echo "FAIL: make test-gui-history must not inject PIE_TEST_TCC_GRANTED=1; the caller must attest TCC readiness" >&2
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
  if [[ "$output" == *"starting deterministic HTTP harness"* ]]; then
    echo "FAIL: TCC preflight must happen before starting the deterministic harness" >&2
    exit 1
  fi
}

test_make_target_does_not_inject_tcc_attestation
test_requires_tcc_before_starting_harness
echo "test-run-resume-gui-history-e2e: PASS"
