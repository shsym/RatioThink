#!/usr/bin/env bash
# Regression tests for Scripts/verify-app-icon-assets.sh. Each case mutates a
# temp copy of the app-icon contract and asserts the verifier catches it.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/pie-app-icon-verifier-tests.XXXXXX")"

# Pin the regeneration toolchain exactly to the Pillow the committed assets were
# produced with (byte-identical at 12.2.0). Bump deliberately alongside a
# manifest re-lock; a floating 12.* would red CI on any future Lanczos/PNG
# encoding change even when the artwork and generator are unchanged.
PILLOW_PIN="pillow==12.2.0"

cleanup() {
  rm -rf "$WORK_ROOT"
}
trap cleanup EXIT

copy_fixture() {
  local fixture="$1"
  mkdir -p "$fixture"

  cp "$ROOT/project.yml" "$fixture/"
  mkdir -p "$fixture/App" "$fixture/Resources" "$fixture/Scripts"
  cp "$ROOT/App/Info.plist" "$fixture/App/"
  cp -R "$ROOT/Resources/AppIcon" "$fixture/Resources/"
  cp -R "$ROOT/Resources/Assets.xcassets" "$fixture/Resources/"
  cp "$ROOT/Scripts/genproject.sh" "$fixture/Scripts/"
  cp "$ROOT/Scripts/verify-app-icon-assets.sh" "$fixture/Scripts/"
  cp "$ROOT/Scripts/generate-app-icon.py" "$fixture/Scripts/"

  # XcodeGen validates source paths when generating the project. Copy the small
  # source roots named by project.yml so the generated-project contract is
  # exercised without copying heavyweight build/vendor artifacts.
  for path in App Shared Helper Tests Inferlets; do
    if [[ -d "$ROOT/$path" ]]; then
      cp -R "$ROOT/$path" "$fixture/"
    fi
  done
}

prepare_fixture() {
  local name="$1"
  local fixture="$WORK_ROOT/$name"
  copy_fixture "$fixture"
  (
    cd "$fixture"
    Scripts/genproject.sh >/dev/null
  )
  printf "%s" "$fixture"
}

prepare_clean_fixture() {
  local name="$1"
  local fixture="$WORK_ROOT/$name"
  copy_fixture "$fixture"
  printf "%s" "$fixture"
}

append_png_text_chunk() {
  local png="$1"
  python3 - "$png" <<'PY'
import pathlib
import struct
import sys
import zlib

png_path = pathlib.Path(sys.argv[1])
data = png_path.read_bytes()
iend = data.rfind(b"\x00\x00\x00\x00IEND\xaeB`\x82")
if iend == -1:
    raise SystemExit(f"missing IEND chunk in {png_path}")

chunk_type = b"tEXt"
payload = b"pie-verifier-test\x00content-drift"
chunk = (
    struct.pack(">I", len(payload))
    + chunk_type
    + payload
    + struct.pack(">I", zlib.crc32(chunk_type + payload) & 0xFFFFFFFF)
)
png_path.write_bytes(data[:iend] + chunk + data[iend:])
PY
}

run_verifier() {
  local fixture="$1"
  (
    cd "$fixture"
    Scripts/verify-app-icon-assets.sh
  )
}

expect_success() {
  local name="$1"
  local fixture
  fixture="$(prepare_fixture "$name")"

  if ! run_verifier "$fixture" >"$fixture/verify.log" 2>&1; then
    cat "$fixture/verify.log" >&2
    echo "FAIL: expected verifier success for $name" >&2
    exit 1
  fi
}

expect_clean_success() {
  local name="$1"
  local fixture
  fixture="$(prepare_clean_fixture "$name")"

  if [[ -e "$fixture/RatioThink.xcodeproj" ]]; then
    echo "FAIL: clean fixture unexpectedly contains RatioThink.xcodeproj" >&2
    exit 1
  fi

  if ! run_verifier "$fixture" >"$fixture/verify.log" 2>&1; then
    cat "$fixture/verify.log" >&2
    echo "FAIL: expected verifier success for clean fixture $name" >&2
    exit 1
  fi
}

