#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/Scripts/run-cache-smoke-real-e2e.sh"

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

test_exports_default_model_to_cache_smoke_runner() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  cat >"$tmp/runner" <<'RUNNER'
#!/bin/bash
set -euo pipefail
{
  echo "model=$MODEL"
  echo "harness=$CACHE_SMOKE_REAL_HARNESS"
} >"$CACHE_SMOKE_REAL_CAPTURE"
RUNNER
  chmod +x "$tmp/runner"

  local capture="$tmp/capture"
  local output
  output="$(
    CACHE_SMOKE_REAL_RUNNER="$tmp/runner" \
    CACHE_SMOKE_REAL_CAPTURE="$capture" \
      "$SCRIPT" 2>&1
  )"

  require_contains "$output" "real-engine APC cache smoke"
  require_contains "$(cat "$capture")" "model=Qwen/Qwen3-0.6B"
  require_contains "$(cat "$capture")" "harness=Inferlets/chat-apc/cache_smoke_real.py"
}

test_preserves_operator_model_override() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  cat >"$tmp/runner" <<'RUNNER'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$MODEL" >"$CACHE_SMOKE_REAL_CAPTURE"
RUNNER
  chmod +x "$tmp/runner"

  local capture="$tmp/capture"
  MODEL="local/custom-model" \
  CACHE_SMOKE_REAL_RUNNER="$tmp/runner" \
  CACHE_SMOKE_REAL_CAPTURE="$capture" \
    "$SCRIPT" >/dev/null

  require_contains "$(cat "$capture")" "local/custom-model"
}

assert_harness_selftest_fails() {
  local scenario="$1"
  local expected="$2"
  local output
  local status
  set +e
  output="$(
    CACHE_SMOKE_REAL_SELFTEST="post-turn2-$scenario" \
      python3 "$ROOT/Inferlets/chat-apc/cache_smoke_real.py" 2>&1
  )"
  status=$?
  set -e

  if [[ "$status" -eq 0 ]]; then
    echo "FAIL: expected cache_smoke_real.py self-test '$scenario' to fail" >&2
    echo "--- output ---" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
  require_contains "$output" "$expected"
}

test_cache_smoke_harness_fails_post_turn2_non_200_probes() {
  assert_harness_selftest_fails "same-model-profile-switch-500" "same-model profile switch status 500"
  assert_harness_selftest_fails "bypass-500" "bypass status 500"
  assert_harness_selftest_fails "otherkey-500" "different key status 500"
  assert_harness_selftest_fails "retry-after-turn2-500" "retry lookup status 500"
  assert_harness_selftest_fails "sysprompt-change-500" "prompt-changing request status 500"
}

test_cache_smoke_harness_fails_required_missing_diagnostics() {
  assert_harness_selftest_fails "same-model-profile-switch-missing-diag" \
    "same-model profile switch: missing X-ChatAPC-Cache header"
  assert_harness_selftest_fails "otherkey-missing-diag" \
    "different key: missing X-ChatAPC-Cache header"
  assert_harness_selftest_fails "retry-after-turn2-missing-diag" \
    "retry lookup: missing X-ChatAPC-Cache header"
  assert_harness_selftest_fails "sysprompt-change-missing-diag" \
    "prompt-changing request: missing X-ChatAPC-Cache header"
}

test_cache_smoke_harness_rejects_unknown_selftest_scenario() {
  assert_harness_selftest_fails "typo" \
    "unknown CACHE_SMOKE_REAL_SELFTEST scenario: post-turn2-typo"
}

test_exports_default_model_to_cache_smoke_runner
test_preserves_operator_model_override
test_cache_smoke_harness_fails_post_turn2_non_200_probes
test_cache_smoke_harness_fails_required_missing_diagnostics
test_cache_smoke_harness_rejects_unknown_selftest_scenario

echo "test-run-cache-smoke-real-e2e: PASS"
