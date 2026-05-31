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

The window geometry (icon positions + canvas size) is read from the shared
Scripts/dmg-window.json — the single source of truth make-dmg-background.swift
draws the arrow from and verify-dmg-layout.sh asserts — so the icons and the
arrow stay aligned without a second copy to keep in sync.

After writing, the store is re-read and validated; a malformed store exits
non-zero so the build fails loudly instead of silently shipping an unstyled DMG.

Requires the ds_store + mac_alias git submodules under Scripts/vendor/ (pinned
release commits). Initialize them with `git submodule update --init --recursive`;
this script fails loud with that command if they are missing.

Usage: make-dmg-dsstore.py <mounted-volume-path>
"""

import json
import os
import sys

# ds_store + mac_alias are required runtime deps, pinned as git submodules
# under Scripts/vendor/ (both use a src/ layout). Fail loud with the exact
# init command if the submodules were not checked out, rather than letting it
# surface as a cryptic ImportError.
_HERE = os.path.dirname(os.path.abspath(__file__))
_SUBMODULE_SRC = {
    "ds_store": os.path.join(_HERE, "vendor", "ds_store", "src"),
    "mac_alias": os.path.join(_HERE, "vendor", "mac_alias", "src"),
}
_missing = [
    name for name, src in _SUBMODULE_SRC.items()
    if not os.path.isfile(os.path.join(src, name, "__init__.py"))
]
if _missing:
    sys.exit(
        "make-dmg-dsstore.py: required submodule(s) not initialized: "
        + ", ".join(_missing)
        + "\n  Run: git submodule update --init --recursive"
    )
for _src in _SUBMODULE_SRC.values():
    sys.path.insert(0, _src)

from ds_store import DSStore  # noqa: E402
from mac_alias import Alias  # noqa: E402

APP_NAME = "RatioThink.app"
APPS_NAME = "Applications"
BACKGROUND_REL = ".background/background.png"

# Window + slot geometry come from the shared geometry file, the single source
# of truth also read by make-dmg-background.swift (arrow art) and
# verify-dmg-layout.sh (asserts these positions). Edit Scripts/dmg-window.json,
# not these values.
with open(os.path.join(_HERE, "dmg-window.json"), encoding="utf-8") as _gf:
    _GEO = json.load(_gf)
CANVAS_W = _GEO["window"]["width"]
CANVAS_H = _GEO["window"]["height"]
ICON_SIZE = _GEO["iconSize"]
APP_POS = (_GEO["icons"][APP_NAME]["x"], _GEO["icons"][APP_NAME]["y"])
APPS_POS = (_GEO["icons"][APPS_NAME]["x"], _GEO["icons"][APPS_NAME]["y"])
# On-screen window origin is cosmetic (where the window opens), not part of the
# geometry contract the art/verifier share.
WINDOW_X, WINDOW_Y = 200, 120


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
    background_alias = None
    with DSStore.open(ds_path, "r") as d:
        for entry in d:
            if entry.code == b"Iloc" and entry.filename in (APP_NAME, APPS_NAME):
                found[entry.filename] = tuple(entry.value[:2])
            if entry.filename == "." and entry.code == b"icvp":
                icvp = entry.value
                if icvp.get("backgroundType") == 2:
                    background_alias = icvp.get("backgroundImageAlias")

    if found.get(APP_NAME) != APP_POS:
        sys.exit(f"make-dmg-dsstore.py: validation failed — {APP_NAME} Iloc={found.get(APP_NAME)} != {APP_POS}")
    if found.get(APPS_NAME) != APPS_POS:
        sys.exit(f"make-dmg-dsstore.py: validation failed — {APPS_NAME} Iloc={found.get(APPS_NAME)} != {APPS_POS}")
    if found[APP_NAME][0] >= found[APPS_NAME][0]:
        sys.exit("make-dmg-dsstore.py: validation failed — app is not left of Applications")
    if not background_alias:
        sys.exit("make-dmg-dsstore.py: validation failed — background picture not set in icvp")

    # Don't just trust that the alias bytes are non-empty: decode them and
    # confirm they actually resolve to .background/background.png, so a stale or
    # wrong alias is caught rather than read as "styled".
    target = Alias.from_bytes(background_alias).target
    name = target.filename
    if isinstance(name, bytes):
        name = name.decode("utf-8", "replace")
    carbon = target.carbon_path or b""
    if isinstance(carbon, bytes):
        carbon = carbon.decode("latin-1")
    if name != "background.png" or ".background:" not in carbon:
        sys.exit(
            "make-dmg-dsstore.py: validation failed — background alias does not "
            f"resolve to {BACKGROUND_REL} (filename={name!r}, path={carbon!r})"
        )


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit("make-dmg-dsstore.py: usage: make-dmg-dsstore.py <mounted-volume-path>")
    volume = sys.argv[1]
    if not os.path.isdir(volume):
        sys.exit(f"make-dmg-dsstore.py: not a directory: {volume}")
    build(volume)


if __name__ == "__main__":
    main()
