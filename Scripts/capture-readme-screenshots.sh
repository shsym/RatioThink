#!/bin/bash
# Capture README landing-page screenshots of the REAL Rational.app driven
# into a populated, OFFLINE state, and export them into docs/assets/.
#
# Mechanism (see Tests/GUIScenarioTests/ReadmeScreenshotsGUITests.swift):
#   1. Start Scripts/readme-screenshot-harness.py — a mock pie engine (no real
#      engine, no model download).
#   2. Seed $PIE_HOME/models with dummy (sparse) .gguf files so the Models tab
#      shows a populated table.
#   3. Run the ReadmeScreenshots XCUITest, which launches the app against the
#      mock, drives chat / endpoint / models, and attaches one window
#      screenshot each.
#   4. Export the attachments from the .xcresult into docs/assets/.
#
# Requires a seated GUI session (console / Screen Sharing) and a one-time TCC
# grant for the XCTest runner + Rational.app (Automation + Accessibility),
# same as the other GUI E2E scripts. Re-run with PIE_TEST_TCC_GRANTED=1.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MODEL="${PIE_TEST_CHAT_MODEL:-Qwen3-8B-Instruct}"
RUN_ROOT="${PIE_TEST_RUN_ROOT:-/tmp/readme-shots-$$}"
GUI_HOME="$RUN_ROOT/g"
URL_FILE="$RUN_ROOT/harness.url"
HARNESS_LOG="$RUN_ROOT/harness.log"
RESULT_BUNDLE="$RUN_ROOT/result.xcresult"
CONFIG_FILE="/tmp/pie-readme-screenshots.env"
OUT_DIR="$ROOT/docs/assets"
HARNESS_PID=""

cleanup() {
  rm -f "$CONFIG_FILE"
  if [ -n "$HARNESS_PID" ] && kill -0 "$HARNESS_PID" >/dev/null 2>&1; then
    kill "$HARNESS_PID" >/dev/null 2>&1 || true
    wait "$HARNESS_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if ! pgrep -x Dock >/dev/null 2>&1; then
  echo "readme shots: no seated GUI session detected (Dock not running)." >&2
  echo "readme shots: run from the console or a Screen Sharing session." >&2
  exit 2
fi
if [ "${PIE_TEST_TCC_GRANTED:-}" != "1" ]; then
  echo "readme shots: Rational.app + XCTest runner need Automation + Accessibility." >&2
  echo "readme shots: grant them once in System Settings → Privacy & Security, then rerun:" >&2
  echo "readme shots:   PIE_TEST_TCC_GRANTED=1 Scripts/capture-readme-screenshots.sh" >&2
  exit 2
fi

mkdir -p "$GUI_HOME/models" "$OUT_DIR"
rm -f "$URL_FILE" "$CONFIG_FILE"
rm -rf "$RESULT_BUNDLE"

# Seed dummy installed models (sparse files — no disk used, realistic sizes).
# InstalledModels.scan only reads name/size/modDate, never parses GGUF bytes.
seed_model() { mkfile -n "$2" "$GUI_HOME/models/$1" 2>/dev/null || : ; }
seed_model "Qwen3-8B-Instruct-Q4_K_M.gguf"        "4900m"
seed_model "Llama-3.2-3B-Instruct-Q4_K_M.gguf"    "2020m"
seed_model "Mistral-7B-Instruct-v0.3-Q4_K_M.gguf" "4370m"

echo "readme shots: starting mock engine harness"
python3 Scripts/readme-screenshot-harness.py \
  --port-file "$URL_FILE" \
  --model "$MODEL" \
  >"$HARNESS_LOG" 2>&1 &
HARNESS_PID=$!

for _ in $(seq 1 30); do
  [ -s "$URL_FILE" ] && break
  if ! kill -0 "$HARNESS_PID" >/dev/null 2>&1; then
    echo "readme shots: harness exited before publishing URL" >&2
    cat "$HARNESS_LOG" >&2 || true
    exit 1
  fi
  sleep 1
done
if [ ! -s "$URL_FILE" ]; then
  echo "readme shots: timed out waiting for harness URL" >&2
  cat "$HARNESS_LOG" >&2 || true
  exit 1
fi

BASE_URL="$(cat "$URL_FILE")"
cat >"$CONFIG_FILE" <<EOF
PIE_TEST_ENGINE_BASE_URL=$BASE_URL
PIE_TEST_GUI_HOME=$GUI_HOME
PIE_TEST_CHAT_MODEL=$MODEL
EOF

echo "readme shots: engine=$BASE_URL  model=$MODEL  PIE_HOME=$GUI_HOME"
echo "readme shots: generating Xcode project"
Scripts/genproject.sh

# Optional narrower filter (e.g. a single method) for re-capturing one
# shot; defaults to the whole class.
ONLY="${READMESHOTS_ONLY:-RatioThinkGUITests/ReadmeScreenshotsGUITests}"
echo "readme shots: running screenshot XCUITest ($ONLY)"
# A failing assertion in one capture must NOT strand the shots the other
# captures attached — XCTAttachment writes into the .xcresult regardless of
# pass/fail, so swallow a non-zero test exit and always reach the export.
xcodebuild -project RatioThink.xcodeproj \
  -scheme RatioThinkGUITests \
  -destination 'platform=macOS,arch=arm64' \
  -parallel-testing-enabled NO \
  -resultBundlePath "$RESULT_BUNDLE" \
  test \
  -only-testing:"$ONLY" \
  ENABLE_CODE_COVERAGE=NO \
  || echo "readme shots: xcodebuild reported test failures — exporting captured shots best-effort"

echo "readme shots: exporting attachments → $OUT_DIR"
EXPORT_DIR="$RUN_ROOT/attachments"
rm -rf "$EXPORT_DIR"
xcrun xcresulttool export attachments \
  --path "$RESULT_BUNDLE" \
  --output-path "$EXPORT_DIR"

# Map each attachment's human-readable name (set as XCTAttachment.name:
# "chat"/"endpoint"/"models") to its exported file and copy to docs/assets/.
python3 - "$EXPORT_DIR" "$OUT_DIR" <<'PY'
import json, os, shutil, sys
export_dir, out_dir = sys.argv[1], sys.argv[2]
manifest = os.path.join(export_dir, "manifest.json")
with open(manifest) as f:
    data = json.load(f)
wanted = {"chat", "endpoint", "models"}
copied = {}
for test in data:
    for att in test.get("attachments", []):
        name = att.get("suggestedHumanReadableName") or att.get("name")
        exported = att.get("exportedFileName")
        if not name or not exported:
            continue
        # XCUITest names attachments "<name>_0_<uuid>.png"; the leading
        # token before "_0_" is the XCTAttachment.name we set.
        base = name.split("_0_")[0].rsplit(".", 1)[0]
        if base in wanted:
            src = os.path.join(export_dir, exported)
            dst = os.path.join(out_dir, base + ".png")
            shutil.copyfile(src, dst)
            copied[base] = dst
for name in sorted(wanted):
    print(f"readme shots: {'OK ' if name in copied else 'MISSING'} {name}.png")
if not copied:
    sys.exit("readme shots: no screenshots exported — check the test run above")
PY

echo "readme shots: retained run root: $RUN_ROOT"
echo "readme shots: PASS"
