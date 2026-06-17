# Rational app icon source

`rational-icon-highres.png` is the committed high-resolution source for
`Resources/Assets.xcassets/AppIcon.appiconset/`. It is derived from the
operator-provided Rational node-graph "R" artwork; it is no longer the
upstream `pie-project/pie-desktop` icon.

## Provenance root

`rational-icon-original-1254.png` is the pristine operator-provided original
(1254x1254, opaque, near-black backdrop) and the recorded derivation root.
Keep it committed so the icon set can always be regenerated from source.

- Provenance: operator-provided Rational artwork (1254x1254 PNG, opaque
  near-black backdrop carrying a full-bleed navy rounded-rect plate).
- Original artwork SHA-256:
  `e32a19bc3dc15e91717020863b8d11d2b6b50f925a07fbbe7f408160c20014ba`

## Derivation

`Scripts/generate-app-icon.py` regenerates the master and the appiconset from
the original. macOS does not mask app icons (unlike iOS), so the styled
rounded-rect plate ships with a transparent surround and the icon-grid margin
baked in:

- The near-black backdrop is keyed to alpha by flood-filling inward from the
  borders (tolerance 10) — a flood fill, not a global chroma-key, so the
  plate's own near-black navy corners are never eaten.
- The keyed plate is cropped to its alpha bounding box.
- The plate is composited at 824/1024 of a transparent 1024x1024 canvas (the
  standard macOS icon-grid margin). The rounded-rect plate is part of the
  artwork and intentionally kept.
- SHA-256 in this repository: `308b292f6a7f72af90643f87d524afe773d1f000ed293549f22c2cd92348a6f3`

All sizes in the appiconset are Lanczos downscales of this source;
`app-icon-1024.png` is a byte-identical copy of it.

`manifest.sha256` records the expected hashes for the committed original, the
generated source PNG, and the generated AppIcon PNGs. Update it only when
intentionally refreshing the artwork or regenerating the icon set.
