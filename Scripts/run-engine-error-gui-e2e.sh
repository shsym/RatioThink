#!/bin/bash
# #669: capture the engine-start-failure state in the REAL Rational.app GUI —
# the no-model gate + the loud Tier-2 engine/helper error banner up at once,
# with the toolbar model picker opened over it — and export the screenshot.
#
# Mechanism (see Tests/GUIScenarioTests/S669_EngineErrorCaptureGUITests.swift):
#   1. The XCUITest launches the app with PIE_TEST_PIN_HELPER_HEALTH=unreachable
#      and no resolvable model, sends a prompt (raising the no-model gate),
#      opens toolbar.model over the gate+banner, and attaches a full-screen
#      screenshot.
#   2. This wrapper exports that screenshot out of the .xcresult to a stable
#      absolute path: build/gui-artifacts/engine-error.png.
#
# CAVEAT: the macOS-26 scroll-edge blur seen on 26.5.1 hardware is
# GPU/appearance-gated and will NOT render in this capture. The shot proves the
# gate/banner/picker STATE and picker reachability — it neither shows nor
# disproves the on-device blur.
#
# Engine-free: the gate/banner render before any engine contact, so no mock
# harness / model is started. Requires a seated GUI session + the one-time TCC
# grant. Re-run with PIE_TEST_TCC_GRANTED=1.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source "$ROOT/Scripts/e2e-prep.sh"

RUN_ROOT="${PIE_TEST_RUN_ROOT:-/tmp/p669-engine-error-$$}"
RESULT_BUNDLE="$RUN_ROOT/result.xcresult"
XCODE_LOG="$RUN_ROOT/xcodebuild.log"
OUT_DIR="$ROOT/build/gui-artifacts"
OUT_PNG="$OUT_DIR/engine-error.png"

cleanup() { rm -rf "$RUN_ROOT"; }
trap cleanup EXIT

e2e_require_seated_gui "engine error gui e2e" || exit 2
e2e_require_tcc "engine error gui e2e" || exit 2

mkdir -p "$RUN_ROOT" "$OUT_DIR"
rm -rf "$RESULT_BUNDLE"
rm -f "$OUT_PNG"

echo "engine error gui e2e: generating Xcode project"
"${PIE_TEST_GENPROJECT:-Scripts/genproject.sh}"

TEST_NAME="test_capture_engine_error_state_with_model_picker_open"
ONLY="RatioThinkGUITests/S669_EngineErrorCaptureGUITests/$TEST_NAME"
echo "engine error gui e2e: running XCUITest ($ONLY)"
# A failing assertion must NOT strand the attached screenshot — XCTAttachment
# writes into the .xcresult regardless of pass/fail, so swallow the exit and
# always reach the export, but remember the status for the final verdict.
set +e
e2e_run_gui_xcodebuild "$XCODE_LOG" \
  -project RatioThink.xcodeproj \
  -scheme RatioThinkGUITests \
  -destination 'platform=macOS,arch=arm64' \
  -parallel-testing-enabled NO \
  -resultBundlePath "$RESULT_BUNDLE" \
  test \
  -only-testing:"$ONLY" \
  ENABLE_CODE_COVERAGE=NO
status=$?
set -e

if [ -d "$RESULT_BUNDLE" ]; then
  EXPORT_DIR="$RUN_ROOT/attachments"
  rm -rf "$EXPORT_DIR"
  echo "engine error gui e2e: exporting attachment → $OUT_PNG"
  xcrun xcresulttool export attachments \
    --path "$RESULT_BUNDLE" \
    --output-path "$EXPORT_DIR" >/dev/null
  python3 - "$EXPORT_DIR" "$OUT_PNG" <<'PY'
import json, os, shutil, sys
export_dir, out_png = sys.argv[1], sys.argv[2]
with open(os.path.join(export_dir, "manifest.json")) as f:
    data = json.load(f)
for test in data:
    for att in test.get("attachments", []):
        name = att.get("suggestedHumanReadableName") or att.get("name") or ""
        exported = att.get("exportedFileName")
        if exported and name.split("_0_")[0].rsplit(".", 1)[0] == "engine-error":
            shutil.copyfile(os.path.join(export_dir, exported), out_png)
            print(f"engine error gui e2e: OK exported {out_png}")
            sys.exit(0)
sys.exit("engine error gui e2e: no 'engine-error' attachment found in xcresult")
PY
else
  echo "engine error gui e2e: no .xcresult bundle produced (build/launch failed before any test ran)" >&2
fi

# Verdict: xcodebuild exits 0 on an XCTSkip too, so require the positive
# per-test pass line and refuse any skip.
if [ "$status" -ne 0 ]; then
  echo "engine error gui e2e: FAIL (xcodebuild exit $status)" >&2
  exit "$status"
fi
if grep -q "Test Case .*$TEST_NAME.*skipped" "$XCODE_LOG"; then
  echo "engine error gui e2e: FAIL — test was SKIPPED, not run" >&2
  exit 1
fi
if ! grep -q "Test Case .*$TEST_NAME.*passed" "$XCODE_LOG"; then
  echo "engine error gui e2e: FAIL — no positive pass signal for $TEST_NAME" >&2
  exit 1
fi

echo "engine error gui e2e: PASS — screenshot at $OUT_PNG"
