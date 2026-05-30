#!/usr/bin/env python3
"""Write a styled `.DS_Store` for the RatioThink drag-install DMG.

Finder AppleScript cannot style a DMG under automation (it times out on every
Apple event) and is impossible in CI, so we generate the icon-view layout
directly — the same approach `dmgbuild` uses. Given a *mounted* writable DMG
volume that already contains `RatioThink.app`, an `Applications` symlink and
`.background/background.png`, this writes a `.DS_Store` at the volume root that:

  * shows the window as 128pt icons with no auto-arrangement,
  * pins RatioThink.app on the LEFT and Applications on the RIGHT so the
    background arrow points app -> Applications, and
  * sets the background picture to the staged `.background/background.png`.

The geometry constants MUST match Scripts/make-dmg-background.swift (SLOT_APP_X
/ SLOT_APPS_X / CENTER_Y and the canvas size), or the arrow will not line up.

After writing, the store is re-read and validated; a malformed store exits
non-zero so the build fails loudly instead of silently shipping an unstyled DMG.

Usage: make-dmg-dsstore.py <mounted-volume-path>
"""

import os
import sys

# Vendored, pure-Python ds_store + mac_alias keep the build self-contained.
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "vendor"))

from ds_store import DSStore  # noqa: E402
from mac_alias import Alias  # noqa: E402

APP_NAME = "RatioThink.app"
APPS_NAME = "Applications"
BACKGROUND_REL = ".background/background.png"

# Canvas + slot geometry — keep in sync with make-dmg-background.swift.
CANVAS_W, CANVAS_H = 600, 400
WINDOW_X, WINDOW_Y = 200, 120
ICON_SIZE = 128
APP_POS = (150, 200)   # left slot
APPS_POS = (450, 200)  # right slot


def build(volume: str) -> None:
    bg_path = os.path.join(volume, BACKGROUND_REL)
    if not os.path.isfile(bg_path):
        sys.exit(f"make-dmg-dsstore.py: background missing at {bg_path}")
    if not os.path.isdir(os.path.join(volume, APP_NAME)):
        sys.exit(f"make-dmg-dsstore.py: {APP_NAME} missing in {volume}")

    # mac_alias resolves the on-volume background to a volume-relative classic
    # alias ("RatioThink:.background:background.png"), so it re-resolves when an
    # end user mounts the shipped DMG.
    background_alias = Alias.for_file(bg_path).to_bytes()

    ds_path = os.path.join(volume, ".DS_Store")
    with DSStore.open(ds_path, "w+") as d:
        d["."]["vSrn"] = ("long", 1)
        d["."]["ICVO"] = ("bool", True)
        d["."]["vstl"] = ("type", b"icnv")  # default to icon view
        d["."]["bwsp"] = {
            "WindowBounds": "{{%d, %d}, {%d, %d}}" % (WINDOW_X, WINDOW_Y, CANVAS_W, CANVAS_H),
            "ContainerShowSidebar": False,
            "ShowPathbar": False,
            "ShowSidebar": False,
            "ShowStatusBar": False,
            "ShowTabView": False,
            "ShowToolbar": False,
            "SidebarWidth": 0,
            "ViewStyle": "icnv",
        }
        d["."]["icvp"] = {
            "viewOptionsVersion": 1,
            "backgroundType": 2,  # 2 = picture
            "backgroundImageAlias": background_alias,
            "backgroundColorRed": 1.0,
            "backgroundColorGreen": 1.0,
            "backgroundColorBlue": 1.0,
            "gridOffsetX": 0.0,
            "gridOffsetY": 0.0,
            "gridSpacing": 100.0,
            "arrangeBy": "none",
            "showIconPreview": False,
            "showItemInfo": False,
            "labelOnBottom": True,
            "textSize": 12.0,
            "iconSize": float(ICON_SIZE),
            "scrollPositionX": 0.0,
            "scrollPositionY": 0.0,
        }
        d[APP_NAME]["Iloc"] = APP_POS
        d[APPS_NAME]["Iloc"] = APPS_POS

    validate(ds_path)
    print(f"make-dmg-dsstore.py: wrote styled .DS_Store ({ds_path})")


def validate(ds_path: str) -> None:
    """Re-read the store and confirm the styling persisted and is well-formed.

    A subtly malformed store makes Finder discard it and show an unstyled
    window, so treat any read-back mismatch as a hard failure.
    """
    found = {}
    background_ok = False
    with DSStore.open(ds_path, "r") as d:
        for entry in d:
            if entry.code == b"Iloc" and entry.filename in (APP_NAME, APPS_NAME):
                found[entry.filename] = tuple(entry.value[:2])
            if entry.filename == "." and entry.code == b"icvp":
                icvp = entry.value
                background_ok = (
                    icvp.get("backgroundType") == 2
                    and bool(icvp.get("backgroundImageAlias"))
                )

    if found.get(APP_NAME) != APP_POS:
        sys.exit(f"make-dmg-dsstore.py: validation failed — {APP_NAME} Iloc={found.get(APP_NAME)} != {APP_POS}")
    if found.get(APPS_NAME) != APPS_POS:
        sys.exit(f"make-dmg-dsstore.py: validation failed — {APPS_NAME} Iloc={found.get(APPS_NAME)} != {APPS_POS}")
    if found[APP_NAME][0] >= found[APPS_NAME][0]:
        sys.exit("make-dmg-dsstore.py: validation failed — app is not left of Applications")
    if not background_ok:
        sys.exit("make-dmg-dsstore.py: validation failed — background picture not set in icvp")


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit("make-dmg-dsstore.py: usage: make-dmg-dsstore.py <mounted-volume-path>")
    volume = sys.argv[1]
    if not os.path.isdir(volume):
        sys.exit(f"make-dmg-dsstore.py: not a directory: {volume}")
    build(volume)


if __name__ == "__main__":
    main()
