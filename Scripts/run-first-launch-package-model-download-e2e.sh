#!/bin/bash
set -euo pipefail

# #379 — packaged first-launch model-download → Load-default chat GUI E2E.
#
# Builds a packaged Rational.app, starts a deterministic HTTP engine that
# advertises the seeded default model slug, runs the packaged first-launch
# wizard, downloads the default curated GGUF through Settings (the fixture
# downloader lands the file + writes a probe), then drives the no-model gate's
# **Load-default** path — which resolves the persisted profile default (NO
# PIE_TEST_CHAT_MODEL injection) — and a send streams a reply. Finally asserts,
# from the probe, the downloaded file, and the SwiftData store, that the
# download targeted the persisted default and the reply persisted.
#
# Build configuration: the app is packaged in **Debug** by default. The
# deterministic engine seams (`PIE_TEST_ENGINE_BASE_URL` and
# `PIE_TEST_ENGINE_START_TO_RUNNING`) are gated to DEBUG builds
# (`HelperConfig.isTestOverrideAllowed`, the #325 hardening that stops a shipped
# Release app from redirecting its engine endpoint), and an isolated-PIE_HOME
# GUI test cannot use the app's own global-Helper engine (the Helper resolves
# models under ITS pieHome, not the test's). So a deterministic chat from a
# packaged bundle requires a Debug-configured package. The Release-signed
# artifact + wizard + relaunch persistence are covered by
# S7_FirstLaunchWizardPackagedArtifactGUITests; this suite adds the
# model-download → persisted-default-chat envelope. Override with
# PIE_TEST_PACKAGE_CONFIGURATION=Release for the packaging path only (the chat
# step then cannot reach the deterministic engine).

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source "$ROOT/Scripts/e2e-prep.sh"

TAG="first-launch package model-download e2e"

# Mirror ProfileStore.defaultChatModelID + the matching curated catalog row
# (CuratedModelCatalog id "qwen3-0.6b-q8_0"). Kept in sync by the curated
# catalog audit + LaunchSpecResolver.
SLUG="Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf"
CURATED_ID="qwen3-0.6b-q8_0"
REPO="Qwen/Qwen3-0.6B-GGUF"
FILE="Qwen3-0.6B-Q8_0.gguf"
REPLY="bluejay-379"

CONFIG="${PIE_TEST_PACKAGE_CONFIGURATION:-Debug}"
ARCH_VALUE="${ARCH:-$(uname -m)}"
RUN_ROOT="${PIE_TEST_RUN_ROOT:-/tmp/p379-$$}"
GUI_HOME="$RUN_ROOT/gui-home"
PKG_OUT="$RUN_ROOT/package"
URL_FILE="$RUN_ROOT/engine.url"
PROBE_FILE="$RUN_ROOT/model-download-probe.json"
HARNESS_LOG="$RUN_ROOT/engine-harness.log"
CONFIG_FILE="/tmp/pie-first-launch-package-model-download-e2e.env"
SUITE="RatioThinkGUITests/S7_FirstLaunchWizardPackagedModelDownloadGUITests/test_first_launch_download_then_load_default_resolves_and_send_succeeds"
PREF_SUITE="com.ratiothink.app.gui.s379.$(uuidgen | tr '[:upper:]' '[:lower:]')"
HARNESS_PID=""

cleanup() {
  local status="$1"
  rm -f "$CONFIG_FILE"
  defaults delete "$PREF_SUITE" >/dev/null 2>&1 || true
  if [ -n "$HARNESS_PID" ] && kill -0 "$HARNESS_PID" >/dev/null 2>&1; then
    kill "$HARNESS_PID" >/dev/null 2>&1 || true
    wait "$HARNESS_PID" >/dev/null 2>&1 || true
  fi
  if [ "$status" -eq 0 ]; then
    case "$RUN_ROOT" in
      /tmp/p379-*|/private/tmp/p379-*) rm -rf "$RUN_ROOT" ;;
    esac
  else
    echo "$TAG: preserving run root for triage: $RUN_ROOT" >&2
  fi
  return "$status"
}
trap 'cleanup "$?"' EXIT

require_seated_gui() {
  e2e_require_seated_gui "$TAG" || exit 2
  e2e_require_tcc "$TAG" || exit 2
}

require_seated_gui

# Fresh GUI home: a reused run root (PIE_TEST_RUN_ROOT / preserved-on-failure)
# could otherwise leave a models/<slug> file + a chats store from a prior
# attempt, false-greening the downloaded-file and persisted-reply checks.
rm -rf "$GUI_HOME"
mkdir -p "$RUN_ROOT" "$GUI_HOME" "$PKG_OUT"
rm -f "$URL_FILE" "$PROBE_FILE" "$CONFIG_FILE"

echo "$TAG: generating Xcode project"
Scripts/genproject.sh

