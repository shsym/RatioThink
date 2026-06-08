#!/usr/bin/env bash
#
# Real-engine harsh-LOAD evaluation for the Local API (#467, real tier).
#
# Drives the REAL engine (`pie serve` portable-Metal, real Qwen3-0.6B) under
# realistic heavy load — many concurrent requests, long/realistic prompts and
# growing histories, sustained agent-replay traffic — replaying prompts
# CAPTURED FROM REAL AGENTS (the pie-agents replay approach) with the bounded
# concurrency that the upstream sequential runner lacks.
#
# This is the REAL-WEIGHTS / GPU tier. It is NOT part of normal CI and NEVER
# fails for a missing prerequisite — the Python harness SKIPs cleanly (exit 0)
# when the pie binary, the chat-apc wasm, or the real model weights are absent.
#
# Tiers (see Inferlets/chat-apc/harsh_load_real.py):
#   * SMOKE — committed self-contained openclaw sample
#             (Inferlets/chat-apc/fixtures/openclaw_replay_sample.jsonl).
#             Runs whenever the weights exist.
#   * HEAVY — a richer hermes capture.jsonl, env-sourced (NOT committed):
#             set PIE_TEST_REPLAY_CORPUS=/path/to/.../capture.jsonl
#
# Prereqs this script CANNOT build (fail-loud with guidance):
#   * `uv` on PATH.
#   * The real model WEIGHTS in the HF cache (e.g. Qwen/Qwen3-0.6B
#     model.safetensors). Unlike the dummy tier, the harness needs real
#     weights and will SKIP without them.
#
# Knobs (all optional, defaulted in the harness):
#   MODEL, HARSH_CONCURRENCY, HARSH_SMOKE_CONCURRENCY, HARSH_USERS,
#   HARSH_ROUNDS, HARSH_MAX_TOKENS, HARSH_REQ_TIMEOUT, PIE_TEST_REPLAY_CORPUS
#
# Usage: Scripts/run-harsh-load-e2e.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PIE_BIN="Vendor/pie/target/release/pie"
WASM="Inferlets/chat-apc/prebuilt/chat-apc.wasm"
PYDIR="Vendor/pie/client/python"
HARNESS="Inferlets/chat-apc/harsh_load_real.py"

if ! command -v uv >/dev/null 2>&1; then
  echo "[harsh-load] FATAL: 'uv' not found on PATH." >&2
  echo "             install it: https://docs.astral.sh/uv/getting-started/installation/" >&2
  exit 2
fi

# Self-bootstrap: build the pie engine binary with the portable-Metal driver
# if missing (the real tier needs the Metal backend compiled in).
if [ ! -x "$PIE_BIN" ]; then
  echo "[harsh-load] pie engine binary missing — building portable-Metal (this is slow)…"
  (cd Vendor/pie && PIE_PORTABLE_METAL=1 cargo build -p pie-server --release)
fi

# Self-bootstrap: build the chat-apc wasm if missing.
if [ ! -f "$WASM" ]; then
  echo "[harsh-load] chat-apc wasm missing — building (Scripts/stamp-chat-apc.sh build)…"
  Scripts/stamp-chat-apc.sh build
fi

# The harness gates on real weights itself (SKIP, exit 0, if absent) — surface
# the hint here too so an operator knows why a run no-opped.
MODEL="${MODEL:-Qwen/Qwen3-0.6B}"
HF_CACHE="${HF_HUB_CACHE:-${HF_HOME:-$HOME/.cache/huggingface}/hub}"
REPO="models--$(printf '%s' "$MODEL" | sed 's#/#--#g')"
if ! find -L "$HF_CACHE/$REPO/snapshots" -type f \
        \( -name '*.safetensors' -o -name '*.gguf' -o -name '*.bin' \) 2>/dev/null | grep -q .; then
  echo "[harsh-load] NOTE: no real weights for $MODEL under $HF_CACHE — the harness will SKIP." >&2
  echo "             Fetch them with: uv run --with huggingface_hub python -c \\" >&2
  echo "               \"from huggingface_hub import snapshot_download as d; d('$MODEL')\"" >&2
fi

if [ -n "${PIE_TEST_REPLAY_CORPUS:-}" ]; then
  echo "[harsh-load] HEAVY tier enabled: PIE_TEST_REPLAY_CORPUS=$PIE_TEST_REPLAY_CORPUS"
else
  echo "[harsh-load] HEAVY tier disabled (set PIE_TEST_REPLAY_CORPUS=/path/to/capture.jsonl to enable)."
fi

uv run --project "$PYDIR" --with httpx python "$HARNESS"
