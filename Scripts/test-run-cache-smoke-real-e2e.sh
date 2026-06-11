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

test_exports_default_model_to_cache_smoke_runner
test_preserves_operator_model_override

echo "test-run-cache-smoke-real-e2e: PASS"
