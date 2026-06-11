#!/bin/bash
# FULL real-model GUI E2E:
#   Settings acquisition → chat-apc → chat send/persist.
#
# Verifies THREE layers against one acquired model:
#   Phase A: Rational.app downloads a curated GGUF through Settings → Models
#            (the real ModelDownloader, ) into GUI_HOME/models.
#   Engine:  boot pie + chat-apc serving THAT downloaded GGUF via the
#            portable driver (.portable(modelSlug, modelsRoot)).
#   Layer 1 — HTTP API: api-probe issues a chat over the same
#            HTTPEngineClient → /v1/chat/completions path the app uses
#            and asserts the engine reply contains "Paris" (engine
#            contract, decoupled from the GUI; UI<->API parity seed).
#   Layer 2 — GUI: Rational.app sends the prompt; the on-screen assistant
#            answer is verified (S204_ChatSendGUITests).
#   Layer 3 — persistence: the assistant answer is verified in the
#            SwiftData store after relaunch (sqlite "Paris" check).
#
# Requires a seated GUI session + TCC grant + network. The pie engine
# is built from the Vendor/pie submodule (make engine-build).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MODEL_ID="${PIE_TEST_ACQUIRE_MODEL_ID:-qwen2.5-0.5b-instruct-q4_k_m}"
REPO="${PIE_TEST_ACQUIRE_REPO:-Qwen/Qwen2.5-0.5B-Instruct-GGUF}"
FILE="${PIE_TEST_ACQUIRE_FILE:-qwen2.5-0.5b-instruct-q4_k_m.gguf}"
DOWNLOAD_TIMEOUT="${PIE_TEST_ACQUIRE_TIMEOUT:-600}"
PIE_BIN="${PIE_BIN:-$ROOT/Vendor/pie/target/release/pie}"
RUN_ROOT="${PIE_TEST_RUN_ROOT:-/tmp/p204-full-$$}"
GUI_HOME="$RUN_ROOT/g"
ENGINE_HOME="$RUN_ROOT/e"
URL_FILE="$RUN_ROOT/engine.url"
HARNESS_LOG="$RUN_ROOT/engine-harness.log"
ACQ_CONFIG="/tmp/pie-real-model-e2e.env"
CHAT_CONFIG="/tmp/pie-chat-e2e.env"
ENGINE_PID=""

cleanup() {
  rm -f "$ACQ_CONFIG" "$CHAT_CONFIG"
  if [ -n "$ENGINE_PID" ] && kill -0 "$ENGINE_PID" >/dev/null 2>&1; then
    kill "$ENGINE_PID" >/dev/null 2>&1 || true
    wait "$ENGINE_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# ---- Gates -----------------------------------------------------------
if ! pgrep -x Dock >/dev/null 2>&1; then
  echo "full e2e: no seated GUI session (Dock not running)." >&2
  exit 2
fi
if [ "${PIE_TEST_TCC_GRANTED:-}" != "1" ]; then
  echo "full e2e: grant Automation/Accessibility, then rerun with PIE_TEST_TCC_GRANTED=1." >&2
  exit 2
fi
if [ ! -x "$PIE_BIN" ]; then
  echo "full e2e: pie engine missing at $PIE_BIN — run: make engine-build" >&2
  exit 2
fi
if [ ! -f "Inferlets/chat-apc/prebuilt/chat-apc.wasm" ]; then
  echo "full e2e: chat-apc.wasm missing — run: make build-inferlets" >&2
  exit 2
fi
if ! curl -sSf -o /dev/null --max-time 20 -r 0-0 "https://huggingface.co/$REPO/resolve/main/$FILE?download=true"; then
  echo "full e2e: cannot reach Hugging Face for $REPO/$FILE." >&2
  exit 2
fi

mkdir -p "$GUI_HOME" "$ENGINE_HOME"
rm -f "$URL_FILE" "$ACQ_CONFIG" "$CHAT_CONFIG"

echo "full e2e: model=$MODEL_ID ($REPO/$FILE)"
echo "full e2e: gui PIE_HOME=$GUI_HOME  engine PIE_HOME=$ENGINE_HOME"
echo "full e2e: retained run root: $RUN_ROOT"
echo "full e2e: generating Xcode project"
Scripts/genproject.sh

# ---- Phase A: GUI download via Settings ------------------------------
cat >"$ACQ_CONFIG" <<EOF
PIE_TEST_GUI_HOME=$GUI_HOME
PIE_TEST_ACQUIRE_MODEL_ID=$MODEL_ID
PIE_TEST_ACQUIRE_TIMEOUT=$DOWNLOAD_TIMEOUT
EOF

echo "full e2e: PHASE A — Settings acquisition (real download)"
xcodebuild -project RatioThink.xcodeproj -scheme RatioThinkGUITests \
  -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO test \
  -only-testing:RatioThinkGUITests/S204_ModelAcquisitionGUITests/test_settings_curated_download_verifies_and_completes \
  ENABLE_CODE_COVERAGE=NO

PLACED="$GUI_HOME/models/$REPO/$FILE"
if [ ! -f "$PLACED" ]; then
  echo "full e2e: downloaded GGUF not found at $PLACED" >&2
  exit 1
fi

# Independent on-disk integrity re-verify ( F4): match the narrower
# sibling scripts (run-gui-e2e.sh, run-real-model-
# acquisition.sh) so the FULL chain has the same integrity coverage —
# the placed bytes' sha256 must equal HF's X-Linked-Etag (the LFS
# content hash on the resolve 302, ). Without this an unverified
# (F1) download would flow into the engine/persistence layers green.
EXPECTED="$(curl -sS -D - -o /dev/null --max-time 30 \
  "https://huggingface.co/$REPO/resolve/main/$FILE?download=true" \
  | awk 'tolower($1) ~ /^x-linked-etag:/ {v=$2; gsub(/[\r"]/,"",v); sub(/^sha256:/,"",v); print tolower(v); exit}')"
