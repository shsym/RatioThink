#!/usr/bin/env bash
#
# Real-model Tree-of-Thought smoke (#523) — gated, NOT in CI.
#
# Boots `pie serve` with the portable Metal driver over the staged
# Qwen3-0.6B-Q8_0 GGUF and drives real ToT searches, asserting that
# candidate branches are not near-duplicates and that the value evaluator
# parses real scores (not the input-order fallback). Records raw branch
# diversity + scorer evidence to the log.
#
# Self-bootstraps its three inputs, failing loud with the exact fix
# command (never a bare error-exit / silent skip).
#
# Usage: Scripts/run-tot-real-smoke.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PIE_BIN="Vendor/pie/target/release/pie"
WASM="Inferlets/chat-apc/prebuilt/chat-apc.wasm"
PYDIR="Vendor/pie/client/python"
MODEL="test-models/Qwen3-0.6B-Q8_0.gguf"

if ! command -v uv >/dev/null 2>&1; then
  echo "[tot-smoke] FATAL: 'uv' not found on PATH." >&2
  echo "            install it: https://docs.astral.sh/uv/getting-started/installation/" >&2
  exit 2
fi

# Self-bootstrap: pie engine binary (portable Metal driver).
if [ ! -x "$PIE_BIN" ]; then
  echo "[tot-smoke] pie engine binary missing — building (make engine-build)…"
  make engine-build
fi

# Self-bootstrap: chat-apc wasm.
if [ ! -f "$WASM" ]; then
  echo "[tot-smoke] chat-apc wasm missing — building (make build-inferlets)…"
  make build-inferlets
fi

# Self-bootstrap: the staged GGUF fixture (links from HF cache or prints
# the exact fetch command).
if [ ! -f "$MODEL" ]; then
  echo "[tot-smoke] model fixture missing — staging (Scripts/stage-test-model.sh)…"
  Scripts/stage-test-model.sh
fi

echo "[tot-smoke] pie=$PIE_BIN model=$MODEL"
uv run --project "$PYDIR" --with httpx python Inferlets/chat-apc/tot_real_smoke.py
