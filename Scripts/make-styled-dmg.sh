#!/usr/bin/env bash
# Build the styled drag-install DMG from an already-built RatioThink.app:
# stage the app + an `Applications` symlink + the background art into a writable
# image, write the styled `.DS_Store` (icon positions + background picture) via
# make-dmg-dsstore.py, then convert to a compressed read-only DMG.
#
# No Finder/osascript — the window layout is written to the `.DS_Store`
# directly, so this runs identically on a dev Mac and in CI.
#
# The staging image is mounted at /Volumes/RatioThink, NOT a private `mktemp`
# `-mountpoint`. mac_alias only emits a correct volume-relative background alias
# ("RatioThink:.background:background.png") when the volume is mounted under
# /Volumes; a private mountpoint yields a broken "..:..:..:tmp:..." alias path
# (measured), which would ship a background that cannot resolve on the user's
# machine. Because that mountpoint is fixed, we refuse to run when a volume
# named RatioThink is already mounted and assert our image actually landed
# there — instead of blindly assuming the path, force-ejecting an unrelated
# volume, or letting a concurrent build leg corrupt the staging volume.
#
# Usage: make-styled-dmg.sh <app-path> <out-dmg>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

APP_PATH="${1:-}"
OUT_DMG="${2:-}"
if [[ -z "$APP_PATH" || -z "$OUT_DMG" ]]; then
  echo "make-styled-dmg.sh: usage: make-styled-dmg.sh <app-path> <out-dmg>" >&2
  exit 64
fi
if [[ ! -d "$APP_PATH" ]]; then
  echo "make-styled-dmg.sh: app not found: $APP_PATH" >&2
  exit 66
fi

VOLNAME="RatioThink"
STAGE_MOUNT="/Volumes/$VOLNAME"

# Refuse if a RatioThink volume is already mounted: we must use this exact
# mountpoint (see header), and we will neither write into nor eject a volume we
# did not create — which also makes a concurrent dmg-arm64/dmg-x86_64 leg fail
# loud here rather than corrupt a shared staging volume.
if [[ -e "$STAGE_MOUNT" ]]; then
  echo "make-styled-dmg.sh: a volume is already mounted at $STAGE_MOUNT" >&2
  echo "  detach it first: hdiutil detach \"$STAGE_MOUNT\"" >&2
  exit 75
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pie-styled-dmg.XXXXXX")"
RW_DMG="$WORK/rw.dmg"
BG_PNG="$WORK/background.png"
# Detach ONLY the mount this script created, never a bare /Volumes/RatioThink:
# if a racing process mounts there between the pre-check and our attach, our
# image lands at "/Volumes/RatioThink 1" and the mismatch branch ejects that
# (ours); the trap must not then force-eject the racing volume we did not create.
# Set only after the post-attach match check passes.
CREATED_MOUNT=""
cleanup() {
  if [[ -n "$CREATED_MOUNT" ]]; then
    hdiutil detach "$CREATED_MOUNT" >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# Background art (self-contained; geometry comes from the shared dmg-window.json
# that make-dmg-dsstore.py and verify-dmg-layout.sh also read).
xcrun swift "$SCRIPT_DIR/make-dmg-background.swift" "$BG_PNG" "$SCRIPT_DIR/dmg-window.json"

# Size the writable image to the app plus slack for HFS metadata + .DS_Store.
APP_MB=$(du -sm "$APP_PATH" | cut -f1)
IMG_MB=$((APP_MB + 60))
hdiutil create -size "${IMG_MB}m" -fs HFS+ -volname "$VOLNAME" "$RW_DMG" >/dev/null

# Attach, then confirm it actually mounted where we expect. A stray same-name
# volume that appeared between the check above and now would push macOS to
# "/Volumes/RatioThink 1"; refuse rather than stage the wrong volume.
ATTACH_OUT="$(hdiutil attach "$RW_DMG" -nobrowse -noverify)"
ACTUAL_MOUNT="$(printf '%s\n' "$ATTACH_OUT" | awk '/\/Volumes\//{print substr($0, index($0, "/Volumes/"))}' | tail -1)"
if [[ "$ACTUAL_MOUNT" != "$STAGE_MOUNT" ]]; then
  echo "make-styled-dmg.sh: staging image mounted at unexpected '$ACTUAL_MOUNT' (expected $STAGE_MOUNT)" >&2
  hdiutil detach "$ACTUAL_MOUNT" >/dev/null 2>&1 || true
  exit 75
fi
# We created this mount and confirmed it is ours — the trap may clean it up.
CREATED_MOUNT="$ACTUAL_MOUNT"

# Populate the volume: the verified app (ditto preserves its signature and
# leaves $APP_PATH untouched), the Applications drag target, and the background.
ditto "$APP_PATH" "$STAGE_MOUNT/RatioThink.app"
ln -s /Applications "$STAGE_MOUNT/Applications"
mkdir -p "$STAGE_MOUNT/.background"
cp "$BG_PNG" "$STAGE_MOUNT/.background/background.png"

# Write the styled .DS_Store. Self-validating: a malformed store fails here
# rather than shipping a plain window.
python3 "$SCRIPT_DIR/make-dmg-dsstore.py" "$STAGE_MOUNT"

sync
hdiutil detach "$CREATED_MOUNT" >/dev/null
CREATED_MOUNT=""  # detached cleanly; nothing left for the trap to eject

# Compress the styled writable image to the final read-only DMG.
rm -f "$OUT_DMG"
hdiutil convert "$RW_DMG" -format UDZO -o "$OUT_DMG" >/dev/null

echo "make-styled-dmg.sh: ok ($OUT_DMG)"
