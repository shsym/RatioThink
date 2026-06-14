# Rational app icon source

`rational-icon-highres.png` is the committed high-resolution source for
`Resources/Assets.xcassets/AppIcon.appiconset/`. It is derived from the
operator-approved Rational node-tree artwork (the same artwork the project
landing page hero uses, `docs/assets/pie-icon.png`); it is no longer the
upstream `pie-project/pie-desktop` icon.

- Provenance: operator-provided Rational artwork (1254x1254 PNG, opaque
  near-black backdrop).
- Treatment: the backdrop was keyed to alpha (flood fill from the borders,
  tolerance 10), the rounded-rect plate cropped to its alpha bounding box,
  and the plate composited at 824/1024 of a transparent 1024x1024 canvas
  (the standard macOS icon-grid margin). The rounded-rect plate is part of
  the artwork and intentionally kept.
- SHA-256 in this repository: `7f11be1a2d926e54aefd9f62e6e4357ed1065adc2ebca27f5db8dbf403cb8d66`

All sizes in the appiconset are Lanczos downscales of this source;
`app-icon-1024.png` is a byte-identical copy of it.

`manifest.sha256` records the expected hashes for the committed source PNG and
generated AppIcon PNGs. Update it only when intentionally refreshing the
artwork or regenerating the icon set.
