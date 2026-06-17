#!/usr/bin/env bash
#
# Spec-decode benefit MATRIX runner: method × workload over PUBLIC pinned
# datasets (#652, extends #510's Scripts/run-spec-bench.sh).
#
# Boots pie's portable Metal driver against a real cached model and runs
# Inferlets/chat-apc/spec_matrix_real.py, which sweeps every dataset prepared
# by Scripts/benchmark/prep_*.sh (rows) under plain vs n-gram drafting (columns)
# and writes a method×workload artifact + rendered matrix.
#
# Self-bootstraps all three build inputs (pie binary, chat-apc wasm, dataset
# prompt sets). Fails loud with the exact fix command if the model weights are
# absent (it will NOT download them).
#
# Knobs (env):
#   MODEL        HF repo to bench (default Qwen/Qwen3-8B — a 7-14B target; 0.6B
#                is too cheap to amortize drafting, per #510)
#   MAX_TOKENS   decode length per run (default 256)
#   MAX_PROMPTS  prompts measured per dataset, canonical-order prefix
#                (default 16; 0 = the WHOLE split — the opt-in long run)
#   DATASETS     comma list to restrict rows (default: all locked)
#   MATRIX_OUT   JSON artifact path
#
# Usage: Scripts/run-spec-matrix.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PIE_BIN="Vendor/pie/target/release/pie"
WASM="Inferlets/chat-apc/prebuilt/chat-apc.wasm"
PYDIR="Vendor/pie/client/python"
MODEL="${MODEL:-Qwen/Qwen3-8B}"

if ! command -v uv >/dev/null 2>&1; then
  echo "[spec-matrix] FATAL: 'uv' not found on PATH." >&2
  echo "             install it: https://docs.astral.sh/uv/getting-started/installation/" >&2
  exit 2
fi

# Self-bootstrap the pie engine (build if missing OR stale vs the pin), exactly
# like run-spec-bench.sh — a stale binary silently measures the OLD engine.
PIE_SHA="$(git -C Vendor/pie rev-parse HEAD 2>/dev/null || echo unknown)"
STAMP="$PIE_BIN.built-from-sha"
build_engine() {
  (cd Vendor/pie && PIE_PORTABLE_METAL=1 cargo build -p pie-server --release)
  printf '%s\n' "$PIE_SHA" >"$STAMP"
}
if [ ! -x "$PIE_BIN" ]; then
  echo "[spec-matrix] pie engine binary missing — building…"
  build_engine
elif [ "$PIE_SHA" = "unknown" ]; then
  echo "[spec-matrix] WARNING: cannot resolve Vendor/pie SHA; measuring existing binary." >&2
elif [ ! -f "$STAMP" ] || [ "$(cat "$STAMP")" != "$PIE_SHA" ]; then
  echo "[spec-matrix] pie engine binary STALE vs pin — rebuilding…" >&2
  build_engine
fi

# Self-bootstrap the chat-apc wasm.
if [ ! -f "$WASM" ]; then
  echo "[spec-matrix] chat-apc wasm missing — building…"
  Scripts/stamp-chat-apc.sh build
fi

# Require REAL weights (will NOT download). Same guard as run-spec-bench.sh.
HF_CACHE="${HF_HUB_CACHE:-${HF_HOME:-$HOME/.cache/huggingface}/hub}"
MODEL_DIR="$HF_CACHE/models--${MODEL//\//--}/snapshots"
if ! find -L "$MODEL_DIR" -type f \
     \( -name '*.safetensors' -o -name '*.gguf' -o -name '*.bin' \) \
     2>/dev/null | grep -q .; then
  echo "[spec-matrix] FATAL: no resolved weights for '$MODEL' under $HF_CACHE." >&2
  echo "             Fetch the model:" >&2
  echo "               uv run --with huggingface_hub python -c \\" >&2
  echo "                 \"from huggingface_hub import snapshot_download as d; d('$MODEL')\"" >&2
  exit 2
fi

# Self-bootstrap the dataset prompt sets (regenerated from the pinned revision;
# data/ is gitignored). Only the rows actually requested are prepped.
SEL="${DATASETS:-}"
if [ -z "$SEL" ]; then
  SEL="$(uv run --quiet --with "datasets>=2.18" python Scripts/benchmark/prep_datasets.py keys)"
fi
for key in $(printf '%s' "$SEL" | tr ',' ' '); do
  if [ ! -f "Scripts/benchmark/data/$key.jsonl" ]; then
    echo "[spec-matrix] prompt set for '$key' missing — running prep_$key.sh…"
    "Scripts/benchmark/prep_$key.sh"
  fi
done

echo ""
echo "=============================================================="
echo "[spec-matrix] running spec_matrix_real.py  (MODEL=$MODEL)"
echo "=============================================================="
MODEL="$MODEL" uv run --project "$PYDIR" --with httpx \
  python Inferlets/chat-apc/spec_matrix_real.py

echo ""
echo "[spec-matrix] done."
