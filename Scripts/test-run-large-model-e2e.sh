#!/bin/bash
#
# Fast, non-GUI preflight regressions for run-large-model-e2e.sh. Drives the REAL
# wrapper to assert its preflight gating and contract without a seated session.
# Runs in `make test-gui-script`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/Scripts/run-large-model-e2e.sh"

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

test_rejects_external_pie_binary_unless_explicitly_overridden() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  touch "$tmp/pie"
  chmod +x "$tmp/pie"

  set +e
  local output
  output="$(
    PIE_BIN="$tmp/pie" \
    PIE_LARGE_E2E_RUNNER="$tmp/runner" \
    "$SCRIPT" 2>&1
  )"
  local status=$?
  set -e

  if [[ "$status" -ne 2 ]]; then
    echo "FAIL: expected external PIE_BIN to exit 2, got $status" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
  require_contains "$output" "worktree pie binary"
  require_contains "$output" "PIE_LARGE_E2E_ALLOW_EXTERNAL_PIE=1"
}

test_exports_default_large_model_to_real_engine_wrapper() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  touch "$tmp/pie"
  chmod +x "$tmp/pie"
  cat >"$tmp/runner" <<'RUNNER'
#!/bin/bash
set -euo pipefail
{
  echo "repo=$PIE_TEST_E2E_REPO"
  echo "file=$PIE_TEST_E2E_FILE"
  echo "min=$PIE_TEST_E2E_MIN_BYTES"
  echo "pie=$PIE_BIN"
} >"$PIE_LARGE_E2E_CAPTURE"
RUNNER
  chmod +x "$tmp/runner"

  local capture="$tmp/capture"
  local output
  output="$(
    PIE_BIN="$tmp/pie" \
    PIE_LARGE_E2E_ALLOW_EXTERNAL_PIE=1 \
    PIE_LARGE_E2E_RUNNER="$tmp/runner" \
    PIE_LARGE_E2E_CAPTURE="$capture" \
    "$SCRIPT" 2>&1
  )"

  require_contains "$output" "manual/local large-model real-engine E2E"
  require_contains "$output" "Qwen/Qwen3-14B-GGUF/Qwen3-14B-Q4_K_M.gguf"
  require_contains "$(cat "$capture")" "repo=Qwen/Qwen3-14B-GGUF"
  require_contains "$(cat "$capture")" "file=Qwen3-14B-Q4_K_M.gguf"
  require_contains "$(cat "$capture")" "min=9001752960"
  require_contains "$(cat "$capture")" "pie=$tmp/pie"
}

test_preserves_operator_repo_file_override() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  touch "$tmp/pie"
  chmod +x "$tmp/pie"
  cat >"$tmp/runner" <<'RUNNER'
#!/bin/bash
set -euo pipefail
{
  echo "$PIE_TEST_E2E_REPO/$PIE_TEST_E2E_FILE"
  echo "min=$PIE_TEST_E2E_MIN_BYTES"
} >"$PIE_LARGE_E2E_CAPTURE"
RUNNER
  chmod +x "$tmp/runner"

  local capture="$tmp/capture"
  PIE_BIN="$tmp/pie" \
  PIE_LARGE_E2E_ALLOW_EXTERNAL_PIE=1 \
  PIE_LARGE_E2E_RUNNER="$tmp/runner" \
  PIE_LARGE_E2E_CAPTURE="$capture" \
  PIE_TEST_E2E_REPO="bartowski/Qwen2.5-Coder-14B-Instruct-GGUF" \
  PIE_TEST_E2E_FILE="Qwen2.5-Coder-14B-Instruct-Q4_K_M.gguf" \
    "$SCRIPT" >/dev/null

  require_contains "$(cat "$capture")" \
    "bartowski/Qwen2.5-Coder-14B-Instruct-GGUF/Qwen2.5-Coder-14B-Instruct-Q4_K_M.gguf"
  require_contains "$(cat "$capture")" "min=8988111072"
}

test_partial_large_model_is_restaged_before_real_runner_executes() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  local partial_bytes=400000000
  local full_bytes=9001752960
  local model="$tmp/models/Qwen3-14B-Q4_K_M.gguf"
  mkdir -p "$tmp/bin" "$tmp/models"
  python3 - "$model" "$partial_bytes" <<'PY'
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
path.write_bytes(b"")
with path.open("r+b") as fh:
    fh.truncate(int(sys.argv[2]))
PY

  touch "$tmp/pie"
  chmod +x "$tmp/pie"

  cat >"$tmp/bin/curl" <<'FAKE_CURL'
#!/bin/bash
set -euo pipefail
out=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-o" ]; then out="$arg"; fi
  prev="$arg"
done
if [ -n "$out" ] && [ "$out" != "/dev/null" ]; then
  python3 - "$out" "$PIE_FAKE_CURL_BYTES" <<'PY'
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
path.write_bytes(b"")
with path.open("r+b") as fh:
    fh.truncate(int(sys.argv[2]))
PY
fi
FAKE_CURL
  chmod +x "$tmp/bin/curl"

  cat >"$tmp/bin/swift" <<'FAKE_SWIFT'
