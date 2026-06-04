#!/bin/bash
#  follow-up — REAL Helper-hosted engine E2E.
#
# Exercises the production engine-launch path with NO mock and NO
# PIE_TEST_ENGINE_BASE_URL bypass: real LaunchSpecResolver → real
# PieControlLauncher.launch → real `pie serve` loading a real GGUF →
# EngineStatus.running → an HTTP chat round-trip. This is the path that
# hid the  model-load hang; every other tier stubbed the spawn.
#
# Stages a small GGUF (default Qwen2.5-0.5B-Instruct Q4_K_M, ~476 MB),
# resolves the bundled `pie` engine + chat-apc resources, then runs the
# env-gated RealEngineLaunchE2ETests. Self-bootstraps missing build
# artifacts or prints the exact command to produce them.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Per-run id, exported so RealEngineLaunchE2ETests anchors each engine
# pieHome at /tmp/pe2e-${PE2E_RUN_ID}-<uuid>. The wrapper PID is unique
# among any concurrently-live run-engine-e2e.sh processes — exactly what
# lets the sweep below scope itself to THIS run.
PE2E_RUN_ID="$$"
export PE2E_RUN_ID

# Outer reap net — belt to the in-process IsolatedTestCase braces. The
# in-process SIGKILL-reap only fires when the bundle runs to completion;
# if `swift test` is killed (XCTest timeout, CI cancel, ^C) a hung
# `pie serve` and its /tmp pieHome survive. On exit, SIGKILL a stray
# engine of THIS run by its --config path, then remove THIS run's pieHome
# dirs. Both halves are scoped to /tmp/pe2e-${PE2E_RUN_ID}-* so a
# concurrent run-engine-e2e.sh (or a still-live bundle on the flat
# /tmp/pe2e-<uuid> fallback) is never deleted out from under its live
# engine — and neither is the staged model cache (/tmp/pie-e2e-models).
# SIGKILL because a wedged engine ignores SIGTERM (a healthy one was
# already reaped in-process).
sweep_stray_engines() {
  pkill -KILL -f "/tmp/pe2e-${PE2E_RUN_ID}-[0-9a-f]+/config\.toml" 2>/dev/null || true
  rm -rf "/tmp/pe2e-${PE2E_RUN_ID}-"* 2>/dev/null || true
}
trap sweep_stray_engines EXIT

REPO="${PIE_TEST_E2E_REPO:-Qwen/Qwen2.5-0.5B-Instruct-GGUF}"
FILE="${PIE_TEST_E2E_FILE:-qwen2.5-0.5b-instruct-q4_k_m.gguf}"
MODELS_DIR="${PIE_TEST_E2E_MODELS_DIR:-/tmp/pie-e2e-models}"
MODEL_PATH="$MODELS_DIR/$FILE"

# --- pie engine binary: prefer a release build, fall back to bundled --
PIE_BIN="${PIE_BIN:-}"
if [ -z "$PIE_BIN" ]; then
  if [ -x "$ROOT/Vendor/pie/target/release/pie" ]; then
    PIE_BIN="$ROOT/Vendor/pie/target/release/pie"
  elif [ -x "/Applications/RatioThink.app/Contents/Resources/pie-engine/pie" ]; then
    PIE_BIN="/Applications/RatioThink.app/Contents/Resources/pie-engine/pie"
    # Loud fallback: no repo build exists, so this run exercises the
    # INSTALLED app's engine binary, not the current worktree. Make the
    # substitution visible so a stale /Applications build can't silently
    # green an engine regression in the repo. Set PIE_BIN to override.
    echo "e2e: WARNING no repo build (Vendor/pie/target/release/pie) — using INSTALLED app engine:" >&2
    echo "e2e:          $PIE_BIN" >&2
    echo "e2e:          this tests the installed /Applications build, not this worktree." >&2
    echo "e2e:          run 'make engine-build' or set PIE_BIN to test the repo binary." >&2
  fi
fi
if [ -z "$PIE_BIN" ] || [ ! -x "$PIE_BIN" ]; then
  echo "e2e: pie engine binary not found." >&2
  echo "e2e: build it →  make engine-build   (produces Vendor/pie/target/release/pie)" >&2
  exit 2
fi

# --- chat-apc inferlet resources --------------------------------------
WASM="$ROOT/Inferlets/chat-apc/prebuilt/chat-apc.wasm"
MANIFEST="$ROOT/Inferlets/chat-apc/Pie.toml"
if [ ! -f "$WASM" ] || [ ! -f "$MANIFEST" ]; then
  echo "e2e: chat-apc resources missing — build them →  make build-inferlets" >&2
  exit 2
fi

# --- stage the model (download once) ----------------------------------
mkdir -p "$MODELS_DIR"
if [ ! -f "$MODEL_PATH" ] || [ "$(stat -f%z "$MODEL_PATH" 2>/dev/null || echo 0)" -lt 300000000 ]; then
  if ! curl -sSf -o /dev/null --max-time 20 -r 0-0 "https://huggingface.co/$REPO/resolve/main/$FILE?download=true"; then
    echo "e2e: cannot reach Hugging Face for $REPO/$FILE — network required to stage the model." >&2
    exit 2
  fi
  echo "e2e: downloading $REPO/$FILE → $MODEL_PATH"
  curl -sSL -o "$MODEL_PATH" "https://huggingface.co/$REPO/resolve/main/$FILE?download=true"
fi
echo "e2e: model staged at $MODEL_PATH ($(du -h "$MODEL_PATH" | awk '{print $1}'))"
echo "e2e: pie engine = $PIE_BIN"

# --- run the gated real-engine test -----------------------------------
mkdir -p "$ROOT/logs"
LOG="$ROOT/logs/test-$(date +%Y%m%d-%H%M%S)-engine-e2e.log"
echo "e2e: running RealEngineLaunchE2ETests (log: $LOG)"
set +e
PIE_TEST_REAL_PIE_BIN="$PIE_BIN" \
PIE_TEST_REAL_MODEL_PATH="$MODEL_PATH" \
PIE_TEST_REAL_CHATAPC_WASM="$WASM" \
PIE_TEST_REAL_CHATAPC_MANIFEST="$MANIFEST" \
  swift test --filter RealEngineLaunchE2ETests 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}
set -e
echo "e2e: swift test rc=$rc"
exit "$rc"