expect_clean_failure() {
  local name="$1"
  local mutation="$2"
  local fixture
  fixture="$(prepare_clean_fixture "$name")"

  "$mutation" "$fixture"

  if run_verifier "$fixture" >"$fixture/verify.log" 2>&1; then
    cat "$fixture/verify.log" >&2
    echo "FAIL: expected verifier failure for clean fixture $name" >&2
    exit 1
  fi
}

expect_failure() {
  local name="$1"
  local mutation="$2"
  local fixture
  fixture="$(prepare_fixture "$name")"

  "$mutation" "$fixture"

  if run_verifier "$fixture" >"$fixture/verify.log" 2>&1; then
    cat "$fixture/verify.log" >&2
    echo "FAIL: expected verifier failure for $name" >&2
    exit 1
  fi
}

expect_reproducible_manifest() {
  local name="$1"
  local fixture
  fixture="$(prepare_clean_fixture "$name")"

  command -v uv >/dev/null 2>&1 || {
    echo "FAIL: uv is required to regenerate the app icon under a pinned Pillow" >&2
    exit 1
  }

  if ! (
    cd "$fixture"
    uv run --no-project --with "$PILLOW_PIN" python3 Scripts/generate-app-icon.py
  ) >"$fixture/regen.log" 2>&1; then
    cat "$fixture/regen.log" >&2
    echo "FAIL: generate-app-icon.py failed during reproducibility check for $name" >&2
    exit 1
  fi

  # Assert every regenerated artifact (highres + all appiconset downscales)
  # matches the committed manifest, not just the highres master, so a
  # downscale-path regression (wrong SIZES entry, changed resize filter) is
  # caught too.
  if ! (
    cd "$fixture"
    shasum -a 256 -c Resources/AppIcon/manifest.sha256
  ) >"$fixture/regen-verify.log" 2>&1; then
    cat "$fixture/regen-verify.log" >&2
    echo "FAIL: regenerated app icon bytes do not match manifest.sha256 for $name" >&2
    exit 1
  fi
}

mutate_source_png() {
  append_png_text_chunk "$1/Resources/AppIcon/rational-icon-highres.png"
}

mutate_original_png() {
  append_png_text_chunk "$1/Resources/AppIcon/rational-icon-original-1254.png"
}

mutate_generated_png() {
  append_png_text_chunk "$1/Resources/Assets.xcassets/AppIcon.appiconset/app-icon-256.png"
}

mutate_plist_icon_name() {
  /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile WrongIcon" "$1/App/Info.plist"
}

mutate_remove_asset_source() {
  python3 - "$1/project.yml" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
needle = "      - path: Resources/Assets.xcassets\n        optional: true\n"
if needle not in text:
    raise SystemExit("expected asset catalog source entry not found")
path.write_text(text.replace(needle, "", 1))
PY
}

mutate_comment_app_icon_setting() {
  python3 - "$1/project.yml" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
needle = "        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon\n"
if needle not in text:
    raise SystemExit("expected app icon setting not found")
path.write_text(text.replace(needle, "        # ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon\n", 1))
PY
}

mutate_stale_generated_project() {
  python3 - "$1/RatioThink.xcodeproj/project.pbxproj" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
needle = "ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;"
if needle not in text:
    raise SystemExit("expected generated app icon setting not found")
path.write_text(text.replace(needle, "ASSETCATALOG_COMPILER_APPICON_NAME = WrongIcon;"))
PY
}

mutate_partial_generated_project_dir() {
  mkdir -p "$1/RatioThink.xcodeproj"
}

expect_reproducible_manifest "regenerate-matches-manifest"
expect_clean_success "clean-without-generated-project"
expect_clean_failure "partial-generated-project-dir" mutate_partial_generated_project_dir
expect_success "baseline"
expect_failure "source-png-drift" mutate_source_png
expect_failure "original-png-drift" mutate_original_png
expect_failure "generated-png-drift" mutate_generated_png
expect_failure "wrong-plist-icon-name" mutate_plist_icon_name
expect_failure "missing-asset-source-entry" mutate_remove_asset_source
expect_failure "commented-project-app-icon-setting" mutate_comment_app_icon_setting
expect_failure "stale-generated-project" mutate_stale_generated_project

echo "App icon verifier regression tests passed"
