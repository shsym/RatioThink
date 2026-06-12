#!/usr/bin/env bash
#
# Real-engine APC prefix-cache smoke (#529, operator-gated tier).
#
# Runs Inferlets/chat-apc/cache_smoke_real.py against a REAL portable-Metal pie
# engine and a real cached model. This is NOT CI: it exercises actual
# save/open KV reuse and asserts the second turn hits the saved boundary.
#
# Prereqs this script CANNOT fully supply:
#   * `uv` on PATH.
#   * The real model WEIGHTS in the HF cache (default Qwen/Qwen3-0.6B).
#     The Python harness boots the real engine; without weights the run fails
#     with the engine's authoritative model-resolution/load error.
#
# Self-bootstrap:
#   * Builds Vendor/pie/target/release/pie with portable Metal if missing.
#   * Builds Inferlets/chat-apc/prebuilt/chat-apc.wasm if missing.
#
# Knobs:
#   MODEL — served model id (default Qwen/Qwen3-0.6B).
#
# Usage: Scripts/run-cache-smoke-real-e2e.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PIE_BIN="Vendor/pie/target/release/pie"
WASM="Inferlets/chat-apc/prebuilt/chat-apc.wasm"
PYDIR="Vendor/pie/client/python"
HARNESS="${CACHE_SMOKE_REAL_HARNESS:-Inferlets/chat-apc/cache_smoke_real.py}"
RUNNER="${CACHE_SMOKE_REAL_RUNNER:-}"

export MODEL="${MODEL:-Qwen/Qwen3-0.6B}"
export CACHE_SMOKE_REAL_HARNESS="$HARNESS"

echo "[cache-real] real-engine APC cache smoke (MODEL=$MODEL)"

if [ -n "$RUNNER" ]; then
  "$RUNNER"
  exit $?
fi

if ! command -v uv >/dev/null 2>&1; then
  echo "[cache-real] FATAL: 'uv' not found on PATH." >&2
  echo "             install it: https://docs.astral.sh/uv/getting-started/installation/" >&2
  exit 2
fi

if [ ! -x "$PIE_BIN" ]; then
  echo "[cache-real] pie engine binary missing — building portable-Metal (this is slow)…"
  (cd Vendor/pie && PIE_PORTABLE_METAL=1 cargo build -p pie-server --release)
fi

if [ ! -f "$WASM" ]; then
  echo "[cache-real] chat-apc wasm missing — building (Scripts/stamp-chat-apc.sh build)…"
  Scripts/stamp-chat-apc.sh build
fi

HF_CACHE="${HF_HUB_CACHE:-${HF_HOME:-$HOME/.cache/huggingface}/hub}"
REPO="models--$(printf '%s' "$MODEL" | sed 's#/#--#g')"
if ! find -L "$HF_CACHE/$REPO/snapshots" -type f \
        \( -name '*.safetensors' -o -name '*.gguf' -o -name '*.bin' \) 2>/dev/null | grep -q .; then
  echo "[cache-real] NOTE: no real weights for $MODEL under $HF_CACHE." >&2
  echo "             Fetch them with: uv run --with huggingface_hub python -c \\" >&2
  echo "               \"from huggingface_hub import snapshot_download as d; d('$MODEL')\"" >&2
fi

uv run --project "$PYDIR" --with httpx python "$HARNESS"
