#!/bin/bash
# F10 — durable Unverified marker on the Installed-models row.
#
# Stages two GGUFs under a shared PIE_HOME/models (one with a
# `<file>.unverified` sidecar, one clean), then drives Rational.app's
# Settings → Models tab and asserts the unverified row carries the
# Unverified badge after a fresh rescan while the clean row does not.
# No network or engine — proves the marker survives rescan/restart, not
# just the live download row.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source "$ROOT/Scripts/e2e-prep.sh"

RUN_ROOT="${PIE_TEST_RUN_ROOT:-/tmp/p204-unv-$$}"
GUI_HOME="$RUN_ROOT/g"
MODELS="$GUI_HOME/models"
UNVERIFIED_ID="u/unverified.gguf"
CLEAN_ID="c/clean.gguf"
CONFIG_FILE="/tmp/pie-unverified-badge.env"

cleanup() { rm -f "$CONFIG_FILE"; }
trap cleanup EXIT

e2e_require_seated_gui "unverified-badge" || exit 2
e2e_require_tcc "unverified-badge" || exit 2

# Stage the fixtures from the shell (unsandboxed) — a real /tmp path,
# never NSTemporaryDirectory() (XCUITest temp-dir trap).
mkdir -p "$MODELS/u" "$MODELS/c"
printf 'gguf-bytes' > "$MODELS/$UNVERIFIED_ID"
: > "$MODELS/$UNVERIFIED_ID.unverified"          # durable unverified sidecar
printf 'gguf-bytes' > "$MODELS/$CLEAN_ID"        # clean: no sidecar
rm -f "$CONFIG_FILE"
cat >"$CONFIG_FILE" <<EOF
PIE_TEST_GUI_HOME=$GUI_HOME
PIE_TEST_UNVERIFIED_ID=$UNVERIFIED_ID
PIE_TEST_CLEAN_ID=$CLEAN_ID
EOF

echo "unverified-badge: staged $MODELS/$UNVERIFIED_ID (+.unverified) and $MODELS/$CLEAN_ID"
echo "unverified-badge: generating Xcode project"
Scripts/genproject.sh

echo "unverified-badge: running XCUITest"
xcodebuild -project RatioThink.xcodeproj -scheme RatioThinkGUITests \
  -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO test \
  -only-testing:RatioThinkGUITests/S204_UnverifiedBadgeGUITests/test_installed_row_flags_unverified_after_rescan \
  ENABLE_CODE_COVERAGE=NO

echo "unverified-badge: PASS"
