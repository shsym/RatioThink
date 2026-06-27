#!/usr/bin/env bash
#
# ToT task-ACCURACY runner.
#
# Default mode (#852, profile): run identical GSM8K prompts through the SHIPPED
# tree-of-thought profile (advanced dispatch via inferlet:"tree-of-thought" over
# /v1/chat/completions) and an ordinary single-pass /v1/chat/completions
# baseline.  It emits per-item and aggregate accuracy/token/latency deltas.
#
# Academic mode (#657, opt-in): set TOT_ACCURACY_MODE=academic to run the
# faithful host-side BFS harness in Inferlets/chat-apc/tot_accuracy_real.py.
#
# Self-bootstraps all three build inputs (pie binary, chat-apc wasm, dataset
# prompt+reference sets). Fails loud with the exact fix command if the model
# weights are absent (it will NOT download them).
#
# CODE EXECUTION: HumanEval/MBPP grading executes model-generated Python in a
# subprocess (see grade.py). This is why the bench is operator-gated, never CI.
#
# Knobs (env):
#   TOT_ACCURACY_MODE profile|academic (default profile)
#   MODELS       comma list for profile mode, smallest-first by default
#   MODEL        one HF repo (academic default Qwen/Qwen3-8B; profile maps to MODELS)
#   MAX_TOKENS   max tokens per ToT node / per chain (default 512)
#   MAX_PROMPTS  prompts measured per dataset, canonical-order prefix
#   TOT_WIDTH    academic branches k; profile fallback for TOT_BREADTH
#   TOT_BREADTH  profile shipped-ToT breadth (default 2)
#   DATASETS     profile default gsm8k; academic default all graded+locked
#   PROFILE_ACCURACY_OUT / ACCURACY_OUT JSON artifact path
#
# Usage: Scripts/run-tot-accuracy.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PIE_BIN="Vendor/pie/target/release/pie"
WASM="Inferlets/chat-apc/prebuilt/chat-apc.wasm"
PYDIR="Vendor/pie/client/python"
TOT_ACCURACY_MODE="${TOT_ACCURACY_MODE:-profile}"
if [ "$TOT_ACCURACY_MODE" = "profile" ]; then
  if [ -z "${MODELS:-}" ]; then
    if [ -n "${MODEL:-}" ]; then
      MODELS="$MODEL"
    else
      MODELS="Qwen/Qwen3-0.6B,Qwen/Qwen3-4B,Qwen/Qwen3-8B,Qwen/Qwen3-14B-GGUF"
    fi
  fi
  DATASETS="${DATASETS:-gsm8k}"
else
  MODEL="${MODEL:-Qwen/Qwen3-8B}"
  MODELS="${MODELS:-$MODEL}"
fi

if ! command -v uv >/dev/null 2>&1; then
  echo "[tot-accuracy] FATAL: 'uv' not found on PATH." >&2
  echo "              install it: https://docs.astral.sh/uv/getting-started/installation/" >&2
  exit 2
fi

# Self-bootstrap the pie engine (build if missing OR stale vs the pin) — a stale
# binary silently measures the OLD engine. Mirrors run-spec-matrix.sh.
PIE_SHA="$(git -C Vendor/pie rev-parse HEAD 2>/dev/null || echo unknown)"
STAMP="$PIE_BIN.built-from-sha"
build_engine() {
  (cd Vendor/pie && PIE_PORTABLE_METAL=1 cargo build -p pie-server --release)
  printf '%s\n' "$PIE_SHA" >"$STAMP"
}
if [ ! -x "$PIE_BIN" ]; then
  echo "[tot-accuracy] pie engine binary missing — building…"
  build_engine
elif [ "$PIE_SHA" = "unknown" ]; then
  echo "[tot-accuracy] WARNING: cannot resolve Vendor/pie SHA; measuring existing binary." >&2
elif [ ! -f "$STAMP" ] || [ "$(cat "$STAMP")" != "$PIE_SHA" ]; then
  echo "[tot-accuracy] pie engine binary STALE vs pin — rebuilding…" >&2
  build_engine
fi

# Self-bootstrap the chat-apc wasm (the production prebuilt; default ToT exec).
if [ ! -f "$WASM" ]; then
  echo "[tot-accuracy] chat-apc wasm missing — building…"
  Scripts/stamp-chat-apc.sh build
fi

# Require REAL weights (will NOT download). Same guard as run-spec-matrix.sh.
HF_CACHE="${HF_HUB_CACHE:-${HF_HOME:-$HOME/.cache/huggingface}/hub}"
for model in $(printf '%s' "$MODELS" | tr ',' ' '); do
  MODEL_DIR="$HF_CACHE/models--${model//\//--}/snapshots"
  if ! find -L "$MODEL_DIR" -type f \
       \( -name '*.safetensors' -o -name '*.gguf' -o -name '*.bin' \) \
       2>/dev/null | grep -q .; then
    echo "[tot-accuracy] FATAL: no resolved weights for '$model' under $HF_CACHE." >&2
    echo "              Fetch the model:" >&2
    echo "                uv run --with huggingface_hub python -c \\" >&2
    echo "                  \"from huggingface_hub import snapshot_download as d; d('$model')\"" >&2
    exit 2
  fi
done

# Self-bootstrap the graded dataset prompt+reference sets (regenerated from the
# pinned revision; data/ is gitignored). Only the GRADED rows the harness needs.
GRADED="$(uv run --quiet --with "datasets>=2.18" python - <<'PY'
import json, pathlib
lock = json.loads(pathlib.Path("Scripts/benchmark/datasets.lock").read_text())
print(" ".join(k for k, v in lock.get("datasets", {}).items() if v.get("grader")))
PY
)"
if [ "$TOT_ACCURACY_MODE" = "profile" ]; then
  SEL="$DATASETS"
else
  SEL="${DATASETS:-$GRADED}"
fi
for key in $(printf '%s' "$SEL" | tr ',' ' '); do
  if [ ! -f "Scripts/benchmark/data/$key.jsonl" ]; then
    echo "[tot-accuracy] prompt set for '$key' missing — running prep_$key.sh…"
    "Scripts/benchmark/prep_$key.sh"
  fi
done

echo ""
echo "=============================================================="
echo "[tot-accuracy] mode=$TOT_ACCURACY_MODE models=$MODELS datasets=$SEL"
echo "=============================================================="
if [ "$TOT_ACCURACY_MODE" = "profile" ]; then
  MODELS="$MODELS" DATASETS="$SEL" uv run --project "$PYDIR" --with httpx --with jsonschema \
    --with tokenizers --with huggingface_hub \
    python Inferlets/chat-apc/tot_profile_accuracy.py
elif [ "$TOT_ACCURACY_MODE" = "academic" ]; then
  MODEL="$MODEL" DATASETS="$SEL" uv run --project "$PYDIR" --with httpx --with jsonschema \
    --with tokenizers --with huggingface_hub \
    python Inferlets/chat-apc/tot_accuracy_real.py
else
  echo "[tot-accuracy] FATAL: TOT_ACCURACY_MODE must be 'profile' or 'academic' (got '$TOT_ACCURACY_MODE')." >&2
  exit 2
fi

echo ""
echo "[tot-accuracy] done."
