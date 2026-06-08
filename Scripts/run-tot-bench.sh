#!/usr/bin/env bash
# #458 — tree-of-thought batched-vs-sequential BENCHMARK (real portable-Metal).
#
# Drives `Inferlets/chat-apc/tot_bench.py` against a real `pie serve` loading a
# real GGUF on the portable Metal driver, A/B-ing the four #458 execution
# strategies (coupled/phased × sequential/concurrent) on ONE warm engine.
# Records wall-clock latency + decode tokens/s per (search-shape, strategy),
# so the 2-phase + batched-generation choices are justified by data, not
# assumed (the operator's #458 measurement requirement).
#
# Self-bootstraps its build inputs (pie engine with Metal, chat-apc wasm) and
# stages the GGUF from the HF cache (or downloads it), then runs the bench in
# the pie_client uv environment with httpx + a tokenizer for real token counts.
#
# Prerequisites it CANNOT build (fail-loud): `uv` on PATH; network to stage the
# GGUF if it isn't already in the HF cache.
#
# Usage: Scripts/run-tot-bench.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BENCH_RUN_DIR="/tmp/tot-bench-$$"
sweep() {
  pkill -KILL -f "$BENCH_RUN_DIR/.*/config\.toml" 2>/dev/null || true
  rm -rf "$BENCH_RUN_DIR" 2>/dev/null || true
}
trap sweep EXIT

PIE_BIN="Vendor/pie/target/release/pie"
WASM="Inferlets/chat-apc/prebuilt/chat-apc.wasm"
PYDIR="Vendor/pie/client/python"

if ! command -v uv >/dev/null 2>&1; then
  echo "[tot-bench] FATAL: 'uv' not found on PATH (https://docs.astral.sh/uv/)." >&2
  exit 2
fi

# Self-bootstrap: Metal-enabled pie engine.
if [ ! -x "$PIE_BIN" ]; then
  echo "[tot-bench] pie engine missing — building (PIE_PORTABLE_METAL=1)…"
  (cd Vendor/pie && PIE_PORTABLE_METAL=1 cargo build -p pie-server --release)
fi
# Build the exec-strategies wasm: the production prebuilt rejects a
# non-default `exec`, so the benchmark needs a `--features exec-strategies`
# build to drive all four strategies (#458). Built into the run dir and
# pointed at via PIE_TOT_WASM (the prod prebuilt is left untouched).
echo "[tot-bench] building exec-strategies wasm…"
( cd Inferlets/chat-apc && cargo build --release --locked --target wasm32-wasip2 --features exec-strategies >/dev/null )
mkdir -p "$BENCH_RUN_DIR"
FEATURE_WASM="$BENCH_RUN_DIR/chat-apc-exec.wasm"
cp "$ROOT/Inferlets/chat-apc/target/wasm32-wasip2/release/chat_apc.wasm" "$FEATURE_WASM"

# Stage the GGUF (symlink from HF cache if present, else download).
REPO="${PIE_BENCH_REPO:-Qwen/Qwen3-0.6B-GGUF}"
FILE="${PIE_BENCH_FILE:-Qwen3-0.6B-Q8_0.gguf}"
SLUG="$REPO/$FILE"
MODELS_ROOT="$BENCH_RUN_DIR/models"
MODEL_PATH="$MODELS_ROOT/$SLUG"
mkdir -p "$(dirname "$MODEL_PATH")"
HF_CACHE="${HF_HUB_CACHE:-$HOME/.cache/huggingface/hub}"
CACHED="$(ls "$HF_CACHE"/models--Qwen--Qwen3-0.6B-GGUF/snapshots/*/"$FILE" 2>/dev/null | head -1 || true)"
if [ -n "$CACHED" ] && [ -f "$CACHED" ]; then
  ln -sf "$CACHED" "$MODEL_PATH"
  echo "[tot-bench] staged from HF cache → $CACHED"
else
  echo "[tot-bench] downloading $REPO/$FILE → $MODEL_PATH"
  curl -sSL -o "$MODEL_PATH" "https://huggingface.co/$REPO/resolve/main/$FILE?download=true"
fi

mkdir -p "$ROOT/logs"
LOG="$ROOT/logs/test-$(date +%Y%m%d-%H%M%S)-tot-bench.log"
echo "[tot-bench] running benchmark (log: $LOG)"
set +e
PIE_BENCH_SLUG="$SLUG" \
PIE_BENCH_MODEL_PATH="$MODEL_PATH" \
PIE_TOT_WASM="$FEATURE_WASM" \
PIE_BENCH_TRIALS="${PIE_BENCH_TRIALS:-3}" \
PIE_BENCH_MAX_TOKENS="${PIE_BENCH_MAX_TOKENS:-128}" \
  uv run --project "$PYDIR" --with httpx --with huggingface_hub --with tokenizers \
    python Inferlets/chat-apc/tot_bench.py 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}
set -e
echo "[tot-bench] rc=$rc (0=ok, trees identical across strategies)"
exit "$rc"
