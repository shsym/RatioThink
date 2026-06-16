#!/bin/bash
#
# Fast, non-GUI preflight regressions for run-stream-cancel-gui-e2e.sh. Drives
# the REAL wrapper to assert its preflight gating and contract without a seated
# session. Runs in `make test-gui-script`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/Scripts/run-stream-cancel-gui-e2e.sh"
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
  if grep -F "PIE_TEST_TCC_GRANTED=1 Scripts/run-stream-cancel-gui-e2e.sh" "$MAKEFILE" >/dev/null; then
    echo "FAIL: make test-gui-stream-cancel must not inject PIE_TEST_TCC_GRANTED=1; the caller must attest TCC readiness" >&2
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
  if [[ "$output" == *"starting holding mock engine"* ]]; then
    echo "FAIL: TCC preflight must happen before starting the mock engine" >&2
    exit 1
  fi
}

# #518 regression: a release credit must be consumed by exactly ONE of two
# CONCURRENTLY-held streams (the old Event's test-then-clear let both finish
# on a single release). Drives the real harness over loopback — no GUI.
test_release_credit_is_consumed_by_exactly_one_held_stream() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"; kill "${harness_pid:-}" 2>/dev/null' RETURN

  python3 "$ROOT/Scripts/gui-chat-stream-harness.py" \
    --port-file "$tmp/url" --mode hold --hold-count 2 \
    --hold-token TOK518 --reply TAIL518 >"$tmp/harness.log" 2>&1 &
  local harness_pid=$!
  for _ in $(seq 1 20); do [ -s "$tmp/url" ] && break; sleep 0.5; done
  [ -s "$tmp/url" ] || { echo "FAIL: harness never published URL" >&2; exit 1; }
  local base; base="$(cat "$tmp/url")"

  curl -sN -m 30 -X POST "$base/v1/chat/completions" -d '{}' >"$tmp/s1" &
  local c1=$!
  curl -sN -m 30 -X POST "$base/v1/chat/completions" -d '{}' >"$tmp/s2" &
  local c2=$!
  sleep 2  # both streams held

  curl -s -X POST "$base/control/release" >/dev/null
  sleep 2
  local done1 done2
  done1=$(grep -c 'finish_reason":"stop' "$tmp/s1" || true)
  done2=$(grep -c 'finish_reason":"stop' "$tmp/s2" || true)
  if [ $((done1 + done2)) -ne 1 ]; then
    echo "FAIL: one release credit finished $((done1 + done2)) held streams (want exactly 1)" >&2
    exit 1
  fi

  curl -s -X POST "$base/control/release?n=1" >/dev/null
  for _ in $(seq 1 20); do
    done1=$(grep -c 'finish_reason":"stop' "$tmp/s1" || true)
    done2=$(grep -c 'finish_reason":"stop' "$tmp/s2" || true)
    [ $((done1 + done2)) -eq 2 ] && break
    sleep 0.5
  done
  if [ $((done1 + done2)) -ne 2 ]; then
    echo "FAIL: second credit did not finish the remaining held stream" >&2
    exit 1
  fi
  wait "$c1" "$c2" 2>/dev/null || true
}

test_make_target_does_not_inject_tcc_attestation
test_requires_tcc_before_starting_harness
test_release_credit_is_consumed_by_exactly_one_held_stream
echo "test-run-stream-cancel-gui-e2e: PASS"
