#!/usr/bin/env bash
#
# Fast Think (speculative decoding) correctness smoke + measurement (#510,
# absorbs #430).
#
# Runs the chat-apc speculative-decode suites against pie's **portable
# Metal** driver with a REAL cached model (real weights, real GPU):
#
#   * spec_smoke_real.py — correctness smoke: SHORT-WINDOW greedy
#                          token-equivalence (spec == plain at 64 tok; not
#                          unconditional — see #592), at least one accepted
#                          draft, and the forced-tool gate.
#   * spec_bench_real.py — measurement harness: per-scenario latency
#                          (TTFT / wall / decode tok/s) and speculation
#                          metrics (proposed/accepted/rejected, accepted
#                          ratio, avg tokens/step) for baseline vs Fast
#                          Think, with a machine-readable JSON artifact.
#
# Opt-in only — NOT part of `make test`. Self-bootstraps the two build
# inputs (pie binary, chat-apc wasm); fails loud with the exact fix
# command if the model weights are absent (it will NOT download them).
#
# Knobs (env):
#   MODEL        HF repo to bench (default Qwen/Qwen3-0.6B)
#   MAX_TOKENS   decode length per run (default 256)
#   REPS         repetitions per (scenario, profile) (default 1)
#   BENCH_OUT    JSON artifact path (default spec_bench_<model>.json)
#   SMOKE_ONLY=1 run only the correctness smoke
#   BENCH_ONLY=1 run only the measurement harness
#
# Usage: Scripts/run-spec-bench.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PIE_BIN="Vendor/pie/target/release/pie"
WASM="Inferlets/chat-apc/prebuilt/chat-apc.wasm"
PYDIR="Vendor/pie/client/python"
MODEL="${MODEL:-Qwen/Qwen3-0.6B}"

if ! command -v uv >/dev/null 2>&1; then
  echo "[spec-bench] FATAL: 'uv' not found on PATH." >&2
  echo "            install it: https://docs.astral.sh/uv/getting-started/installation/" >&2
  exit 2
fi

# Self-bootstrap: build the pie engine binary if missing. NOTE: a stale
# binary is NOT auto-rebuilt — after a Vendor/pie pin bump run
# `make engine-build` to refresh before trusting a measurement.
if [ ! -x "$PIE_BIN" ]; then
  echo "[spec-bench] pie engine binary missing — building (make engine-build)…"
  (cd Vendor/pie && PIE_PORTABLE_METAL=1 cargo build -p pie-server --release)
fi

# Self-bootstrap: build the chat-apc wasm if missing.
if [ ! -f "$WASM" ]; then
  echo "[spec-bench] chat-apc wasm missing — building (Scripts/stamp-chat-apc.sh build)…"
  Scripts/stamp-chat-apc.sh build
fi

# Require REAL weights (unlike the dummy-driver HTTP E2E). A resolved
# weight artifact must exist under the snapshot — a partial HF download can
# leave a hub dir or metadata-only with no weights, which would surface as
# a confusing engine load error. Fail loud with the exact fetch command.
HF_CACHE="${HF_HUB_CACHE:-${HF_HOME:-$HOME/.cache/huggingface}/hub}"
MODEL_DIR="$HF_CACHE/models--${MODEL//\//--}/snapshots"
if ! find -L "$MODEL_DIR" -type f \
     \( -name '*.safetensors' -o -name '*.gguf' -o -name '*.bin' \) \
     2>/dev/null | grep -q .; then
  echo "[spec-bench] FATAL: no resolved weights for '$MODEL' under $HF_CACHE." >&2
  echo "            The portable Metal driver needs the real weights (not just config/tokenizer)." >&2
  echo "            Fetch the model:" >&2
  echo "              uv run --with huggingface_hub python -c \\" >&2
  echo "                \"from huggingface_hub import snapshot_download as d; d('$MODEL')\"" >&2
  exit 2
fi

run() {
  local script="$1"
  echo ""
  echo "=============================================================="
  echo "[spec-bench] running $script  (MODEL=$MODEL)"
  echo "=============================================================="
  MODEL="$MODEL" uv run --project "$PYDIR" --with httpx python "$script"
}

if [ "${BENCH_ONLY:-0}" != "1" ]; then
  run "Inferlets/chat-apc/spec_smoke_real.py"
fi
if [ "${SMOKE_ONLY:-0}" != "1" ]; then
  run "Inferlets/chat-apc/spec_bench_real.py"
fi

echo ""
echo "[spec-bench] done."
