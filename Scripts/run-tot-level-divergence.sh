#!/usr/bin/env bash
# Per-level ToT sibling-divergence evidence on gsm8k + humaneval (#683) —
# MEASUREMENT, not CI.
#
# Runs `Inferlets/chat-apc/tot_level_divergence.py` against a real `pie serve`
# loading a real GGUF: the PRODUCTION-default tree-of-thought shape (breadth 3,
# depth 2, beam 2, thinking on, temp 0.7) over the pinned gsm8k + humaneval
# prompt sets, reporting sibling divergence at EACH level. The numbers (and the
# in-engine `[chat-apc] tot diversity:` log lines) decide whether the #523
# diversity machinery actually keeps `breadth` forks distinct on real tasks.
#
# Self-bootstraps pie (Metal) + the production chat-apc wasm, stages the GGUF,
# and emits the pinned datasets if absent. Mirrors run-tot-diversity-probe.sh;
# `uv` and (cold) network to stage the GGUF + datasets are the only
# prerequisites it can't build.
#
# Usage: Scripts/run-tot-level-divergence.sh
#   DATASETS=gsm8k,humaneval        datasets to drive (must be in datasets.lock)
#   PIE_TEST_TOT_MAX_PROMPTS=4       prompts per dataset
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

RUN_DIR="/tmp/tot-level-divergence-$$"
sweep() {
  pkill -KILL -f "$RUN_DIR/.*/config\.toml" 2>/dev/null || true
  rm -rf "$RUN_DIR" 2>/dev/null || true
}
trap sweep EXIT

PIE_BIN="Vendor/pie/target/release/pie"
WASM="Inferlets/chat-apc/prebuilt/chat-apc.wasm"
PYDIR="Vendor/pie/client/python"

if ! command -v uv >/dev/null 2>&1; then
  echo "[tot-lvl] FATAL: 'uv' not found on PATH (https://docs.astral.sh/uv/)." >&2
  exit 2
fi
if [ ! -x "$PIE_BIN" ]; then
  echo "[tot-lvl] pie engine missing — building (PIE_PORTABLE_METAL=1)…"
  (cd Vendor/pie && PIE_PORTABLE_METAL=1 cargo build -p pie-server --release)
fi
if [ ! -f "$WASM" ]; then
  echo "[tot-lvl] chat-apc wasm missing — building…"
  Scripts/stamp-chat-apc.sh build
fi

# Emit the pinned prompt sets (gitignored; reproducible from datasets.lock).
DATASETS="${DATASETS:-gsm8k,humaneval}"
IFS=',' read -r -a _DS <<< "$DATASETS"
for ds in "${_DS[@]}"; do
  ds="$(echo "$ds" | tr -d '[:space:]')"
  [ -z "$ds" ] && continue
  if [ ! -f "Scripts/benchmark/data/$ds.jsonl" ]; then
    echo "[tot-lvl] emitting pinned dataset: $ds"
    "Scripts/benchmark/prep_$ds.sh"
  fi
done

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
  echo "[tot-lvl] staged from HF cache → $CACHED"
else
  echo "[tot-lvl] downloading $REPO/$FILE → $MODEL_PATH"
  curl -sSL -o "$MODEL_PATH" "https://huggingface.co/$REPO/resolve/main/$FILE?download=true"
fi

mkdir -p "$ROOT/logs"
LOG="$ROOT/logs/test-$(date +%Y%m%d-%H%M%S)-tot-level-divergence.log"
echo "[tot-lvl] running (log: $LOG)"
set +e
DATASETS="$DATASETS" \
PIE_BENCH_SLUG="$SLUG" \
PIE_BENCH_MODEL_PATH="$MODEL_PATH" \
  uv run --project "$PYDIR" --with httpx \
    python Inferlets/chat-apc/tot_level_divergence.py 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}
set -e
echo "[tot-lvl] rc=$rc (0=run completed; per-level numbers in log)"
exit "$rc"
