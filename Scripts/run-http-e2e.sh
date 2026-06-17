#!/usr/bin/env bash
#
# HTTP API stress + agent-client tool-calling contract E2E (#398).
#
# Runs the chat-apc engine-side HTTP suites against pie's **dummy driver**
# (deterministic, no GGUF weights, no GPU):
#
#   * e2e_test.py        — baseline control-plane + validation smoke.
#   * stress_e2e_test.py — protocol stress, SSE/streaming stress,
#                          frequency/concurrency, and the OpenAI
#                          tool-calling contract (forced tool_choice ->
#                          tool_calls -> fake client tool -> result turn
#                          -> final answer).
#
# Self-bootstraps its two build inputs (fail-loud with the exact fix
# command if a build step is unavailable), then runs both suites in the
# pie_client uv environment with httpx added.
#
# Prerequisites this script CANNOT build for you (fail-loud with guidance):
#   * `uv` on PATH (https://docs.astral.sh/uv/).
#   * Qwen/Qwen3-0.6B config.json + tokenizer.json in the HF cache — the
#     dummy driver auto-discovers vocab/arch from config.json and loads the
#     tokenizer (the model WEIGHTS are NOT needed; the dummy fabricates
#     outputs). Fetch just those two small files with:
#         uv run --with huggingface_hub python -c \
#           "from huggingface_hub import hf_hub_download as d; \
#            [d('Qwen/Qwen3-0.6B', f) for f in ('config.json','tokenizer.json')]"
#
# Usage: Scripts/run-http-e2e.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# shellcheck source=lib/sandbox-diagnostics.sh
. "$ROOT/Scripts/lib/sandbox-diagnostics.sh"

PIE_BIN="Vendor/pie/target/release/pie"
PIE_STAMP="${PIE_BIN}.vendor-sha"
WASM="Inferlets/chat-apc/prebuilt/chat-apc.wasm"
PYDIR="Vendor/pie/client/python"
TAG="http-e2e"

if ! command -v uv >/dev/null 2>&1; then
  echo "[http-e2e] FATAL: 'uv' not found on PATH." >&2
  echo "           install it: https://docs.astral.sh/uv/getting-started/installation/" >&2
  exit 2
fi
sandbox_diag_require_uv_cache "$TAG" || exit 2

# Self-bootstrap: build the pie engine binary when missing OR when the
# existing binary was built from a different Vendor/pie checkout. The WIT host
# ABI lives in Vendor/pie, so a stale binary can instantiate-fail every request
# even though chat-apc.wasm + its stamp are current. Record the submodule HEAD
# next to the binary after each wrapper-owned build and compare it before E2E.
current_pie_sha="$(git -C Vendor/pie rev-parse HEAD)"
build_pie=0
if [ ! -x "$PIE_BIN" ]; then
  echo "[http-e2e] pie engine binary missing — building (make engine-build)…"
  build_pie=1
elif [ ! -f "$PIE_STAMP" ]; then
  echo "[http-e2e] pie engine binary has no Vendor/pie stamp — rebuilding (make engine-build)…"
  build_pie=1
elif [ "$(cat "$PIE_STAMP")" != "$current_pie_sha" ]; then
  echo "[http-e2e] pie engine binary stale for current Vendor/pie checkout — rebuilding (make engine-build)…"
  echo "[http-e2e]   binary stamp: $(cat "$PIE_STAMP")"
  echo "[http-e2e]   current head:  $current_pie_sha"
  build_pie=1
fi
if [ "$build_pie" -eq 1 ]; then
  Scripts/run-engine-build.sh
  printf '%s\n' "$current_pie_sha" > "$PIE_STAMP"
fi

# Self-bootstrap: build the chat-apc wasm if missing.
if [ ! -f "$WASM" ]; then
  echo "[http-e2e] chat-apc wasm missing — building (Scripts/stamp-chat-apc.sh build)…"
  Scripts/stamp-chat-apc.sh build
fi

# Guide (don't auto-download): the dummy driver auto-discovers vocab/arch
# from Qwen3-0.6B config.json and loads its tokenizer. Warn loudly with the
# exact fetch command if they're absent from the common cache locations —
# pie will still emit the authoritative resolution error if it can't find
# them (the cache path can be relocated via HF_HOME/HF_HUB_CACHE).
HF_CACHE="${HF_HUB_CACHE:-${HF_HOME:-$HOME/.cache/huggingface}/hub}"
MODEL_GLOB="$HF_CACHE/models--Qwen--Qwen3-0.6B/snapshots"/*/config.json
if ! compgen -G "$MODEL_GLOB" >/dev/null 2>&1; then
  echo "[http-e2e] WARNING: Qwen/Qwen3-0.6B config.json not found under $HF_CACHE." >&2
  echo "           The dummy driver needs its config.json + tokenizer.json (NOT the weights)." >&2
  echo "           Fetch just those two small files:" >&2
  echo "             uv run --with huggingface_hub python -c \\" >&2
  echo "               \"from huggingface_hub import hf_hub_download as d; \\" >&2
  echo "                [d('Qwen/Qwen3-0.6B', f) for f in ('config.json','tokenizer.json')]\"" >&2
fi

run_suite() {
  local script="$1"
  echo ""
  echo "=============================================================="
  echo "[http-e2e] running $script"
  echo "=============================================================="
  sandbox_diag_run_with_recovery "$TAG $script" uv run --project "$PYDIR" --with httpx python "$script"
}

# Parser unit first (cheap harness regression), then baseline control-plane
# smoke, then the full stress suite.
run_suite "Inferlets/chat-apc/e2e_handshake_test.py"
run_suite "Inferlets/chat-apc/e2e_test.py"
run_suite "Inferlets/chat-apc/stress_e2e_test.py"

echo ""
echo "[http-e2e] all HTTP API E2E suites passed."
