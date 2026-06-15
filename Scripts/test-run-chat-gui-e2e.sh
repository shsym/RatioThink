#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/Scripts/run-chat-gui-e2e.sh"

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

test_requires_tcc_before_starting_engine() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  mkdir -p "$tmp/bin" "$tmp/hf/hub/models--Qwen--Qwen3-0.6B"
  cat >"$tmp/bin/pgrep" <<'FAKE_PGREP'
#!/bin/bash
exit 0
FAKE_PGREP
  chmod +x "$tmp/bin/pgrep"
  touch "$tmp/pie"
  chmod +x "$tmp/pie"

  set +e
  local output
  output="$(
    PATH="$tmp/bin:$PATH" \
    HF_HOME="$tmp/hf" \
    PIE_BIN="$tmp/pie" \
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
  if [[ "$output" == *"starting small-model engine harness"* ]]; then
    echo "FAIL: TCC preflight must happen before starting the engine harness" >&2
    exit 1
  fi
}

test_removes_stale_config_on_exit() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  local config="/tmp/pie-chat-gui-e2e.env"
  printf 'PIE_TEST_ENGINE_BASE_URL=http://127.0.0.1:9\n' >"$config"

  mkdir -p "$tmp/bin" "$tmp/hf/hub/models--Qwen--Qwen3-0.6B"
  cat >"$tmp/bin/pgrep" <<'FAKE_PGREP'
#!/bin/bash
exit 0
FAKE_PGREP
  chmod +x "$tmp/bin/pgrep"

  set +e
  PATH="$tmp/bin:$PATH" \
  HF_HOME="$tmp/hf" \
  PIE_BIN="$tmp/missing-pie" \
  PIE_TEST_TCC_GRANTED=1 \
  PIE_E2E_AUTOPREP=0 \
  PIE_TEST_RUN_ROOT="$tmp/run" \
  "$SCRIPT" >/dev/null 2>&1
  set -e

  if [[ -e "$config" ]]; then
    echo "FAIL: stale $config should be removed on wrapper exit" >&2
    rm -f "$config"
    exit 1
  fi
}

test_requires_tcc_before_starting_engine
test_removes_stale_config_on_exit
echo "test-run-chat-gui-e2e: PASS"
