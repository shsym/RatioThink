#!/usr/bin/env bash
#
# Contract self-test for stage-test-model.sh. Hits the REAL script (never
# stubs it) in a throwaway sandbox so the self-bootstrap-or-guide contract
# is regression-guarded by `make test-gui-script`, mirroring the sibling
# test-run-*-e2e.sh wrappers. macOS / BSD userland.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STAGE="$SCRIPT_DIR/stage-test-model.sh"
TMP="$(mktemp -d /tmp/stage-test-model-selftest.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
fail=0

# Case 1 — GUIDE: empty cache + absent dest must exit non-zero AND print the
# exact huggingface-cli download command (never a silent skip).
set +e
out="$(HF_HOME="$TMP/empty-hf" STAGE_TEST_MODEL_DEST="$TMP/none/Qwen3-0.6B-Q8_0.gguf" "$STAGE" 2>&1)"
rc=$?
set -e
[ "$rc" -ne 0 ] || { echo "FAIL case1: expected non-zero exit when fixture absent"; fail=1; }
printf '%s\n' "$out" | grep -q 'huggingface-cli download Qwen/Qwen3-0.6B-GGUF --include "Qwen3-0.6B-Q8_0.gguf"' \
  || { echo "FAIL case1: guidance missing exact huggingface-cli command"; printf '%s\n' "$out"; fail=1; }

# Case 2 — STAGE: a cached gguf must be symlinked into dest, exit 0.
SNAP="$TMP/hf/hub/models--Qwen--Qwen3-0.6B-GGUF/snapshots/rev1"
mkdir -p "$SNAP"
printf 'dummy-gguf' > "$SNAP/Qwen3-0.6B-Q8_0.gguf"
DEST="$TMP/staged/Qwen3-0.6B-Q8_0.gguf"
HF_HOME="$TMP/hf" STAGE_TEST_MODEL_DEST="$DEST" "$STAGE" >/dev/null 2>&1 \
  || { echo "FAIL case2: expected exit 0 when model cached"; fail=1; }
[ -f "$DEST" ] || { echo "FAIL case2: dest fixture not resolvable"; fail=1; }
[ -L "$DEST" ] || { echo "FAIL case2: dest expected to be a symlink into the cache"; fail=1; }

# Case 3 — IDEMPOTENT: re-running with dest already present is a no-op exit 0.
HF_HOME="$TMP/hf" STAGE_TEST_MODEL_DEST="$DEST" "$STAGE" >/dev/null 2>&1 \
  || { echo "FAIL case3: expected idempotent exit 0 when already staged"; fail=1; }

if [ "$fail" -eq 0 ]; then
  echo "stage-test-model self-test: PASS"
else
  echo "stage-test-model self-test: FAIL"
  exit 1
fi
