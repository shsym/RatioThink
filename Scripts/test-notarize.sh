#!/usr/bin/env bash
# Contract test for Scripts/notarize.sh.
#
# Verifies the loud-fail contract WITHOUT ever contacting Apple: every failure
# path checked here returns before any network round-trip. Hits the real
# codesign / security tools (no stubs), matching the repo's "tests hit the real
# tool" rule.
#
# Deterministic everywhere (incl. CI with no certs): usage (64), missing
# artifact (65), unsupported artifact (65), and refusal of a non-Developer ID
# artifact (66). The no-credentials path (67) needs a Developer ID-signed
# artifact to reach, so it runs only when a Developer ID cert is present; when
# absent it falls back to asserting the contract structurally in the source
# (never a silent skip).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTARIZE="$SCRIPT_DIR/notarize.sh"

PASS=0; FAILN=0
ok()  { echo "  ok: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1" >&2; FAILN=$((FAILN + 1)); }
expect_rc() { if [ "$2" -eq "$1" ]; then ok "$3"; else bad "$3 (got rc=$2)"; fi; }
have() { if grep -q "$1" <<<"$2"; then ok "$3"; else bad "$3"; fi; }

# Run notarize.sh with NO notary env so credential resolution is deterministic.
run_notarize() {
  env -u NOTARY_KEYCHAIN_PROFILE -u NOTARY_API_KEY -u NOTARY_API_KEY_ID \
      -u NOTARY_API_ISSUER -u NOTARY_APPLE_ID -u NOTARY_TEAM_ID \
      -u NOTARY_PASSWORD "$NOTARIZE" "$@"
}

make_app() {  # $1=dir  $2=identity ('-' for ad-hoc)
  local app="$1/Dummy.app"
  mkdir -p "$app/Contents/MacOS"
  cp /bin/echo "$app/Contents/MacOS/Dummy"
  printf '%s' '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>Dummy</string><key>CFBundleIdentifier</key><string>com.example.dummy</string></dict></plist>' > "$app/Contents/Info.plist"
  codesign -f -s "$2" --options runtime --timestamp=none "$app" 2>/dev/null
  printf '%s' "$app"
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "test-notarize: usage + bad-artifact exit codes"
set +e; run_notarize >/dev/null 2>&1; RC=$?; set -e
expect_rc 64 "$RC" "no-arg usage exit 64"
set +e; run_notarize "$TMP/nope.app" >/dev/null 2>&1; RC=$?; set -e
expect_rc 65 "$RC" "missing artifact exit 65"
: > "$TMP/thing.txt"
set +e; run_notarize "$TMP/thing.txt" >/dev/null 2>&1; RC=$?; set -e
expect_rc 65 "$RC" "unsupported extension exit 65"

echo "test-notarize: ad-hoc (non-Developer ID) artifact is refused before any upload"
ADHOC="$(make_app "$TMP" -)"
set +e; OUT="$(run_notarize "$ADHOC" 2>&1)"; RC=$?; set -e
expect_rc 66 "$RC" "non-Developer ID exit 66"
have "not signed with a 'Developer ID Application'" "$OUT" "explains the Developer ID requirement"
have "make release-dmg-arm64" "$OUT" "points at the signing command"

echo "test-notarize: no-credentials path (67)"
DEVID="$(security find-identity -v -p codesigning 2>/dev/null | awk '/Developer ID Application/ {print $2; exit}')"
if [ -n "$DEVID" ]; then
  DEVAPP="$(make_app "$TMP" "$DEVID")"
  set +e; OUT="$(run_notarize "$DEVAPP" 2>&1)"; RC=$?; set -e
  expect_rc 67 "$RC" "Developer ID-signed + no creds exit 67"
  have "no notary credentials found" "$OUT" "prints the no-credentials guidance"
  have "store-credentials" "$OUT" "documents the keychain-profile option"
else
  echo "  note: no 'Developer ID Application' cert on this machine — cannot exercise"
  echo "        the exit-67 path live (it requires a Developer ID-signed artifact)."
  echo "        Asserting the credential contract structurally in notarize.sh instead."
  for token in NOTARY_KEYCHAIN_PROFILE NOTARY_API_KEY NOTARY_APPLE_ID \
               "no notary credentials found" "exit 67" "store-credentials"; do
    if grep -q "$token" "$NOTARIZE"; then ok "notarize.sh defines: $token"; else bad "notarize.sh missing: $token"; fi
  done
fi

echo "------------------------------------------------------------"
echo "test-notarize: $PASS passed, $FAILN failed"
[ "$FAILN" -eq 0 ] || exit 1
