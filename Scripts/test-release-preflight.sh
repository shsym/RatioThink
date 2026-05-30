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

make_dummy_app() {  # $1=dir  [$2=entitlements plist] -> ad-hoc-signed bundle
  local app="$1/Dummy.app"
  mkdir -p "$app/Contents/MacOS"
  cp /bin/echo "$app/Contents/MacOS/Dummy"
  printf '%s' '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>Dummy</string><key>CFBundleIdentifier</key><string>com.example.dummy</string></dict></plist>' > "$app/Contents/Info.plist"
  if [ -n "${2:-}" ]; then
    codesign -f -s - --entitlements "$2" "$app" 2>/dev/null
  else
    codesign -f -s - "$app" 2>/dev/null
  fi
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
MOUNT_BEFORE="$(mount)"
set +e
DMG_OUT="$("$PREFLIGHT" "$DMG" 2>&1)"; DMG_RC=$?
set -e
MOUNT_AFTER="$(mount)"
expect_nz "$DMG_RC" "ad-hoc dmg: nonzero exit"
have "Disk image:" "$DMG_OUT" "dmg section header present"
have "mounting dmg to inspect" "$DMG_OUT" "dmg mounted for inspection"
# A .dmg is a disk image, so it must be assessed with `-t open --context
# context:primary-signature` (Apple's documented form), NOT `-t install`
# (which is for .pkg installers). Asserting the exact flags catches a
# regression of the type even without a paid Developer ID cert.
have "spctl --assess --type open --context context:primary-signature" "$DMG_OUT" "dmg assessed with -t open + primary-signature context"
# Real mount-leak guard: the preflight mounts at its OWN mktemp dir, not the
# test's $TMP, so the old `mount | grep "$TMP"` could never match and always
# passed. Compare the full mount table before vs after — a leaked mount (e.g.
# the cleanup trap's `|| true` swallowing a busy-detach failure) appears as a
# new line and fails the test.
if [ "$MOUNT_BEFORE" = "$MOUNT_AFTER" ]; then
  ok "dmg detached cleanly (mount table unchanged)"
else
  bad "dmg left a mount behind: $(diff <(printf '%s\n' "$MOUNT_BEFORE") <(printf '%s\n' "$MOUNT_AFTER") | tr '\n' ' ')"
fi

echo "test-release-preflight: get-task-allow-entitled bundle must FAIL the verdict"
# Exercises check_get_task_allow's FAIL branch — the exact invariant the
# "Strip get-task-allow from the Release notarization candidate" commit
# enforces. Ad-hoc signing WITH an entitlements plist yields a verify-valid
# bundle that carries com.apple.security.get-task-allow, which the notary
# service rejects.
cat > "$TMP/gta.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.get-task-allow</key><true/></dict></plist>
PLIST
mkdir -p "$TMP/gta"
GTA_APP="$(make_dummy_app "$TMP/gta" "$TMP/gta.entitlements")"
set +e
GTA_OUT="$("$PREFLIGHT" "$GTA_APP" 2>&1)"; GTA_RC=$?
set -e
# Guard the fixture itself: if codesign did not actually embed the entitlement,
# the test would silently revert to the absent->PASS path and prove nothing.
if codesign -d --entitlements :- "$GTA_APP" 2>/dev/null | grep -q 'get-task-allow'; then
  ok "fixture carries get-task-allow"
else
  bad "fixture did NOT embed get-task-allow (codesign --entitlements failed) — F3 assertions are vacuous"
fi
expect_nz "$GTA_RC" "get-task-allow bundle: nonzero verdict"
have "get-task-allow: PRESENT" "$GTA_OUT" "get-task-allow PRESENT line emitted (FAIL branch)"
have "get-task-allow present" "$GTA_OUT" "get-task-allow listed as a blocking issue in the verdict"

echo "------------------------------------------------------------"
echo "test-release-preflight: $PASS passed, $FAILN failed"
[ "$FAILN" -eq 0 ] || exit 1
