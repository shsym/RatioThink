#!/usr/bin/env bash
# Contract test for Scripts/release-preflight.sh.
#
# Hits the REAL codesign / spctl / hdiutil (no stubs, no xcodebuild) with
# throwaway ad-hoc-signed bundles — fast and CI-safe. Verifies the preflight
# correctly REJECTS a non-notarized artifact and emits the actionable
# remediation, so a dev build can never be mistaken for a Gatekeeper-ready
# release.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFLIGHT="$SCRIPT_DIR/release-preflight.sh"
export RT_PREFLIGHT_SKIP_LOGS=1   # skip slow `log show` in the contract test

PASS=0; FAILN=0
ok()  { echo "  ok: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1" >&2; FAILN=$((FAILN + 1)); }
expect_rc() { if [ "$2" -eq "$1" ]; then ok "$3"; else bad "$3 (got rc=$2)"; fi; }
expect_nz() { if [ "$1" -ne 0 ];   then ok "$2 (rc=$1)"; else bad "$2 (got rc=0)"; fi; }
have()  { if grep -q  "$1" <<<"$2"; then ok "$3"; else bad "$3"; fi; }
haveE() { if grep -Eq "$1" <<<"$2"; then ok "$3"; else bad "$3"; fi; }

make_dummy_app() {
  local app="$1/Dummy.app"
  mkdir -p "$app/Contents/MacOS"
  cp /bin/echo "$app/Contents/MacOS/Dummy"
  printf '%s' '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>Dummy</string><key>CFBundleIdentifier</key><string>com.example.dummy</string></dict></plist>' > "$app/Contents/Info.plist"
  codesign -f -s - "$app" 2>/dev/null
  printf '%s' "$app"
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
APP="$(make_dummy_app "$TMP")"

echo "test-release-preflight: ad-hoc .app must be reported as Gatekeeper-rejected"
set +e
APP_OUT="$("$PREFLIGHT" "$APP" 2>&1)"; APP_RC=$?
set -e
expect_nz "$APP_RC" "ad-hoc app: nonzero exit"
have "spctl --assess --type execute: REJECTED" "$APP_OUT" "spctl execute rejection reported"
have "\[FAIL\]" "$APP_OUT" "[FAIL] tag present"
have "^FAIL " "$APP_OUT" "verdict is FAIL"
have "Remediation:" "$APP_OUT" "remediation block present"
have "make release-dmg-arm64" "$APP_OUT" "names the release command"
have "xattr -dr com.apple.quarantine" "$APP_OUT" "names the dev quarantine fallback"
# An ad-hoc bundle has a VALID internal seal but is still Gatekeeper-rejected:
# the preflight must distinguish the two so a valid seal is not read as "ready".
haveE "codesign --verify .*: valid" "$APP_OUT" "internal seal reported valid (seal != gatekeeper)"

echo "test-release-preflight: usage + bad-artifact exit codes"
set +e; "$PREFLIGHT" >/dev/null 2>&1; RC=$?; set -e
expect_rc 64 "$RC" "no-arg usage exit 64"
set +e; "$PREFLIGHT" "$TMP/does-not-exist.app" >/dev/null 2>&1; RC=$?; set -e
expect_rc 65 "$RC" "missing artifact exit 65"
: > "$TMP/thing.txt"
set +e; "$PREFLIGHT" "$TMP/thing.txt" >/dev/null 2>&1; RC=$?; set -e
expect_rc 65 "$RC" "unsupported extension exit 65"

echo "test-release-preflight: .dmg path mounts + assesses the app inside"
DMG="$TMP/Dummy.dmg"
hdiutil create -volname Dummy -srcfolder "$APP" -fs HFS+ -format UDZO "$DMG" >/dev/null 2>&1
set +e
DMG_OUT="$("$PREFLIGHT" "$DMG" 2>&1)"; DMG_RC=$?
set -e
expect_nz "$DMG_RC" "ad-hoc dmg: nonzero exit"
have "Disk image:" "$DMG_OUT" "dmg section header present"
have "mounting dmg to inspect" "$DMG_OUT" "dmg mounted for inspection"
have "spctl --assess --type install" "$DMG_OUT" "dmg assessed as install"
# Confirm no leftover mount from the preflight's EXIT trap.
if mount | grep -q "$TMP"; then bad "dmg left mounted after preflight"; else ok "dmg detached cleanly"; fi

echo "------------------------------------------------------------"
echo "test-release-preflight: $PASS passed, $FAILN failed"
[ "$FAILN" -eq 0 ] || exit 1