#!/bin/bash
echo "fake swift $*"
exit 0
FAKE_SWIFT
  chmod +x "$tmp/bin/swift"

  local output
  output="$(
    PATH="$tmp/bin:$PATH" \
    PIE_BIN="$tmp/pie" \
    PIE_LARGE_E2E_ALLOW_EXTERNAL_PIE=1 \
    PIE_TEST_E2E_MODELS_DIR="$tmp/models" \
    PIE_FAKE_CURL_BYTES="$full_bytes" \
      "$SCRIPT" 2>&1
  )"

  require_contains "$output" "existing staged model too small"
  local actual
  actual="$(stat -f%z "$model")"
  if [ "$actual" -lt "$full_bytes" ]; then
    echo "FAIL: large wrapper reused stale partial model ($actual bytes), want at least $full_bytes" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
}

test_overridden_large_model_partial_is_restaged_before_real_runner_executes() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  local partial_bytes=400000000
  local full_bytes=8988111072
  local model="$tmp/models/Qwen2.5-Coder-14B-Instruct-Q4_K_M.gguf"
  mkdir -p "$tmp/bin" "$tmp/models"
  python3 - "$model" "$partial_bytes" <<'PY'
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
path.write_bytes(b"")
with path.open("r+b") as fh:
    fh.truncate(int(sys.argv[2]))
PY

  touch "$tmp/pie"
  chmod +x "$tmp/pie"

  cat >"$tmp/bin/curl" <<'FAKE_CURL'
#!/bin/bash
set -euo pipefail
out=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-o" ]; then out="$arg"; fi
  prev="$arg"
done
if [ -n "$out" ] && [ "$out" != "/dev/null" ]; then
  python3 - "$out" "$PIE_FAKE_CURL_BYTES" <<'PY'
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
path.write_bytes(b"")
with path.open("r+b") as fh:
    fh.truncate(int(sys.argv[2]))
PY
fi
FAKE_CURL
  chmod +x "$tmp/bin/curl"

  cat >"$tmp/bin/swift" <<'FAKE_SWIFT'
#!/bin/bash
echo "fake swift $*"
exit 0
FAKE_SWIFT
  chmod +x "$tmp/bin/swift"

  local output
  output="$(
    PATH="$tmp/bin:$PATH" \
    PIE_BIN="$tmp/pie" \
    PIE_LARGE_E2E_ALLOW_EXTERNAL_PIE=1 \
    PIE_TEST_E2E_MODELS_DIR="$tmp/models" \
    PIE_TEST_E2E_REPO="bartowski/Qwen2.5-Coder-14B-Instruct-GGUF" \
    PIE_TEST_E2E_FILE="Qwen2.5-Coder-14B-Instruct-Q4_K_M.gguf" \
    PIE_FAKE_CURL_BYTES="$full_bytes" \
      "$SCRIPT" 2>&1
  )"

  require_contains "$output" "existing staged model too small"
  local actual
  actual="$(stat -f%z "$model")"
  if [ "$actual" -lt "$full_bytes" ]; then
    echo "FAIL: large wrapper reused stale partial override model ($actual bytes), want at least $full_bytes" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
}

test_known_large_model_ignores_inherited_weak_minimum() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  local weak_bytes=300000000
  local partial_bytes=400000000
  local full_bytes=9001752960
  local model="$tmp/models/Qwen3-14B-Q4_K_M.gguf"
  mkdir -p "$tmp/bin" "$tmp/models"
  python3 - "$model" "$partial_bytes" <<'PY'
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
path.write_bytes(b"")
with path.open("r+b") as fh:
    fh.truncate(int(sys.argv[2]))
PY

  touch "$tmp/pie"
  chmod +x "$tmp/pie"

  cat >"$tmp/bin/curl" <<'FAKE_CURL'
#!/bin/bash
set -euo pipefail
out=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-o" ]; then out="$arg"; fi
  prev="$arg"
done
if [ -n "$out" ] && [ "$out" != "/dev/null" ]; then
  python3 - "$out" "$PIE_FAKE_CURL_BYTES" <<'PY'
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
path.write_bytes(b"")
with path.open("r+b") as fh:
    fh.truncate(int(sys.argv[2]))
PY
fi
FAKE_CURL
  chmod +x "$tmp/bin/curl"

  cat >"$tmp/bin/swift" <<'FAKE_SWIFT'
#!/bin/bash
echo "fake swift $*"
exit 0
FAKE_SWIFT
  chmod +x "$tmp/bin/swift"

  local output
  output="$(
    PATH="$tmp/bin:$PATH" \
    PIE_BIN="$tmp/pie" \
    PIE_LARGE_E2E_ALLOW_EXTERNAL_PIE=1 \
    PIE_TEST_E2E_MODELS_DIR="$tmp/models" \
    PIE_TEST_E2E_MIN_BYTES="$weak_bytes" \
    PIE_FAKE_CURL_BYTES="$full_bytes" \
      "$SCRIPT" 2>&1
  )"

  require_contains "$output" "minimum staged size = $full_bytes bytes"
  require_contains "$output" "existing staged model too small"
  local actual
  actual="$(stat -f%z "$model")"
  if [ "$actual" -lt "$full_bytes" ]; then
    echo "FAIL: large wrapper honored inherited weak minimum ($weak_bytes bytes) for known model" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
}

test_rejects_external_pie_binary_unless_explicitly_overridden
test_exports_default_large_model_to_real_engine_wrapper
test_preserves_operator_repo_file_override
test_partial_large_model_is_restaged_before_real_runner_executes
test_overridden_large_model_partial_is_restaged_before_real_runner_executes
test_known_large_model_ignores_inherited_weak_minimum
echo "test-run-large-model-e2e: PASS"
