#!/usr/bin/env bash
# Regression tests for Scripts/verify-dmg-layout.sh (ticket #354). Each
# case builds a real DMG fixture (hdiutil) with a mutated drag-install
# layout and asserts the verifier's pass/fail verdict. Exercises the
# REAL hdiutil + codesign — no xcodebuild — so it runs in CI under the
# lint job alongside the app-icon verifier tests.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFIER="$ROOT/Scripts/verify-dmg-layout.sh"
WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/pie-dmg-verifier-tests.XXXXXX")"

cleanup() {
  rm -rf "$WORK_ROOT"
}
trap cleanup EXIT

# Build a minimal, ad-hoc-signed RatioThink.app at $1. /bin/echo is a
# real mach-o, so the bundle is a valid codesign target whose seal a
# `--strict` verify can both accept (intact) and reject (tampered).
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

# hdiutil-create a UDZO DMG from staging dir $1 into $2 (mirrors the
# production package-dmg.sh image format).
make_dmg() {
  local stage="$1" dmg="$2"
  rm -f "$dmg"
  hdiutil create -volname "RatioThink" -srcfolder "$stage" -fs HFS+ -format UDZO "$dmg" >/dev/null
}

# Correct drag-install layout: app + Applications -> /Applications.
stage_baseline() {
  local s="$1"
  mkdir -p "$s"
  make_dummy_app "$s/RatioThink.app"
  ln -s /Applications "$s/Applications"
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

# baseline: the layout package-dmg.sh must produce.
S="$WORK_ROOT/baseline-stage"
stage_baseline "$S"
make_dmg "$S" "$WORK_ROOT/baseline.dmg"
expect_pass "baseline" "$WORK_ROOT/baseline.dmg"

# missing Applications symlink → no drag-install target.
S="$WORK_ROOT/noapps-stage"
mkdir -p "$S"
make_dummy_app "$S/RatioThink.app"
make_dmg "$S" "$WORK_ROOT/noapps.dmg"
expect_fail "missing-applications-symlink" "$WORK_ROOT/noapps.dmg"

# Applications symlink resolves somewhere other than /Applications →
# a drag would not install into the real Applications folder.
S="$WORK_ROOT/wrongtarget-stage"
mkdir -p "$S"
make_dummy_app "$S/RatioThink.app"
ln -s /tmp "$S/Applications"
make_dmg "$S" "$WORK_ROOT/wrongtarget.dmg"
expect_fail "applications-symlink-wrong-target" "$WORK_ROOT/wrongtarget.dmg"

# missing app bundle → nothing to install.
S="$WORK_ROOT/noapp-stage"
mkdir -p "$S"
ln -s /Applications "$S/Applications"
mkdir -p "$S/Readme"
echo "x" >"$S/Readme/x.txt"
make_dmg "$S" "$WORK_ROOT/noapp.dmg"
expect_fail "missing-app-bundle" "$WORK_ROOT/noapp.dmg"

# tampered executable → the verifier's codesign seal check must reject it.
# Guards the acceptance criterion "the app inside the DMG still passes
# codesign verification" by proving the check actually fails on a broken seal
# rather than rubber-stamping every DMG.
S="$WORK_ROOT/broken-stage"
stage_baseline "$S"
printf 'tamper' >>"$S/RatioThink.app/Contents/MacOS/RatioThink"
make_dmg "$S" "$WORK_ROOT/broken.dmg"
expect_fail "broken-codesign-seal" "$WORK_ROOT/broken.dmg"

echo "DMG layout verifier regression tests passed"
