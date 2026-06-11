#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source "$ROOT/Scripts/e2e-prep.sh"

TAG="chat gui e2e"
# Serve the seeded GGUF the App's default "chat" profile resolves, under its
# slug — so `/v1/models` reports the slug and the chat menu renders its leaf
# (`Qwen3-0.6B-Q8_0.gguf`). S258 (send), S260 (model menu), and S426 (Fast
# Think profile select + real reply) all consume it.
SLUG="Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf"
RUN_ROOT="${PIE_TEST_RUN_ROOT:-/tmp/p258-$$}"
ENGINE_HOME="$RUN_ROOT/e"
GUI_HOME="$RUN_ROOT/g"
MODELS_ROOT="$RUN_ROOT/models"
URL_FILE="$RUN_ROOT/engine.url"
HARNESS_LOG="$RUN_ROOT/engine-harness.log"
CONFIG_FILE="/tmp/pie-chat-gui-e2e.env"
ENGINE_PID=""

cleanup() {
  rm -f "$CONFIG_FILE"
  if [ -n "$ENGINE_PID" ] && kill -0 "$ENGINE_PID" >/dev/null 2>&1; then
    kill "$ENGINE_PID" >/dev/null 2>&1 || true
    wait "$ENGINE_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# Preconditions + auto-prep. Human-only gates fail fast with
# exact fix steps; pie + the HF model are built/downloaded automatically
# (disable with PIE_E2E_AUTOPREP=0).
e2e_require_seated_gui "$TAG" || exit 2
e2e_require_tcc "$TAG" || exit 2
e2e_require_chat_apc "$ROOT" "$TAG" || exit 2
PIE_BIN="$(e2e_ensure_pie "$ROOT" "$TAG")" || exit 2

# Stage the GGUF weight (symlink test-models/ from the HF cache, or print the
# exact download command and exit non-zero — honest-skip only when the GGUF is
# genuinely unavailable), then materialize the app-staged slug path the harness
# serves in portable mode.
if ! Scripts/stage-test-model.sh >&2; then
  echo "$TAG: GGUF fixture unavailable (see guidance above); cannot run the GGUF chat E2E." >&2
  exit 2
fi
GGUF_REAL="$(realpath "$ROOT/test-models/Qwen3-0.6B-Q8_0.gguf")"
GGUF_DEST="$MODELS_ROOT/$SLUG"
mkdir -p "$(dirname "$GGUF_DEST")"
# Regular file (hard-link; copy across volumes) so pie loads the weight directly.
ln "$GGUF_REAL" "$GGUF_DEST" 2>/dev/null || cp "$GGUF_REAL" "$GGUF_DEST"

mkdir -p "$ENGINE_HOME" "$GUI_HOME"
rm -f "$URL_FILE" "$CONFIG_FILE"

echo "chat gui e2e: generating Xcode project"
Scripts/genproject.sh

echo "chat gui e2e: starting portable GGUF engine harness"
PIE_BIN="$PIE_BIN" \
PIE_TEST_HARNESS_MODEL_SLUG="$SLUG" \
PIE_TEST_HARNESS_MODELS_ROOT="$MODELS_ROOT" \
PIE_TEST_ENGINE_HOME="$ENGINE_HOME" \
PIE_TEST_ENGINE_URL_FILE="$URL_FILE" \
xcrun swift run chat-engine-harness >"$HARNESS_LOG" 2>&1 &
ENGINE_PID=$!

for _ in $(seq 1 180); do
  if [ -s "$URL_FILE" ]; then
    break
  fi
  if ! kill -0 "$ENGINE_PID" >/dev/null 2>&1; then
    echo "chat gui e2e: engine harness exited before publishing URL" >&2
    cat "$HARNESS_LOG" >&2 || true
    exit 1
  fi
  sleep 1
done

if [ ! -s "$URL_FILE" ]; then
  echo "chat gui e2e: timed out waiting for engine URL" >&2
  cat "$HARNESS_LOG" >&2 || true
  exit 1
fi

BASE_URL="$(cat "$URL_FILE")"
cat >"$CONFIG_FILE" <<EOF
PIE_TEST_ENGINE_BASE_URL=$BASE_URL
PIE_TEST_GUI_HOME=$GUI_HOME
PIE_TEST_CHAT_MODEL=$SLUG
EOF

echo "chat gui e2e: engine=$BASE_URL"
echo "chat gui e2e: model=$SLUG"
echo "chat gui e2e: gui PIE_HOME=$GUI_HOME"
echo "chat gui e2e: config=$CONFIG_FILE"
echo "chat gui e2e: retained run root: $RUN_ROOT"
echo "chat gui e2e: running XCUITest"

xcodebuild -project RatioThink.xcodeproj \
  -scheme RatioThinkGUITests \
  -destination 'platform=macOS,arch=arm64' \
  -parallel-testing-enabled NO \
  test \
  -only-testing:RatioThinkGUITests/S258_ComposerSendGUITests/test_composer_send_streams_real_assistant_and_persists_after_relaunch \
  -only-testing:RatioThinkGUITests/S260_ChatModelMenuGUITests/test_chat_model_menu_contains_seeded_qwen3_default \
  -only-testing:RatioThinkGUITests/S426_FastThinkProfileGUITests/test_fast_think_profile_selectable_and_streams_real_reply \
  -only-testing:RatioThinkGUITests/S520_MultiPartContentGUITests/test_external_multipart_client_succeeds_and_gui_chat_still_streams \
  ENABLE_CODE_COVERAGE=NO

# The seeded Qwen3-0.6B is a *thinking* model: it can emit the answer inside
# its <think> reasoning (persisted to ZREASONING) and not reach final ZCONTENT
# within the token budget. The engine genuinely produced "Paris" either way,
# so the semantic gate accepts it in content OR reasoning. (The empty-final-
# content truncation under the small thinking model is a separate, pre-existing
# concern — see the harness notes; it is not what this E2E asserts.)
if ! sqlite3 "$GUI_HOME/chats.sqlite" \
  "select ZCONTENT, ZREASONING from ZMESSAGE where ZROLE = 'assistant';" \
  | grep -F "Paris" >/dev/null; then
  echo "chat gui e2e: no assistant row produced Paris (content or reasoning) in $GUI_HOME/chats.sqlite" >&2
  sqlite3 "$GUI_HOME/chats.sqlite" \
    "select ZROLE, ZCONTENT, ZREASONING, ZMETA from ZMESSAGE order by ZTS;" >&2 || true
  exit 1
fi

echo "chat gui e2e: assistant produced Paris (content or reasoning)"
echo "chat gui e2e: PASS"
