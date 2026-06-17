#!/usr/bin/env python3
"""Regenerate the docs/landing web favicons from the Rational node-graph "R".

The published landing page (docs/landing.html, docs/architecture.html) brands
itself with three web icons under docs/. They must show the same node-graph "R"
plate the macOS app icon ships, not the retired node-tree artwork.

All three derive from the committed app-icon master
(Resources/AppIcon/rational-icon-highres.png): a transparent 1024x1024 canvas
carrying the styled navy rounded-rect plate. The master keeps the macOS
icon-grid margin (plate at 824/1024); the web icons want the plate framed at
the landing site's own ~93% margin, so the master is cropped to the plate's
alpha bounding box and recomposited.

  - pie-icon.png        256x256 RGBA, plate on a transparent surround (favicon
                        + landing hero image).
  - apple-touch-icon.png 180x180 RGB, plate flattened onto white (iOS adds its
                        own mask, so no transparency).
  - favicon.ico         16/32/48 RGBA multi-resolution icon.

Requires Pillow (`python3 -m pip install pillow`). One-off regeneration tool,
not a build or test dependency.

Usage:
  Scripts/generate-docs-icons.py
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
MASTER = ROOT / "Resources" / "AppIcon" / "rational-icon-highres.png"
DOCS = ROOT / "docs"
ASSETS = DOCS / "assets"

PLATE_FRACTION = 0.93           # plate edge as a fraction of the icon canvas
WHITE = (255, 255, 255)
FAVICON_SIZES = (16, 32, 48)
MASTER_SIZE = (1024, 1024)      # app-icon master canvas (macOS icon grid)


def load_plate() -> Image.Image:
    """Crop the app-icon master down to the styled plate (drop the grid margin)."""
    master = Image.open(MASTER).convert("RGBA")
    if master.size != MASTER_SIZE:
        raise ValueError(
            f"app-icon master {MASTER} is {master.size}, expected {MASTER_SIZE}; "
            "the web icons derive from the 1024x1024 node-graph plate."
        )
    bbox = master.getchannel("A").getbbox()
    if bbox is None:
        raise ValueError(
            f"app-icon master {MASTER} has an empty alpha channel; expected the "
            "transparent-surround node-graph plate."
        )
    return master.crop(bbox)


def frame(plate: Image.Image, size: int) -> Image.Image:
    """Composite the plate, centered at PLATE_FRACTION, on a transparent canvas."""
    edge = round(size * PLATE_FRACTION)
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    scaled = plate.resize((edge, edge), Image.LANCZOS)
    offset = (size - edge) // 2
    canvas.alpha_composite(scaled, (offset, offset))
    return canvas


def main() -> int:
    plate = load_plate()

    frame(plate, 256).save(ASSETS / "pie-icon.png")

    touch = Image.new("RGBA", (180, 180), WHITE + (255,))
    touch.alpha_composite(frame(plate, 180))
    touch.convert("RGB").save(ASSETS / "apple-touch-icon.png")

    largest = max(FAVICON_SIZES)
    frame(plate, largest).save(
        DOCS / "favicon.ico",
        format="ICO",
        sizes=[(s, s) for s in FAVICON_SIZES],
    )

    print(
        "Generated docs/assets/pie-icon.png, docs/assets/apple-touch-icon.png, "
        "docs/favicon.ico from the node-graph R master"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
