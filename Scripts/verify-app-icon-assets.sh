#!/usr/bin/env bash
# Verify the committed macOS app icon source, generated AppIcon set, and
# XcodeGen wiring stay in sync.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/Resources/AppIcon/rational-icon-highres.png"
ORIGINAL="$ROOT/Resources/AppIcon/rational-icon-original-1254.png"
ATTRIBUTION="$ROOT/Resources/AppIcon/README.md"
HASH_MANIFEST="$ROOT/Resources/AppIcon/manifest.sha256"
APPICON_DIR="$ROOT/Resources/Assets.xcassets/AppIcon.appiconset"
CONTENTS="$APPICON_DIR/Contents.json"
PROJECT="$ROOT/project.yml"
APP_PLIST="$ROOT/App/Info.plist"
GENERATED_PROJECT="$ROOT/RatioThink.xcodeproj/project.pbxproj"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

require_file() {
  local path="$1"
  [[ -f "$path" ]] || fail "missing file: ${path#$ROOT/}"
}

png_dimensions() {
  local path="$1"
  sips -g pixelWidth -g pixelHeight "$path" 2>/dev/null |
    awk '
      /pixelWidth:/ { w=$2 }
      /pixelHeight:/ { h=$2 }
      END {
        if (w == "" || h == "") exit 1
        printf "%sx%s", w, h
      }'
}

require_file "$SOURCE"
require_file "$ORIGINAL"
require_file "$ATTRIBUTION"
require_file "$HASH_MANIFEST"
require_file "$CONTENTS"
require_file "$PROJECT"
require_file "$APP_PLIST"

grep -F "operator-provided Rational artwork" "$ATTRIBUTION" >/dev/null ||
  fail "Resources/AppIcon/README.md must record the Rational artwork provenance"

expected_source_sha="$(
  python3 - "$ATTRIBUTION" <<'PY'
import pathlib
import re
import sys

readme = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
match = re.search(r"SHA-256 in this repository:\s*`([0-9a-f]{64})`", readme)
if not match:
    raise SystemExit("missing SHA-256 in Resources/AppIcon/README.md")
print(match.group(1))
PY
)" || fail "Resources/AppIcon/README.md must record the source SHA-256"
actual_source_sha="$(shasum -a 256 "$SOURCE" | awk '{print $1}')"
[[ "$actual_source_sha" == "$expected_source_sha" ]] ||
  fail "Resources/AppIcon/rational-icon-highres.png SHA-256 mismatch: expected $expected_source_sha, got $actual_source_sha"

expected_original_sha="$(
  python3 - "$ATTRIBUTION" <<'PY'
import pathlib
import re
import sys

readme = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
match = re.search(r"Original artwork SHA-256:\s*`([0-9a-f]{64})`", readme)
if not match:
    raise SystemExit("missing Original artwork SHA-256 in Resources/AppIcon/README.md")
print(match.group(1))
PY
)" || fail "Resources/AppIcon/README.md must record the original artwork SHA-256"
actual_original_sha="$(shasum -a 256 "$ORIGINAL" | awk '{print $1}')"
[[ "$actual_original_sha" == "$expected_original_sha" ]] ||
  fail "Resources/AppIcon/rational-icon-original-1254.png SHA-256 mismatch: expected $expected_original_sha, got $actual_original_sha"

(
  cd "$ROOT"
  shasum -a 256 -c "${HASH_MANIFEST#$ROOT/}" >/dev/null
) || fail "app icon PNG hashes do not match Resources/AppIcon/manifest.sha256"

[[ "$(png_dimensions "$SOURCE")" == "1024x1024" ]] ||
  fail "source icon must be a 1024x1024 PNG"

[[ "$(png_dimensions "$ORIGINAL")" == "1254x1254" ]] ||
  fail "original provenance icon must be a 1254x1254 PNG"

python3 - "$CONTENTS" <<'PY'
import json
import sys

contents_path = sys.argv[1]
expected = {
    ("mac", "16x16", "1x"): "app-icon-16.png",
    ("mac", "16x16", "2x"): "app-icon-32.png",
    ("mac", "32x32", "1x"): "app-icon-32.png",
    ("mac", "32x32", "2x"): "app-icon-64.png",
    ("mac", "128x128", "1x"): "app-icon-128.png",
    ("mac", "128x128", "2x"): "app-icon-256.png",
    ("mac", "256x256", "1x"): "app-icon-256.png",
    ("mac", "256x256", "2x"): "app-icon-512.png",
    ("mac", "512x512", "1x"): "app-icon-512.png",
    ("mac", "512x512", "2x"): "app-icon-1024.png",
}

with open(contents_path, "r", encoding="utf-8") as fh:
    data = json.load(fh)

images = {
    (image.get("idiom"), image.get("size"), image.get("scale")): image.get("filename")
    for image in data.get("images", [])
}
missing = []
for key, filename in expected.items():
    if images.get(key) != filename:
        missing.append(f"{key}: expected {filename}, got {images.get(key)!r}")

if missing:
    raise SystemExit("AppIcon Contents.json mismatch:\n" + "\n".join(missing))

if data.get("info", {}).get("author") != "xcode" or data.get("info", {}).get("version") != 1:
    raise SystemExit("AppIcon Contents.json must include xcode info/version metadata")
PY

for size in 16 32 64 128 256 512 1024; do
  file="$APPICON_DIR/app-icon-${size}.png"
  require_file "$file"
  [[ "$(png_dimensions "$file")" == "${size}x${size}" ]] ||
    fail "${file#$ROOT/} must be ${size}x${size}"
