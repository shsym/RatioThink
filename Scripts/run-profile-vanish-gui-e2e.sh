#!/bin/bash
# #702: reproduce the profile-vanish bug in the REAL Rational.app GUI and export
# a screenshot of the failing state (toolbar profile picker open, the stale
# built-in missing).
#
# Mechanism (see Tests/GUIScenarioTests/S702_ProfileVanishGUITests.swift):
#   1. The XCUITest seeds a temp PIE_HOME/profiles with a VALID chat.toml next
#      to a stale, unparseable repeat-boost.toml (id + model only — the exact
#      shape a pre-upgrade install leaves behind).
#   2. It launches the app, opens the toolbar profile picker, asserts `chat`
#      renders but `repeat-boost` is silently dropped (the parse-drop bug), and
#      attaches a full-screen screenshot of that state (XCTAttachment,
#      .keepAlways).
#   3. This wrapper exports that screenshot out of the .xcresult to a stable
#      absolute path in the worktree: build/gui-artifacts/profile-vanish.png.
#
# Engine-free: the picker renders from disk before any engine contact, so no
# mock harness / model is started. Requires a seated GUI session and the
# one-time TCC grant, same as every GUI E2E wrapper. Re-run with
# PIE_TEST_TCC_GRANTED=1.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source "$ROOT/Scripts/e2e-prep.sh"

RUN_ROOT="${PIE_TEST_RUN_ROOT:-/tmp/p702-profile-vanish-$$}"
RESULT_BUNDLE="$RUN_ROOT/result.xcresult"
XCODE_LOG="$RUN_ROOT/xcodebuild.log"
OUT_DIR="$ROOT/build/gui-artifacts"
OUT_PNG="$OUT_DIR/profile-vanish.png"

cleanup() { rm -rf "$RUN_ROOT"; }
trap cleanup EXIT

e2e_require_seated_gui "profile vanish gui e2e" || exit 2
e2e_require_tcc "profile vanish gui e2e" || exit 2

mkdir -p "$RUN_ROOT" "$OUT_DIR"
rm -rf "$RESULT_BUNDLE"
rm -f "$OUT_PNG"

echo "profile vanish gui e2e: generating Xcode project"
"${PIE_TEST_GENPROJECT:-Scripts/genproject.sh}"

TEST_NAME="test_stale_builtin_profile_vanishes_from_toolbar_picker"
ONLY="RatioThinkGUITests/S702_ProfileVanishGUITests/$TEST_NAME"
echo "profile vanish gui e2e: running XCUITest ($ONLY)"
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

# Export the attached screenshot from the .xcresult to the stable worktree path.
if [ -d "$RESULT_BUNDLE" ]; then
  EXPORT_DIR="$RUN_ROOT/attachments"
  rm -rf "$EXPORT_DIR"
  echo "profile vanish gui e2e: exporting attachment → $OUT_PNG"
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
        if exported and name.split("_0_")[0].rsplit(".", 1)[0] == "profile-vanish":
            shutil.copyfile(os.path.join(export_dir, exported), out_png)
            print(f"profile vanish gui e2e: OK exported {out_png}")
            sys.exit(0)
sys.exit("profile vanish gui e2e: no 'profile-vanish' attachment found in xcresult")
PY
else
  echo "profile vanish gui e2e: no .xcresult bundle produced (build/launch failed before any test ran)" >&2
fi

# Verdict mirrors run-select-gui-e2e: xcodebuild exits 0 on an XCTSkip too, so
# require the positive per-test pass line and refuse any skip.
if [ "$status" -ne 0 ]; then
  echo "profile vanish gui e2e: FAIL (xcodebuild exit $status)" >&2
  exit "$status"
fi
if grep -q "Test Case .*$TEST_NAME.*skipped" "$XCODE_LOG"; then
  echo "profile vanish gui e2e: FAIL — test was SKIPPED, not run" >&2
  exit 1
fi
if ! grep -q "Test Case .*$TEST_NAME.*passed" "$XCODE_LOG"; then
  echo "profile vanish gui e2e: FAIL — no positive pass signal for $TEST_NAME" >&2
  exit 1
fi

echo "profile vanish gui e2e: PASS — screenshot at $OUT_PNG"
