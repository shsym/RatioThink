#!/usr/bin/env bash
# #458 — real-engine BATCHED tree-of-thought e2e (portable Metal).
#
# Runs `Inferlets/chat-apc/tot_real_e2e.py` against a real `pie serve` loading
# a real GGUF on the portable Metal driver, driving a multi-level
# `exec:"phased_concurrent"` (batched generation + phased concurrent scoring)
# non-streaming ToT and asserting tree shape/status. This is the #458
# acceptance coverage that the dummy driver (fabricated outputs) cannot give.
#
# Self-bootstraps pie (Metal) + chat-apc wasm and stages the GGUF, then runs
# in the pie_client uv env. `uv` and (cold) network to stage the GGUF are the
# only prerequisites it can't build.
#
# Usage: Scripts/run-tot-batched-e2e.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

RUN_DIR="/tmp/tot-batched-e2e-$$"
sweep() {
  pkill -KILL -f "$RUN_DIR/.*/config\.toml" 2>/dev/null || true
  rm -rf "$RUN_DIR" 2>/dev/null || true
}
trap sweep EXIT

PIE_BIN="Vendor/pie/target/release/pie"
WASM="Inferlets/chat-apc/prebuilt/chat-apc.wasm"
PYDIR="Vendor/pie/client/python"

if ! command -v uv >/dev/null 2>&1; then
  echo "[tot-batched] FATAL: 'uv' not found on PATH (https://docs.astral.sh/uv/)." >&2
  exit 2
fi
if [ ! -x "$PIE_BIN" ]; then
  echo "[tot-batched] pie engine missing — building (PIE_PORTABLE_METAL=1)…"
  (cd Vendor/pie && PIE_PORTABLE_METAL=1 cargo build -p pie-server --release)
fi
if [ ! -f "$WASM" ]; then
  echo "[tot-batched] chat-apc wasm missing — building…"
  Scripts/stamp-chat-apc.sh build
fi

# Build the exec-strategies wasm: the production prebuilt rejects a
# non-default `exec`, and this test drives `exec=phased_concurrent` (#458).
# Built into the run dir + pointed at via PIE_TOT_WASM (prod prebuilt untouched).
echo "[tot-batched] building exec-strategies wasm…"
( cd Inferlets/chat-apc && cargo build --release --locked --target wasm32-wasip2 --features exec-strategies >/dev/null )
mkdir -p "$RUN_DIR"
FEATURE_WASM="$RUN_DIR/chat-apc-exec.wasm"
cp "$ROOT/Inferlets/chat-apc/target/wasm32-wasip2/release/chat_apc.wasm" "$FEATURE_WASM"

REPO="${PIE_BENCH_REPO:-Qwen/Qwen3-0.6B-GGUF}"
FILE="${PIE_BENCH_FILE:-Qwen3-0.6B-Q8_0.gguf}"
SLUG="$REPO/$FILE"
MODELS_ROOT="$RUN_DIR/models"
MODEL_PATH="$MODELS_ROOT/$SLUG"
mkdir -p "$(dirname "$MODEL_PATH")"
HF_CACHE="${HF_HUB_CACHE:-$HOME/.cache/huggingface/hub}"
CACHED="$(ls "$HF_CACHE"/models--Qwen--Qwen3-0.6B-GGUF/snapshots/*/"$FILE" 2>/dev/null | head -1 || true)"
if [ -n "$CACHED" ] && [ -f "$CACHED" ]; then
  ln -sf "$CACHED" "$MODEL_PATH"
  echo "[tot-batched] staged from HF cache → $CACHED"
else
  echo "[tot-batched] downloading $REPO/$FILE → $MODEL_PATH"
  curl -sSL -o "$MODEL_PATH" "https://huggingface.co/$REPO/resolve/main/$FILE?download=true"
fi

mkdir -p "$ROOT/logs"
LOG="$ROOT/logs/test-$(date +%Y%m%d-%H%M%S)-tot-batched-e2e.log"
echo "[tot-batched] running (log: $LOG)"
set +e
PIE_BENCH_SLUG="$SLUG" \
PIE_BENCH_MODEL_PATH="$MODEL_PATH" \
PIE_TOT_WASM="$FEATURE_WASM" \
  uv run --project "$PYDIR" --with httpx \
    python Inferlets/chat-apc/tot_real_e2e.py 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}
set -e
echo "[tot-batched] rc=$rc (0=batched tree well-formed)"
exit "$rc"
