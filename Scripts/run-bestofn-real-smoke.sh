#!/usr/bin/env bash
#
# Real-model Best-of-N round-trip smoke — gated, NOT in CI.
#
# Boots `pie serve` with the portable Metal driver over the staged
# Qwen3-0.6B-Q8_0 GGUF and drives the interactive Best-of-N profile across
# multiple /v1/inferlet requests (generate N → pick → think-more, plus the
# open-miss → re-prefill fallback). Asserts parallel-decode co-batch, real
# candidate divergence, KV resume across the request boundary (warm + cold),
# and daemon survival across the multi-round sequence.
#
# Self-bootstraps its three inputs, failing loud with the exact fix command.
#
# Usage: Scripts/run-bestofn-real-smoke.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PIE_BIN="Vendor/pie/target/release/pie"
WASM="Inferlets/chat-apc/prebuilt/chat-apc.wasm"
PYDIR="Vendor/pie/client/python"
MODEL="test-models/Qwen3-0.6B-Q8_0.gguf"

if ! command -v uv >/dev/null 2>&1; then
  echo "[bon-smoke] FATAL: 'uv' not found on PATH." >&2
  echo "            install it: https://docs.astral.sh/uv/getting-started/installation/" >&2
  exit 2
fi

if [ ! -x "$PIE_BIN" ]; then
  echo "[bon-smoke] pie engine binary missing — building (make engine-build)…"
  make engine-build
fi

if [ ! -f "$WASM" ]; then
  echo "[bon-smoke] chat-apc wasm missing — building (make build-inferlets)…"
  make build-inferlets
fi

if [ ! -f "$MODEL" ]; then
  echo "[bon-smoke] model fixture missing — staging (Scripts/stage-test-model.sh)…"
  Scripts/stage-test-model.sh
fi

echo "[bon-smoke] pie=$PIE_BIN model=$MODEL"
uv run --project "$PYDIR" --with httpx python Inferlets/chat-apc/bestofn_real_smoke.py