if [ -z "$EXPECTED" ]; then
  echo "full e2e: could not read X-Linked-Etag from HF for $REPO/$FILE" >&2
  exit 1
fi
ACTUAL="$(shasum -a 256 "$PLACED" | awk '{print $1}')"
if [ "$ACTUAL" != "$EXPECTED" ]; then
  echo "full e2e: on-disk sha256 mismatch for $PLACED" >&2
  echo "full e2e:   expected (HF X-Linked-Etag) = $EXPECTED" >&2
  echo "full e2e:   actual   (on-disk bytes)    = $ACTUAL" >&2
  exit 1
fi
echo "full e2e: acquired $PLACED ($(du -h "$PLACED" | awk '{print $1}')) sha256==X-Linked-Etag ($EXPECTED)"

# ---- Engine: serve the downloaded GGUF via the portable driver -------
echo "full e2e: booting engine on the downloaded GGUF"
PIE_BIN="$PIE_BIN" \
PIE_TEST_ENGINE_HOME="$ENGINE_HOME" \
PIE_TEST_ENGINE_URL_FILE="$URL_FILE" \
PIE_TEST_HARNESS_MODEL_SLUG="$REPO/$FILE" \
PIE_TEST_HARNESS_MODELS_ROOT="$GUI_HOME/models" \
xcrun swift run chat-engine-harness >"$HARNESS_LOG" 2>&1 &
ENGINE_PID=$!

for _ in $(seq 1 240); do
  [ -s "$URL_FILE" ] && break
  if ! kill -0 "$ENGINE_PID" >/dev/null 2>&1; then
    echo "full e2e: engine harness exited before publishing URL" >&2
    cat "$HARNESS_LOG" >&2 || true
    exit 1
  fi
  sleep 1
done
if [ ! -s "$URL_FILE" ]; then
  echo "full e2e: timed out waiting for engine URL" >&2
  cat "$HARNESS_LOG" >&2 || true
  exit 1
fi
BASE_URL="$(cat "$URL_FILE")"
echo "full e2e: engine=$BASE_URL (model loaded)"

# ---- Layer 1: independent HTTP-API assertion (UI<->API parity seed) --
# Drive the SAME chat-apc path the app uses (HTTPEngineClient →
# /v1/chat/completions) against the SAME running engine, decoupled from
# the SwiftUI render. Foundation for future UI<->API instruction
# parity: the same prompt provable over the engine API, not just
# the GUI. Test assertion + documented seed only — no new product API.
echo "full e2e: LAYER 1 — HTTP API assertion (engine contract)"
PIE_TEST_API_BASE_URL="$BASE_URL" \
PIE_TEST_API_MODEL="$REPO/$FILE" \
PIE_TEST_API_PROMPT="The capital of France is" \
PIE_TEST_API_EXPECT="Paris" \
xcrun swift run api-probe

# ---- Phase B: GUI chat send/persist (reuse the  composer test) ---
# The portable driver serves the model under its slug (`<repo>/<file>`,
# PieControlLauncher → `servedID: modelSlug`), so the app must request that
# slug for /v1/chat/completions to match the resident model — NOT "default".
cat >"$CHAT_CONFIG" <<EOF
PIE_TEST_ENGINE_BASE_URL=$BASE_URL
PIE_TEST_GUI_HOME=$GUI_HOME
PIE_TEST_CHAT_MODEL_PIN=$REPO/$FILE
EOF

echo "full e2e: PHASE B — chat send/persist against the acquired model"
xcodebuild -project RatioThink.xcodeproj -scheme RatioThinkGUITests \
  -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO test \
  -only-testing:RatioThinkGUITests/S204_ChatSendGUITests/test_chat_send_streams_real_assistant_and_persists_after_relaunch \
  ENABLE_CODE_COVERAGE=NO

if ! sqlite3 "$GUI_HOME/chats.sqlite" \
  "select ZCONTENT from ZMESSAGE where ZROLE = 'assistant';" \
  | grep -F "Paris" >/dev/null; then
  echo "full e2e: persisted assistant row missing 'Paris' in $GUI_HOME/chats.sqlite" >&2
  sqlite3 "$GUI_HOME/chats.sqlite" "select ZROLE, ZCONTENT from ZMESSAGE order by ZTS;" >&2 || true
  exit 1
fi

echo "full e2e: persisted assistant row contains 'Paris'"
echo "full e2e: PASS — API + GUI + persistence all verified"
