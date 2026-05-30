#!/usr/bin/env bash
# Mount a packaged RatioThink DMG read-only and assert the drag-install
# layout + window styling (ticket #354):
#   * the mounted root contains RatioThink.app,
#   * the root contains an `Applications` symlink to /Applications so the
#     window offers the familiar drag-install target,
#   * the app still passes a strict codesign seal check — i.e. packaging
#     did not corrupt the signed bundle,
#   * the background asset is present, and
#   * the `.DS_Store` pins the icons with RatioThink.app LEFT of Applications
#     and sets the background picture.
#
# The styling checks read the `.DS_Store` directly (via the vendored ds_store
# parser), so verification needs no GUI and runs in CI.
#
# Usage: Scripts/verify-dmg-layout.sh <dmg>
#
# package-dmg.sh calls this on every build so a silent layout/styling/seal
# regression fails the package instead of shipping.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# Styling: the background art and the .DS_Store icon layout.
[[ -f "$MNT/.background/background.png" ]] ||
  fail "mounted DMG is missing the background asset (.background/background.png)"
[[ -f "$MNT/.DS_Store" ]] ||
  fail "mounted DMG has no .DS_Store — the window is unstyled"

# Parse the .DS_Store with the ds_store submodule reader and assert the icons
# are pinned at the EXACT positions from the shared geometry file (the same file
# the background art is drawn from) and that the background picture is set.
# Self-contained + GUI-free, so it runs the same in CI.
if ! VENDOR_DIR="$SCRIPT_DIR/vendor" GEOMETRY_JSON="$SCRIPT_DIR/dmg-window.json" \
     python3 - "$MNT/.DS_Store" <<'PY'
import json, os, sys
vendor = os.environ["VENDOR_DIR"]
src = {name: os.path.join(vendor, name, "src") for name in ("ds_store", "mac_alias")}
missing = [n for n, s in src.items() if not os.path.isfile(os.path.join(s, n, "__init__.py"))]
if missing:
    sys.exit("required submodule(s) not initialized: " + ", ".join(missing)
             + "\n  Run: git submodule update --init --recursive")
for s in src.values():
    sys.path.insert(0, s)
from ds_store import DSStore

with open(os.environ["GEOMETRY_JSON"], encoding="utf-8") as f:
    geo = json.load(f)
expected = {name: (i["x"], i["y"]) for name, i in geo["icons"].items()}

ds_path = sys.argv[1]
pos = {}
background_set = False
with DSStore.open(ds_path, "r") as d:
    for e in d:
        if e.code == b"Iloc" and e.filename in expected:
            pos[e.filename] = tuple(e.value[:2])
        if e.filename == "." and e.code == b"icvp":
            icvp = e.value
            background_set = icvp.get("backgroundType") == 2 and bool(icvp.get("backgroundImageAlias"))

# Assert the shipped positions match the shared geometry exactly (not just
# ordering), so the icons stay aligned with the drawn arrow.
if pos != expected:
    sys.exit(f"icon positions {pos} do not match the geometry contract {expected}")
app = expected["RatioThink.app"]
apps = expected["Applications"]
if app[0] >= apps[0]:
    sys.exit(f"geometry contract is inconsistent — app ({app}) is not left of Applications ({apps})")
if not background_set:
    sys.exit("background picture is not set in the icon-view options (icvp)")
PY
then
  fail "DMG window styling check failed (see above)"
fi

echo "verify-dmg-layout.sh: ok — RatioThink.app + Applications target, codesign valid, styled window ($DMG)"
