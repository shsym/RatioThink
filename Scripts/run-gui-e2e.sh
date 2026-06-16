#!/bin/bash
# Real-model acquisition GUI E2E.
#
# Drives Rational.app's Settings → Models → Add Model… → Curated download
# through the GUI (the real in-process ModelDownloader against live
# Hugging Face), waits for the "Done" badge, then independently
# re-verifies the placed GGUF's sha256 against HF's X-Linked-Etag.
#
# Requires the SettingsRoot a11y fix so the Models tab content
# is driveable by XCUITest. No pie engine needed for the acquisition
# leg. Chat-apc send/persist with a real model is covered by ; the
# lower-tier ModelDownloader guard is
# Scripts/run-real-model-acquisition.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source "$ROOT/Scripts/e2e-prep.sh"

MODEL_ID="${PIE_TEST_ACQUIRE_MODEL_ID:-qwen2.5-0.5b-instruct-q4_k_m}"
REPO="${PIE_TEST_ACQUIRE_REPO:-Qwen/Qwen2.5-0.5B-Instruct-GGUF}"
FILE="${PIE_TEST_ACQUIRE_FILE:-qwen2.5-0.5b-instruct-q4_k_m.gguf}"
DOWNLOAD_TIMEOUT="${PIE_TEST_ACQUIRE_TIMEOUT:-600}"
RUN_ROOT="${PIE_TEST_RUN_ROOT:-/tmp/p204-gui-$$}"
GUI_HOME="$RUN_ROOT/g"
CONFIG_FILE="/tmp/pie-real-model-e2e.env"

cleanup() { rm -f "$CONFIG_FILE"; }
trap cleanup EXIT

if ! pgrep -x Dock >/dev/null 2>&1; then
  echo "gui e2e: no seated GUI session (Dock not running) — sit at console / Screen Sharing." >&2
  exit 2
fi
if [ "${PIE_TEST_TCC_GRANTED:-}" != "1" ]; then
  echo "gui e2e: Rational.app + XCTest-runner Automation/Accessibility permissions required." >&2
  echo "gui e2e: grant them in System Settings → Privacy & Security, then rerun:" >&2
  echo "gui e2e:   PIE_TEST_TCC_GRANTED=1 Scripts/run-gui-e2e.sh" >&2
  exit 2
fi
if ! curl -sSf -o /dev/null --max-time 20 -r 0-0 "https://huggingface.co/$REPO/resolve/main/$FILE?download=true"; then
  echo "gui e2e: cannot reach Hugging Face for $REPO/$FILE — network required." >&2
  exit 2
fi

mkdir -p "$GUI_HOME"
rm -f "$CONFIG_FILE"
cat >"$CONFIG_FILE" <<EOF
PIE_TEST_GUI_HOME=$GUI_HOME
PIE_TEST_ACQUIRE_MODEL_ID=$MODEL_ID
PIE_TEST_ACQUIRE_TIMEOUT=$DOWNLOAD_TIMEOUT
EOF

echo "gui e2e: model=$MODEL_ID ($REPO/$FILE)"
echo "gui e2e: gui PIE_HOME=$GUI_HOME"
echo "gui e2e: retained run root: $RUN_ROOT"
echo "gui e2e: generating Xcode project"
Scripts/genproject.sh

echo "gui e2e: running XCUITest (real download, up to ${DOWNLOAD_TIMEOUT}s)"
XCODE_LOG="$RUN_ROOT/xcodebuild.log"
set +e
e2e_run_gui_xcodebuild "$XCODE_LOG" \
  -project RatioThink.xcodeproj \
  -scheme RatioThinkGUITests \
  -destination 'platform=macOS,arch=arm64' \
  -parallel-testing-enabled NO \
  test \
  -only-testing:RatioThinkGUITests/S204_ModelAcquisitionGUITests/test_settings_curated_download_verifies_and_completes \
  ENABLE_CODE_COVERAGE=NO
status=$?
set -e
[ "$status" -ne 0 ] && exit "$status"

# Independent on-disk re-verification: placed bytes' sha256 == HF
# X-Linked-Etag (LFS content hash on the resolve 302, ).
PLACED="$GUI_HOME/models/$REPO/$FILE"
if [ ! -f "$PLACED" ]; then
  echo "gui e2e: verified GGUF not found at $PLACED" >&2
  exit 1
fi
EXPECTED="$(curl -sS -D - -o /dev/null --max-time 30 \
  "https://huggingface.co/$REPO/resolve/main/$FILE?download=true" \
  | awk 'tolower($1) ~ /^x-linked-etag:/ {v=$2; gsub(/[\r"]/,"",v); sub(/^sha256:/,"",v); print tolower(v); exit}')"
if [ -z "$EXPECTED" ]; then
  echo "gui e2e: could not read X-Linked-Etag from HF" >&2
  exit 1
fi
ACTUAL="$(shasum -a 256 "$PLACED" | awk '{print $1}')"
if [ "$ACTUAL" != "$EXPECTED" ]; then
  echo "gui e2e: on-disk sha256 mismatch for $PLACED" >&2
  echo "gui e2e:   expected (HF X-Linked-Etag) = $EXPECTED" >&2
  echo "gui e2e:   actual   (on-disk bytes)    = $ACTUAL" >&2
  exit 1
fi
echo "gui e2e: on-disk sha256 matches HF X-Linked-Etag ($EXPECTED)"
echo "gui e2e: PASS"
