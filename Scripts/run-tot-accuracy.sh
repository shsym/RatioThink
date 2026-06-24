#!/usr/bin/env bash
#
# ToT task-ACCURACY matrix runner: single-chain CoT vs ToT(width=k, depth=1)
# over PUBLIC pinned GRADED datasets (#657, extends the #652 throughput matrix
# with a deterministic correctness axis).
#
# Boots pie's portable Metal driver against a real cached model and runs
# Inferlets/chat-apc/tot_accuracy_real.py, which — for every GRADED dataset
# prepared by Scripts/benchmark/prep_*.sh (GSM8K, HumanEval, MBPP, JSONSchema) —
# decodes a single greedy CoT chain and a ToT(width=k, depth=1) search through
# the SAME /v1/chat/completions advanced-profile envelope, grades both answers with the dataset's
# deterministic grader (Inferlets/chat-apc/grade.py), and writes an
# accuracy/token artifact + rendered matrix.
#
# Self-bootstraps all three build inputs (pie binary, chat-apc wasm, dataset
# prompt+reference sets). Fails loud with the exact fix command if the model
# weights are absent (it will NOT download them).
#
# CODE EXECUTION: HumanEval/MBPP grading executes model-generated Python in a
# subprocess (see grade.py). This is why the bench is operator-gated, never CI.
#
# Knobs (env):
#   MODEL        HF repo to bench (default Qwen/Qwen3-8B — a 7-14B target)
#   MAX_TOKENS   max tokens per ToT node / per chain (default 512)
#   MAX_PROMPTS  prompts measured per dataset, canonical-order prefix
#                (default 12; 0 = the WHOLE split — the opt-in long run)
#   TOT_WIDTH    branches k for the ToT column (default 4; [1,5])
#   DATASETS     comma list to restrict rows (default: all graded+locked)
#   ACCURACY_OUT JSON artifact path
#
# Usage: Scripts/run-tot-accuracy.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PIE_BIN="Vendor/pie/target/release/pie"
WASM="Inferlets/chat-apc/prebuilt/chat-apc.wasm"
PYDIR="Vendor/pie/client/python"
MODEL="${MODEL:-Qwen/Qwen3-8B}"

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
MODEL_DIR="$HF_CACHE/models--${MODEL//\//--}/snapshots"
if ! find -L "$MODEL_DIR" -type f \
     \( -name '*.safetensors' -o -name '*.gguf' -o -name '*.bin' \) \
     2>/dev/null | grep -q .; then
  echo "[tot-accuracy] FATAL: no resolved weights for '$MODEL' under $HF_CACHE." >&2
  echo "              Fetch the model:" >&2
  echo "                uv run --with huggingface_hub python -c \\" >&2
  echo "                  \"from huggingface_hub import snapshot_download as d; d('$MODEL')\"" >&2
  exit 2
fi

# Self-bootstrap the graded dataset prompt+reference sets (regenerated from the
# pinned revision; data/ is gitignored). Only the GRADED rows the harness needs.
GRADED="$(uv run --quiet --with "datasets>=2.18" python - <<'PY'
import json, pathlib
lock = json.loads(pathlib.Path("Scripts/benchmark/datasets.lock").read_text())
print(" ".join(k for k, v in lock.get("datasets", {}).items() if v.get("grader")))
PY
)"
SEL="${DATASETS:-$GRADED}"
for key in $(printf '%s' "$SEL" | tr ',' ' '); do
  if [ ! -f "Scripts/benchmark/data/$key.jsonl" ]; then
    echo "[tot-accuracy] prompt set for '$key' missing — running prep_$key.sh…"
    "Scripts/benchmark/prep_$key.sh"
  fi
done

echo ""
echo "=============================================================="
echo "[tot-accuracy] running tot_accuracy_real.py  (MODEL=$MODEL)"
echo "=============================================================="
MODEL="$MODEL" uv run --project "$PYDIR" --with httpx --with jsonschema \
  --with tokenizers --with huggingface_hub \
  python Inferlets/chat-apc/tot_accuracy_real.py

echo ""
echo "[tot-accuracy] done."
