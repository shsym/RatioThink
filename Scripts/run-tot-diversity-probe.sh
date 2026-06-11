#!/usr/bin/env bash
# Level-1 ToT sibling-diversity probe (portable Metal) — MEASUREMENT, not CI.
#
# Runs `Inferlets/chat-apc/tot_diversity_probe.py` against a real `pie serve`
# loading a real GGUF: depth-1 tree-of-thought searches at the production
# DEFAULT_BREADTH over representative prompts, sweeping the branch-generation
# temperature (default 0.7,1.0,1.3) and reporting pairwise sibling-similarity
# metrics. The numbers decide whether DEFAULT_TEMPERATURE actually buys
# branch diversity (the design leans on sampling temperature alone at
# level 1).
#
# Self-bootstraps pie (Metal) + the production chat-apc wasm and stages the
# GGUF. `uv` and (cold) network to stage the GGUF are the only prerequisites
# it can't build. Mirrors run-tot-batched-e2e.sh; no feature wasm needed —
# the probe drives only production-default request shapes.
#
# Usage: Scripts/run-tot-diversity-probe.sh
#   PIE_TEST_TOT_TEMPS=0.7,1.0,1.3  temperatures to sweep
#   PIE_TEST_TOT_REPEATS=2          searches per (prompt, temperature) cell
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

RUN_DIR="/tmp/tot-diversity-probe-$$"
sweep() {
  pkill -KILL -f "$RUN_DIR/.*/config\.toml" 2>/dev/null || true
  rm -rf "$RUN_DIR" 2>/dev/null || true
}
trap sweep EXIT

PIE_BIN="Vendor/pie/target/release/pie"
WASM="Inferlets/chat-apc/prebuilt/chat-apc.wasm"
PYDIR="Vendor/pie/client/python"

if ! command -v uv >/dev/null 2>&1; then
  echo "[tot-div] FATAL: 'uv' not found on PATH (https://docs.astral.sh/uv/)." >&2
  exit 2
fi
if [ ! -x "$PIE_BIN" ]; then
  echo "[tot-div] pie engine missing — building (PIE_PORTABLE_METAL=1)…"
  (cd Vendor/pie && PIE_PORTABLE_METAL=1 cargo build -p pie-server --release)
fi
if [ ! -f "$WASM" ]; then
  echo "[tot-div] chat-apc wasm missing — building…"
  Scripts/stamp-chat-apc.sh build
fi

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
  echo "[tot-div] staged from HF cache → $CACHED"
else
  echo "[tot-div] downloading $REPO/$FILE → $MODEL_PATH"
  curl -sSL -o "$MODEL_PATH" "https://huggingface.co/$REPO/resolve/main/$FILE?download=true"
fi

mkdir -p "$ROOT/logs"
LOG="$ROOT/logs/test-$(date +%Y%m%d-%H%M%S)-tot-diversity-probe.log"
echo "[tot-div] running (log: $LOG)"
set +e
PIE_BENCH_SLUG="$SLUG" \
PIE_BENCH_MODEL_PATH="$MODEL_PATH" \
  uv run --project "$PYDIR" --with httpx \
    python Inferlets/chat-apc/tot_diversity_probe.py 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}
set -e
echo "[tot-div] rc=$rc (0=probe completed; numbers in log)"
exit "$rc"