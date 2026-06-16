#!/usr/bin/env python3
"""Regenerate the macOS app icon set from the pristine Rational artwork.

The operator-provided original is a 1254x1254 opaque PNG: a navy rounded-rect
plate carrying the Rational node-graph "R", sitting on a near-black backdrop.
macOS app icons are NOT masked by the OS (unlike iOS), so the developer ships
the fully styled rounded-rect plate with a transparent surround and the
standard icon-grid margin baked in.

Derivation (matches the recipe recorded in Resources/AppIcon/README.md):
  1. Key the near-black backdrop to alpha by flood-filling inward from the
     borders (tolerance 10). Flood fill, not a global chroma-key, so the
     plate's own near-black navy corners are never eaten.
  2. Crop to the keyed plate's alpha bounding box.
  3. Composite the plate at 824/1024 of a transparent 1024x1024 canvas (the
     standard macOS icon-grid margin) -> rational-icon-highres.png.
  4. Lanczos-downscale that master to every appiconset size. app-icon-1024.png
     is a byte-identical copy of the master.

Requires Pillow (`python3 -m pip install pillow`). This is a one-off
regeneration tool, not a build or test dependency.

Usage:
  Scripts/generate-app-icon.py [ORIGINAL_PNG]

ORIGINAL_PNG defaults to Resources/AppIcon/rational-icon-original-1254.png.
"""

from __future__ import annotations

import sys
from collections import deque
from pathlib import Path

from PIL import Image, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
APPICON_SOURCE = ROOT / "Resources" / "AppIcon"
APPICON_SET = ROOT / "Resources" / "Assets.xcassets" / "AppIcon.appiconset"

DEFAULT_ORIGINAL = APPICON_SOURCE / "rational-icon-original-1254.png"
HIGHRES = APPICON_SOURCE / "rational-icon-highres.png"

CANVAS = 1024          # master canvas edge
PLATE = 824            # plate edge on the master (macOS icon-grid margin)
KEY_TOLERANCE = 10     # backdrop is "near black": max(R,G,B) <= tolerance
FEATHER = 1.2          # alpha blur radius (px, at original resolution)
SIZES = (1024, 512, 256, 128, 64, 32, 16)


def key_backdrop_to_alpha(im: Image.Image) -> Image.Image:
    """Flood-fill the near-black backdrop inward from the borders to alpha."""
    rgb = im.convert("RGB")
    px = rgb.load()
    w, h = rgb.size

    near = [[max(px[x, y]) <= KEY_TOLERANCE for x in range(w)] for y in range(h)]
    bg = [[False] * w for _ in range(h)]
    dq: deque[tuple[int, int]] = deque()

    def seed(x: int, y: int) -> None:
        if near[y][x] and not bg[y][x]:
            bg[y][x] = True
            dq.append((x, y))

    for x in range(w):
        seed(x, 0)
        seed(x, h - 1)
    for y in range(h):
        seed(0, y)
        seed(w - 1, y)

    while dq:
        x, y = dq.popleft()
        for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
            if 0 <= nx < w and 0 <= ny < h and not bg[ny][nx] and near[ny][nx]:
                bg[ny][nx] = True
                dq.append((nx, ny))

    alpha = Image.new("L", (w, h), 255)
    ap = alpha.load()
    for y in range(h):
        row = bg[y]
        for x in range(w):
            if row[x]:
                ap[x, y] = 0
    # Feather the keyed edge so the rounded corners stay smooth after downscale.
    alpha = alpha.filter(ImageFilter.GaussianBlur(FEATHER))

    out = rgb.convert("RGBA")
    out.putalpha(alpha)
    return out


def crop_to_alpha_bbox(im: Image.Image) -> Image.Image:
    bbox = im.getchannel("A").getbbox()
    return im.crop(bbox) if bbox else im


def build_master(original: Path) -> Image.Image:
    plate = crop_to_alpha_bbox(key_backdrop_to_alpha(Image.open(original)))
    plate = plate.resize((PLATE, PLATE), Image.LANCZOS)
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    offset = (CANVAS - PLATE) // 2
    canvas.alpha_composite(plate, (offset, offset))
    return canvas


def main() -> int:
    original = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_ORIGINAL
    if not original.is_file():
        print(f"error: original artwork not found: {original}", file=sys.stderr)
        return 1

    master = build_master(original)
    master.save(HIGHRES)
    for size in SIZES:
        img = master if size == CANVAS else master.resize((size, size), Image.LANCZOS)
        img.save(APPICON_SET / f"app-icon-{size}.png")

    print(f"Generated {HIGHRES.relative_to(ROOT)} and {len(SIZES)} appiconset sizes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