echo "$TAG: packaging $CONFIG Rational.app for $ARCH_VALUE (cold-builds the pie engine on first run)"
Scripts/package-dmg.sh --arch "$ARCH_VALUE" --configuration "$CONFIG" --out "$PKG_OUT"
APP_PATH="$ROOT/build/xcode-$ARCH_VALUE/sym/Rational.app"
if [ ! -d "$APP_PATH" ]; then
  echo "$TAG: packaged app missing at $APP_PATH" >&2
  exit 1
fi

echo "$TAG: starting deterministic HTTP engine (serves $SLUG)"
python3 Scripts/gui-chat-stream-harness.py \
  --port-file "$URL_FILE" \
  --model-id "$SLUG" \
  --mode normal \
  --reply "$REPLY" \
  >"$HARNESS_LOG" 2>&1 &
HARNESS_PID=$!

for _ in $(seq 1 30); do
  [ -s "$URL_FILE" ] && break
  if ! kill -0 "$HARNESS_PID" >/dev/null 2>&1; then
    echo "$TAG: engine harness exited before publishing URL" >&2
    cat "$HARNESS_LOG" >&2 || true
    exit 1
  fi
  sleep 1
done
if [ ! -s "$URL_FILE" ]; then
  echo "$TAG: timed out waiting for engine URL" >&2
  cat "$HARNESS_LOG" >&2 || true
  exit 1
fi
BASE_URL="$(cat "$URL_FILE")"

cat >"$CONFIG_FILE" <<EOF
PIE_TEST_APP_PATH=$APP_PATH
PIE_TEST_GUI_HOME=$GUI_HOME
PIE_APP_PREFERENCES_SUITE=$PREF_SUITE
PIE_TEST_ENGINE_BASE_URL=$BASE_URL
PIE_TEST_CURATED_MODEL_ID=$CURATED_ID
PIE_TEST_MODEL_DOWNLOAD_PROBE_FILE=$PROBE_FILE
PIE_TEST_CHAT_REPLY_NEEDLE=$REPLY
EOF

echo "$TAG: app artifact=$APP_PATH ($CONFIG)"
echo "$TAG: engine=$BASE_URL"
echo "$TAG: gui PIE_HOME=$GUI_HOME"
echo "$TAG: config=$CONFIG_FILE"
echo "$TAG: retained run root: $RUN_ROOT"
echo "$TAG: running packaged first-launch model-download XCUITest"

xcodebuild -project RatioThink.xcodeproj \
  -scheme RatioThinkGUITests \
  -destination "platform=macOS,arch=$ARCH_VALUE" \
  -parallel-testing-enabled NO \
  test \
  -only-testing:"$SUITE" \
  ENABLE_CODE_COVERAGE=NO

# ---- Semantic assertions (post-XCUITest, like S258/S204 wrappers) ---------
echo "$TAG: asserting download probe + downloaded file + persisted reply"
DOWNLOADED_FILE="$GUI_HOME/models/$REPO/$FILE"
SQLITE_DB="$GUI_HOME/chats.sqlite"

python3 - "$PROBE_FILE" "$DOWNLOADED_FILE" "$SLUG" "$REPO" "$FILE" <<'PY'
import json
import os
import sys

probe_path, downloaded_file, slug, repo, file = sys.argv[1:]

# 1. The download request (repo/file recorded by the fixture downloader from
# the actual ModelDownloadController.enqueue, NOT an env round-trip) composes
# to the persisted default slug.
if not os.path.exists(probe_path):
    print(f"first-launch package model-download e2e: download probe missing at {probe_path}", file=sys.stderr)
    sys.exit(1)
with open(probe_path, encoding="utf-8") as fh:
    probe = json.load(fh)
if probe.get("repo") != repo or probe.get("file") != file:
    print(f"first-launch package model-download e2e: probe repo/file {probe.get('repo')!r}/{probe.get('file')!r} != {repo!r}/{file!r}", file=sys.stderr)
    sys.exit(1)
composed = f"{probe['repo']}/{probe['file']}"
if composed != slug:
    print(f"first-launch package model-download e2e: probe repo/file compose to {composed!r}, not the persisted default {slug!r}", file=sys.stderr)
    sys.exit(1)

# 2. The downloaded model file actually landed on disk under PIE_HOME/models.
if not os.path.exists(downloaded_file):
    print(f"first-launch package model-download e2e: downloaded model file missing at {downloaded_file}", file=sys.stderr)
    sys.exit(1)

print(f"first-launch package model-download e2e: probe confirms the download targeted {slug}")
PY

# 3. The Load-resolved assistant reply persisted in the SwiftData store.
if ! sqlite3 "$SQLITE_DB" \
  "select ZCONTENT from ZMESSAGE where ZROLE = 'assistant';" \
  | grep -F "$REPLY" >/dev/null; then
  echo "$TAG: persisted assistant reply '$REPLY' not found in $SQLITE_DB" >&2
  sqlite3 "$SQLITE_DB" "select ZROLE, ZCONTENT from ZMESSAGE order by ZTS;" >&2 || true
  exit 1
fi

echo "$TAG: persisted assistant reply present; download → Load-default persisted-default chat verified"
echo "$TAG: PASS"
