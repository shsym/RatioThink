#!/usr/bin/env bash
# Regression tests for Scripts/verify-dmg-layout.sh (ticket #354). Each case
# builds a real DMG fixture (hdiutil) — some bare, some fully styled via the
# production .DS_Store generator — and asserts the verifier's pass/fail verdict.
# Exercises the REAL hdiutil + codesign + .DS_Store writer/reader, no xcodebuild
# and no Finder/GUI, so it runs in CI under the lint job.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFIER="$ROOT/Scripts/verify-dmg-layout.sh"
BG_SWIFT="$ROOT/Scripts/make-dmg-background.swift"
DSSTORE_PY="$ROOT/Scripts/make-dmg-dsstore.py"
VENDOR_DIR="$ROOT/Scripts/vendor"
WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/pie-dmg-verifier-tests.XXXXXX")"
VOLNAME="RatioThink"
STAGE_MOUNT="/Volumes/$VOLNAME"

cleanup() {
  hdiutil detach "$STAGE_MOUNT" >/dev/null 2>&1 || true
  rm -rf "$WORK_ROOT"
}
trap cleanup EXIT

# Build a minimal, ad-hoc-signed RatioThink.app at $1. /bin/echo is a real
# mach-o, so the bundle is a valid codesign target whose seal a `--strict`
# verify can both accept (intact) and reject (tampered).
make_dummy_app() {
  local app="$1"
  mkdir -p "$app/Contents/MacOS"
  cp /bin/echo "$app/Contents/MacOS/RatioThink"
  cat >"$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>RatioThink</string>
  <key>CFBundleIdentifier</key><string>com.ratiothink.app.dmgtest</string>
</dict></plist>
PLIST
  codesign -f -s - "$app" >/dev/null 2>&1
}

# hdiutil-create a UDZO DMG from a staging dir (for the bare layout-failure
# fixtures that fail before the styling checks are reached).
make_dmg() {
  local stage="$1" dmg="$2"
  rm -f "$dmg"
  hdiutil create -volname "$VOLNAME" -srcfolder "$stage" -fs HFS+ -format UDZO "$dmg" >/dev/null
}

# Build a DMG the way production does: create a writable image, mount it, run a
# populate callback against the mount, detach, convert to UDZO. The callback
# receives the mount path and decides how complete/styled the layout is.
build_dmg() {
  local name="$1" populate="$2"
  local rw="$WORK_ROOT/$name-rw.dmg" out="$WORK_ROOT/$name.dmg"
  rm -f "$rw" "$out"
  hdiutil detach "$STAGE_MOUNT" >/dev/null 2>&1 || true
  hdiutil create -size 61m -fs HFS+ -volname "$VOLNAME" "$rw" >/dev/null
  hdiutil attach "$rw" -nobrowse -noverify >/dev/null
  "$populate" "$STAGE_MOUNT"
  sync
  hdiutil detach "$STAGE_MOUNT" >/dev/null
  hdiutil convert "$rw" -format UDZO -o "$out" >/dev/null 2>&1
  rm -f "$rw"
  printf "%s" "$out"
}

# Populate callbacks (run against the mounted writable volume).
pop_app_symlink() {
  local mnt="$1"
  make_dummy_app "$mnt/RatioThink.app"
  ln -s /Applications "$mnt/Applications"
}
pop_with_background() {
  local mnt="$1"
  pop_app_symlink "$mnt"
  mkdir -p "$mnt/.background"
  cp "$WORK_ROOT/bg.png" "$mnt/.background/background.png"
}
pop_styled() {
  local mnt="$1"
  pop_with_background "$mnt"
  python3 "$DSSTORE_PY" "$mnt" >/dev/null
}
pop_styled_reversed() {
  local mnt="$1"
  pop_styled "$mnt"
  # Swap the pinned icon positions so RatioThink.app sits to the RIGHT of
  # Applications — the exact regression the verifier must catch.
  VENDOR_DIR="$VENDOR_DIR" python3 - "$mnt/.DS_Store" <<'PY'
import os, sys
sys.path.insert(0, os.environ["VENDOR_DIR"])
from ds_store import DSStore
with DSStore.open(sys.argv[1], "r+") as d:
    d["RatioThink.app"]["Iloc"] = (450, 200)
    d["Applications"]["Iloc"] = (150, 200)
PY
}

expect_pass() {
  local name="$1" dmg="$2"
  if ! "$VERIFIER" "$dmg" >"$WORK_ROOT/$name.log" 2>&1; then
    cat "$WORK_ROOT/$name.log" >&2
    echo "FAIL: expected verifier PASS for $name" >&2
    exit 1
  fi
}
expect_fail() {
  local name="$1" dmg="$2"
  if "$VERIFIER" "$dmg" >"$WORK_ROOT/$name.log" 2>&1; then
    cat "$WORK_ROOT/$name.log" >&2
    echo "FAIL: expected verifier FAILURE for $name" >&2
    exit 1
  fi
}

# Shared background art for the styled fixtures.
xcrun swift "$BG_SWIFT" "$WORK_ROOT/bg.png" >/dev/null

# baseline: the fully styled layout package-dmg.sh produces.
expect_pass "baseline" "$(build_dmg baseline pop_styled)"

# missing Applications symlink → no drag-install target (fails before styling).
S="$WORK_ROOT/noapps-stage"; mkdir -p "$S"; make_dummy_app "$S/RatioThink.app"
make_dmg "$S" "$WORK_ROOT/noapps.dmg"
expect_fail "missing-applications-symlink" "$WORK_ROOT/noapps.dmg"

# Applications symlink resolves somewhere other than /Applications.
S="$WORK_ROOT/wrongtarget-stage"; mkdir -p "$S"; make_dummy_app "$S/RatioThink.app"
ln -s /tmp "$S/Applications"
make_dmg "$S" "$WORK_ROOT/wrongtarget.dmg"
expect_fail "applications-symlink-wrong-target" "$WORK_ROOT/wrongtarget.dmg"

# missing app bundle → nothing to install.
S="$WORK_ROOT/noapp-stage"; mkdir -p "$S"; ln -s /Applications "$S/Applications"
mkdir -p "$S/Readme"; echo "x" >"$S/Readme/x.txt"
make_dmg "$S" "$WORK_ROOT/noapp.dmg"
expect_fail "missing-app-bundle" "$WORK_ROOT/noapp.dmg"

# tampered executable → codesign seal must reject it.
S="$WORK_ROOT/broken-stage"; mkdir -p "$S"; make_dummy_app "$S/RatioThink.app"
ln -s /Applications "$S/Applications"
printf 'tamper' >>"$S/RatioThink.app/Contents/MacOS/RatioThink"
make_dmg "$S" "$WORK_ROOT/broken.dmg"
expect_fail "broken-codesign-seal" "$WORK_ROOT/broken.dmg"

# valid layout but UNSTYLED (no background, no .DS_Store) → must be rejected so
# we never silently ship a plain drag-install window.
S="$WORK_ROOT/unstyled-stage"; mkdir -p "$S"; make_dummy_app "$S/RatioThink.app"
ln -s /Applications "$S/Applications"
make_dmg "$S" "$WORK_ROOT/unstyled.dmg"
expect_fail "unstyled-no-background" "$WORK_ROOT/unstyled.dmg"

# background present but no .DS_Store → window would open unstyled.
expect_fail "no-dsstore" "$(build_dmg no-dsstore pop_with_background)"

# fully styled but icons pinned in the wrong order (app right of Applications).
expect_fail "reversed-icon-positions" "$(build_dmg reversed pop_styled_reversed)"

echo "DMG layout verifier regression tests passed"