done

python3 - "$PROJECT" <<'PY'
import pathlib
import re
import sys

project_path = pathlib.Path(sys.argv[1])
lines = project_path.read_text(encoding="utf-8").splitlines()

in_targets = False
in_pie = False
in_sources = False
has_asset_source = False
has_app_icon_setting = False
pending_asset_source = False

for raw in lines:
    stripped = raw.strip()
    if not stripped or stripped.startswith("#"):
        continue

    indent = len(raw) - len(raw.lstrip(" "))
    uncommented = raw.split("#", 1)[0].rstrip()
    uncommented_stripped = uncommented.strip()

    if indent == 0:
        in_targets = uncommented_stripped == "targets:"
        in_pie = False
        in_sources = False
        pending_asset_source = False
        continue

    if in_targets and indent == 2 and re.match(r"[^:]+:", uncommented_stripped):
        in_pie = uncommented_stripped == "RatioThink:"
        in_sources = False
        pending_asset_source = False
        continue

    if not in_pie:
        continue

    if indent <= 2:
        in_pie = False
        in_sources = False
        pending_asset_source = False
        continue

    if indent == 4:
        in_sources = uncommented_stripped == "sources:"
        pending_asset_source = False
    elif indent <= 4:
        in_sources = False
        pending_asset_source = False

    if in_sources and re.match(r"-\s*path:\s*Resources/Assets\.xcassets\s*$", uncommented_stripped):
        has_asset_source = True
        pending_asset_source = True
        continue

    if pending_asset_source and indent == 8:
        if uncommented_stripped == "optional: true":
            pending_asset_source = False
            continue
        if uncommented_stripped.startswith("- "):
            pending_asset_source = False

    if re.match(r"ASSETCATALOG_COMPILER_APPICON_NAME:\s*AppIcon\s*$", uncommented_stripped):
        has_app_icon_setting = True

if not has_asset_source:
    raise SystemExit("project.yml RatioThink target must include Resources/Assets.xcassets in sources")
if not has_app_icon_setting:
    raise SystemExit("project.yml RatioThink target must set ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon")
PY

plist_icon_name="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIconFile" "$APP_PLIST" 2>/dev/null || true)"
[[ "$plist_icon_name" == "AppIcon" ]] ||
  fail "App/Info.plist must set CFBundleIconFile to AppIcon"

validate_generated_project() {
  local pbxproj="$1"
  local label="$2"

  python3 - "$pbxproj" "$label" <<'PY'
import re
import sys
from pathlib import Path

pbxproj = Path(sys.argv[1])
label = sys.argv[2]
text = pbxproj.read_text(encoding="utf-8")

if "Assets.xcassets in Resources" not in text:
    raise SystemExit(f"{label} must include Assets.xcassets in the RatioThink resources build phase so Xcode compiles Assets.car")
if "lastKnownFileType = folder.assetcatalog; path = Assets.xcassets;" not in text:
    raise SystemExit(f"{label} must include Resources/Assets.xcassets as an asset catalog file reference")

target_match = re.search(
    r"([0-9A-F]+) /\* RatioThink \*/ = \{\n"
    r"\s+isa = PBXNativeTarget;\n"
    r"\s+buildConfigurationList = ([0-9A-F]+) /\* Build configuration list for PBXNativeTarget \"RatioThink\" \*/;",
    text,
)
if not target_match:
    raise SystemExit(f"{label} must contain a PBXNativeTarget named RatioThink")
config_list_id = target_match.group(2)

config_list_match = re.search(
    rf"{config_list_id} /\* Build configuration list for PBXNativeTarget \"RatioThink\" \*/ = \{{.*?"
    r"buildConfigurations = \(\n(?P<ids>.*?)\n\s+\);",
    text,
    re.S,
)
if not config_list_match:
    raise SystemExit(f"{label} must contain the RatioThink target build configuration list")

config_ids = re.findall(r"([0-9A-F]+) /\* (Debug|Release) \*/", config_list_match.group("ids"))
if {name for _, name in config_ids} != {"Debug", "Release"}:
    raise SystemExit(f"{label} RatioThink target must have Debug and Release build configurations")

for config_id, config_name in config_ids:
    config_match = re.search(
        rf"{config_id} /\* {config_name} \*/ = \{{.*?buildSettings = \{{(?P<settings>.*?)\n\s+\}};",
        text,
        re.S,
    )
    if not config_match:
        raise SystemExit(f"{label} must contain RatioThink {config_name} build settings")
    settings = config_match.group("settings")
    if "ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;" not in settings:
        raise SystemExit(f"{label} RatioThink {config_name} must set ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon")
PY
}

command -v xcodegen >/dev/null 2>&1 ||
  fail "xcodegen is required to validate the generated-project app icon contract"

tmp_project_dir="$(mktemp -d "${TMPDIR:-/tmp}/pie-app-icon-xcodegen.XXXXXX")"
trap 'rm -rf "$tmp_project_dir"' EXIT
(
  cd "$ROOT"
  xcodegen generate --spec "$PROJECT" --project "$tmp_project_dir" --project-root "$ROOT" --quiet
) || fail "xcodegen failed while validating the generated-project app icon contract"
validate_generated_project "$tmp_project_dir/RatioThink.xcodeproj/project.pbxproj" "fresh XcodeGen output"

if [[ -d "$ROOT/RatioThink.xcodeproj" ]]; then
  require_file "$GENERATED_PROJECT"
  validate_generated_project "$GENERATED_PROJECT" "local RatioThink.xcodeproj"
fi

echo "App icon assets verified"
