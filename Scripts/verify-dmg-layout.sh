#!/usr/bin/env bash
# Mount a packaged RatioThink DMG read-only and assert the drag-install
# layout (ticket #354):
#   * the mounted root contains RatioThink.app,
#   * the root contains an `Applications` symlink to /Applications so the
#     window offers the familiar drag-install target, and
#   * the app still passes a strict codesign seal check — i.e. packaging
#     did not corrupt the signed bundle.
#
# Usage: Scripts/verify-dmg-layout.sh <dmg>
#
# package-dmg.sh calls this on every build so a silent layout/seal
# regression fails the package instead of shipping.

set -euo pipefail

DMG="${1:-}"
if [[ -z "$DMG" ]]; then
  echo "verify-dmg-layout.sh: usage: verify-dmg-layout.sh <dmg>" >&2
  exit 64
fi
if [[ ! -f "$DMG" ]]; then
  echo "verify-dmg-layout.sh: DMG not found: $DMG" >&2
  exit 66
fi

fail() {
  echo "verify-dmg-layout.sh: FAIL: $*" >&2
  exit 1
}

MNT="$(mktemp -d "${TMPDIR:-/tmp}/pie-dmg-verify.XXXXXX")"
cleanup() {
  hdiutil detach "$MNT" >/dev/null 2>&1 || true
  rm -rf "$MNT"
}
trap cleanup EXIT

# Explicit -mountpoint avoids clobbering an existing /Volumes/RatioThink
# and keeps cleanup unambiguous. -nobrowse keeps the verify mount out of
# Finder/sidebar.
if ! hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$DMG" >/dev/null; then
  fail "could not attach DMG: $DMG"
fi

APP="$MNT/RatioThink.app"
[[ -d "$APP" ]] || fail "mounted DMG root is missing RatioThink.app"

LINK="$MNT/Applications"
[[ -L "$LINK" ]] || fail "mounted DMG root is missing the /Applications drag-install symlink"
target="$(readlink "$LINK")"
[[ "$target" == "/Applications" ]] ||
  fail "Applications symlink points to '$target', expected /Applications"

# --strict + --deep is the same seal check package-dmg.sh runs on the
# pre-package bundle; here it confirms staging/hdiutil preserved that
# seal so the shipped app still verifies (drag-install acceptance).
if ! codesign --verify --strict --deep --verbose=2 "$APP" >/dev/null 2>&1; then
  fail "RatioThink.app inside the DMG fails codesign verification"
fi

echo "verify-dmg-layout.sh: ok — RatioThink.app + Applications target present, codesign valid ($DMG)"
