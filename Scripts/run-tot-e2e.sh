#!/bin/bash
# #413 — REAL-engine tree-of-thought APP-PATH E2E.
#
# Drives a real multi-level ToT beam search through the EXACT Swift path
# the app uses — HTTPEngineClient.dispatchInferlet → toTEventStream →
# ToTTree — against a real `pie serve` loading a real GGUF, and asserts the
# stream reaches a `tree_complete` terminal with a selected answer.
#
# This is the coverage that the Python wire probe (bypasses Swift) and the
# TCC-blocked GUI tests both missed — and where the operator's stall lived:
# PieControlLauncher stopped draining pie's `--debug` stdout+stderr pipe
# after the handshake, so a long ToT search filled the kernel buffer and
# wedged the engine mid-search (no frames, no terminal, no error). A depth>1
# search is the regression guard: it spans the idle gap between levels that
# the single-burst depth-1 case never exercised.
#
# Uses Qwen3-0.6B-GGUF (the seeded ToT default) so the run also exercises
# the `/no_think` reasoning-suppression path. Self-bootstraps missing build
# artifacts or prints the exact command to produce them.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Per-run scratch root; SIGKILL-reap any stray engine of THIS run on exit
# (belt to the harness's own session.shutdown). Scoped to this run's dir so
# a concurrent wrapper is never reaped out from under its live engine.
TOT_RUN_DIR="/tmp/tot-e2e-$$"
sweep() {
  pkill -KILL -f "$TOT_RUN_DIR/.*/config\.toml" 2>/dev/null || true
  pkill -KILL -f "Vendor/pie/target/release/pie serve" 2>/dev/null || true
  rm -rf "$TOT_RUN_DIR" 2>/dev/null || true
}
trap sweep EXIT

REPO="${PIE_TEST_TOT_REPO:-Qwen/Qwen3-0.6B-GGUF}"
FILE="${PIE_TEST_TOT_FILE:-Qwen3-0.6B-Q8_0.gguf}"
SLUG="$REPO/$FILE"                       # 3-segment portable GGUF slug
MODELS_ROOT="$TOT_RUN_DIR/models"
MODEL_PATH="$MODELS_ROOT/$SLUG"

# --- pie engine binary: prefer a release build, fall back to bundled ---
PIE_BIN="${PIE_BIN:-}"
if [ -z "$PIE_BIN" ]; then
  if [ -x "$ROOT/Vendor/pie/target/release/pie" ]; then
    PIE_BIN="$ROOT/Vendor/pie/target/release/pie"
  elif [ -x "/Applications/RatioThink.app/Contents/Resources/pie-engine/pie" ]; then
    PIE_BIN="/Applications/RatioThink.app/Contents/Resources/pie-engine/pie"
    echo "tot-e2e: WARNING no repo build (Vendor/pie/target/release/pie) — using INSTALLED app engine:" >&2
    echo "tot-e2e:          $PIE_BIN (tests the installed build, not this worktree)." >&2
    echo "tot-e2e:          run 'make engine-build' or set PIE_BIN to test the repo binary." >&2
  fi
fi
if [ -z "$PIE_BIN" ] || [ ! -x "$PIE_BIN" ]; then
  echo "tot-e2e: pie engine binary not found." >&2
  echo "tot-e2e: build it →  make engine-build   (produces Vendor/pie/target/release/pie)" >&2
  exit 2
fi

# --- chat-apc inferlet resources --------------------------------------
WASM="$ROOT/Inferlets/chat-apc/prebuilt/chat-apc.wasm"
MANIFEST="$ROOT/Inferlets/chat-apc/Pie.toml"
if [ ! -f "$WASM" ] || [ ! -f "$MANIFEST" ]; then
  echo "tot-e2e: chat-apc resources missing — build them →  make build-inferlets" >&2
  exit 2
fi

# --- stage the GGUF (symlink from HF cache if present, else download) --
mkdir -p "$(dirname "$MODEL_PATH")"
HF_CACHE="${HF_HUB_CACHE:-$HOME/.cache/huggingface/hub}"
CACHED="$(ls "$HF_CACHE"/models--Qwen--Qwen3-0.6B-GGUF/snapshots/*/"$FILE" 2>/dev/null | head -1 || true)"
if [ -n "$CACHED" ] && [ -f "$CACHED" ]; then
  ln -sf "$CACHED" "$MODEL_PATH"
  echo "tot-e2e: staged from HF cache → $CACHED"
else
  if ! curl -sSf -o /dev/null --max-time 20 -r 0-0 "https://huggingface.co/$REPO/resolve/main/$FILE?download=true"; then
    echo "tot-e2e: cannot reach Hugging Face for $REPO/$FILE — network required to stage the model." >&2
    exit 2
  fi
  echo "tot-e2e: downloading $REPO/$FILE → $MODEL_PATH"
  curl -sSL -o "$MODEL_PATH" "https://huggingface.co/$REPO/resolve/main/$FILE?download=true"
fi
echo "tot-e2e: pie engine = $PIE_BIN"

# --- build the harness ------------------------------------------------
echo "tot-e2e: building chat-engine-harness"
swift build --product chat-engine-harness >/dev/null

# --- drive real depth>1 ToT searches through the app path -------------
# PIE_TEST_TOT_DEPTHS drives one search per depth on a single engine boot
# (default "2,3"): the depth=2 case pins the final level, the depth=3 case
# additionally pins a true intermediate depth>1 level, so the "every level
# reasons under thinking:true" invariant (#649) is proven depth-parametrically.
mkdir -p "$ROOT/logs"
LOG="$ROOT/logs/test-$(date +%Y%m%d-%H%M%S)-tot-e2e.log"
echo "tot-e2e: driving ToT app path (log: $LOG)"
set +e
PIE_BIN="$PIE_BIN" \
PIE_TEST_HARNESS_MODEL_SLUG="$SLUG" \
PIE_TEST_HARNESS_MODELS_ROOT="$MODELS_ROOT" \
PIE_TEST_TOT_BREADTH="${PIE_TEST_TOT_BREADTH:-3}" \
PIE_TEST_TOT_DEPTH="${PIE_TEST_TOT_DEPTH:-2}" \
PIE_TEST_TOT_DEPTHS="${PIE_TEST_TOT_DEPTHS:-2,3}" \
PIE_TEST_TOT_BEAM="${PIE_TEST_TOT_BEAM:-2}" \
PIE_TEST_TOT_MAXTOK="${PIE_TEST_TOT_MAXTOK:-256}" \
PIE_TEST_TOT_QUESTION="${PIE_TEST_TOT_QUESTION:-What is the best way to learn a new programming language?}" \
  timeout "${PIE_TEST_TOT_TIMEOUT:-300}" .build/debug/chat-engine-harness 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}
set -e
echo "tot-e2e: harness rc=$rc (0=tree_complete reached, 1=no terminal, 124=stall/timeout)"
exit "$rc"
