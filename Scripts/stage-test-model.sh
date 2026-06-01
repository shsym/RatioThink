#!/usr/bin/env bash
#
# Stage the Qwen3-0.6B-Q8_0.gguf GUI-test fixture at repo-root test-models/.
#
# Self-bootstrap-or-guide contract: if the model is already in the local
# Hugging Face cache (repo Qwen/Qwen3-0.6B-GGUF), symlink it into
# test-models/ (fast, no network); otherwise print the EXACT download
# command and exit non-zero. Never silently skips, never fails cryptically.
#
# The model-dependent GUI tests (S4 helper-menu "Engine: stopped") resolve
# the seeded "chat" profile's model from this fixture. Without it they
# XCTSkip with the same instruction printed below.
#
# macOS / BSD userland only (no GNU-specific flags).
#
# Overridable for the contract self-test (test-run-stage-test-model.sh):
#   STAGE_TEST_MODEL_DEST   full path to the staged .gguf (default test-models/)
#   HF_HUB_CACHE / HF_HOME  Hugging Face cache location (standard HF vars)
set -euo pipefail

REPO_ID="Qwen/Qwen3-0.6B-GGUF"
FILE="Qwen3-0.6B-Q8_0.gguf"
CACHE_DIRNAME="models--Qwen--Qwen3-0.6B-GGUF"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEST="${STAGE_TEST_MODEL_DEST:-$REPO_ROOT/test-models/$FILE}"

# `-f` follows symlinks: true only when the link target actually resolves,
# so a dangling fixture re-stages instead of looking present.
if [ -f "$DEST" ]; then
  echo "stage-test-model: fixture already present at $DEST"
  exit 0
fi

# Resolve the HF hub cache dir (HF_HUB_CACHE > HF_HOME/hub > default).
if [ -n "${HF_HUB_CACHE:-}" ]; then
  HUB="$HF_HUB_CACHE"
elif [ -n "${HF_HOME:-}" ]; then
  HUB="$HF_HOME/hub"
else
  HUB="$HOME/.cache/huggingface/hub"
fi

CACHED=""
if [ -d "$HUB/$CACHE_DIRNAME/snapshots" ]; then
  # -L follows the snapshot->blob symlinks; require a real resolved file,
  # not a bare dir or a dangling metadata-only entry.
  CACHED="$(find -L "$HUB/$CACHE_DIRNAME/snapshots" -type f -name "$FILE" 2>/dev/null | head -1 || true)"
fi

if [ -n "$CACHED" ]; then
  mkdir -p "$(dirname "$DEST")"
  ln -sfn "$CACHED" "$DEST"
  if [ ! -f "$DEST" ]; then
    echo "stage-test-model: ERROR staged link does not resolve: $DEST -> $CACHED" >&2
    exit 1
  fi
  echo "stage-test-model: linked $DEST -> $CACHED"
  exit 0
fi

cat >&2 <<EOF
stage-test-model: model fixture NOT staged.
  Need:  $FILE  (repo $REPO_ID, ~610 MB)
  Looked in HF cache: $HUB/$CACHE_DIRNAME
  And at:             $DEST

  Download it, then re-run this script:
    huggingface-cli download $REPO_ID --include "$FILE"
    Scripts/stage-test-model.sh
  (newer HF CLI equivalent:  hf download $REPO_ID $FILE )

  Until then the model-dependent GUI tests (S4 helper-menu) XCTSkip.
EOF
exit 1
