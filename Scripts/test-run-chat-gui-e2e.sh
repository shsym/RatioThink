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

test_missing_gguf_fixture_is_not_accepted() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  # Fake a seated session and a runnable pie so the flow reaches the GGUF
  # fixture gate. Stage only a *bare* GGUF hub dir — the partial/aborted-
  # download shape that must not be accepted as a resolved fixture — and
  # assert the wrapper fails loudly before starting Xcode/engine work.
  mkdir -p "$tmp/bin" "$tmp/hf/hub/models--Qwen--Qwen3-0.6B-GGUF"
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
    PIE_TEST_TCC_GRANTED=1 \
    PIE_E2E_AUTOPREP=0 \
    PIE_TEST_RUN_ROOT="$tmp/run" \
    STAGE_TEST_MODEL_DEST="$tmp/staged/Qwen3-0.6B-Q8_0.gguf" \
    "$SCRIPT" 2>&1
  )"
  local status=$?
  set -e

  if [[ "$status" -ne 2 ]]; then
    echo "FAIL: missing GGUF fixture must fail the model gate (exit 2), got $status" >&2
    echo "--- output ---" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
  require_contains "$output" "model fixture NOT staged"
  require_contains "$output" "GGUF fixture unavailable"
  if [[ "$output" == *"starting portable GGUF engine harness"* ]]; then
    echo "FAIL: bare GGUF cache wrongly accepted as a staged fixture — engine harness started" >&2
    exit 1
  fi
}

# Direct contract assertions on _e2e_hf_model_cached, independent of the
# wrapper's gate ordering ( F2): only a RESOLVED WEIGHT artifact
# counts as cached. The bare-dir case above short-circuits at `[ -d snapshots ]`
# and never reaches the find predicate, so these pin the predicate itself — a
# future loosening (dropping -L, the weight-extension filter, or reverting to
# `[ -d snapshots ]`) is caught here.
test_hf_model_cached_helper_contract() {
  source "$ROOT/Scripts/e2e-prep.sh"
  local tmp rev="abc123"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  _assert_cached() {  # <dir> <want 0|1> <label>
    local d="$1" want="$2" label="$3" got
    if _e2e_hf_model_cached "$d"; then got=0; else got=1; fi
    if [ "$got" -ne "$want" ]; then
      echo "FAIL: helper contract [$label] — _e2e_hf_model_cached=$got want=$want" >&2
      exit 1
    fi
  }

  # 1) bare hub dir, no snapshots/                         -> not cached
  mkdir -p "$tmp/bare/blobs" "$tmp/bare/refs"
  _assert_cached "$tmp/bare" 1 "bare hub dir"

  # 2) empty snapshots/ tree                               -> not cached
  mkdir -p "$tmp/empty/snapshots/$rev"
  _assert_cached "$tmp/empty" 1 "empty snapshots"

  # 3) metadata-only resolved (config.json + stray .DS_Store, no weight) -> not cached (F1)
  mkdir -p "$tmp/meta/snapshots/$rev"
  printf '{}' >"$tmp/meta/snapshots/$rev/config.json"
  printf 'x'  >"$tmp/meta/snapshots/$rev/.DS_Store"
  _assert_cached "$tmp/meta" 1 "metadata-only + stray, no weight"

  # 4) dangling weight symlink (blob missing)              -> not cached
  mkdir -p "$tmp/dangling/snapshots/$rev" "$tmp/dangling/blobs"
  printf '{}' >"$tmp/dangling/snapshots/$rev/config.json"
  ln -s "../../blobs/deadbeef" "$tmp/dangling/snapshots/$rev/model.safetensors"
  _assert_cached "$tmp/dangling" 1 "dangling weight symlink"

  # 5) resolved weight (symlink -> real blob)              -> cached
  mkdir -p "$tmp/ok/snapshots/$rev" "$tmp/ok/blobs"
  printf 'SAFE' >"$tmp/ok/blobs/deadbeef"
  ln -s "../../blobs/deadbeef" "$tmp/ok/snapshots/$rev/model.safetensors"
  _assert_cached "$tmp/ok" 0 "resolved weight"

  echo "test-run-chat-gui-e2e: _e2e_hf_model_cached contract OK"
}

test_requires_tcc_before_starting_engine
test_removes_stale_config_on_exit
test_missing_gguf_fixture_is_not_accepted
test_hf_model_cached_helper_contract
echo "test-run-chat-gui-e2e: PASS"
