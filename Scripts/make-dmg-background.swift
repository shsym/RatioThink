#!/usr/bin/env swift
// Generate the RatioThink DMG drag-install background art programmatically so
// the package build is self-contained (no committed binary art, no ImageMagick
// dependency). Draws a left->right arrow between the app icon slot (left) and
// the Applications slot (right), matching the icon positions package-dmg.sh
// sets via Finder.
//
// TODO(#354): placeholder art — replace with a designed background asset when
// one exists. Keep the canvas size and the two slot centers (see SLOT_* below)
// in sync with the `osascript` icon positions in Scripts/package-dmg.sh, or the
// arrow will not line up with the icons.
//
// Usage: Scripts/make-dmg-background.swift <out.png>

import AppKit

// Canvas + slot geometry. These constants are the contract with
// package-dmg.sh: WIDTH/HEIGHT feed the Finder window bounds, and the icon
// centers sit at SLOT_APP_X / SLOT_APPS_X on the vertical center.
let WIDTH = 600
let HEIGHT = 400
let SLOT_APP_X: CGFloat = 150   // app icon center (left)
let SLOT_APPS_X: CGFloat = 450  // Applications icon center (right)
let CENTER_Y: CGFloat = 200

let args = CommandLine.arguments
guard args.count >= 2 else {
  FileHandle.standardError.write(Data("make-dmg-background.swift: usage: make-dmg-background.swift <out.png>\n".utf8))
  exit(64)
}
let outPath = args[1]

// Render into an explicit 1x bitmap so the PNG is exactly WIDTH x HEIGHT
// pixels regardless of the build host's display scale. Finder maps the
// background picture point-for-point onto the window, so the pixel size must
// equal the point geometry the icon positions assume.
guard
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: WIDTH, pixelsHigh: HEIGHT,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)
else {
  FileHandle.standardError.write(Data("make-dmg-background.swift: failed to allocate bitmap\n".utf8))
  exit(70)
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Soft neutral backdrop.
NSColor(calibratedWhite: 0.96, alpha: 1.0).setFill()
NSRect(x: 0, y: 0, width: WIDTH, height: HEIGHT).fill()

// Arrow shaft from just right of the app slot to just left of the Applications
// slot (128pt icons span ~64pt each side of centre, so stay in the gap).
let shaftStart = SLOT_APP_X + 80
let shaftEnd = SLOT_APPS_X - 92
let arrowColor = NSColor(calibratedWhite: 0.62, alpha: 1.0)
arrowColor.setStroke()
let shaft = NSBezierPath()
shaft.lineWidth = 6
shaft.lineCapStyle = .round
shaft.move(to: NSPoint(x: shaftStart, y: CENTER_Y))
shaft.line(to: NSPoint(x: shaftEnd, y: CENTER_Y))
shaft.stroke()

// Arrowhead pointing right (app -> Applications).
arrowColor.setFill()
let head = NSBezierPath()
head.move(to: NSPoint(x: shaftEnd + 16, y: CENTER_Y))
head.line(to: NSPoint(x: shaftEnd - 6, y: CENTER_Y + 14))
head.line(to: NSPoint(x: shaftEnd - 6, y: CENTER_Y - 14))
head.close()
head.fill()

// Caption above the arrow.
let caption = "Drag RatioThink to Applications" as NSString
let captionAttrs: [NSAttributedString.Key: Any] = [
  .font: NSFont.systemFont(ofSize: 15, weight: .medium),
  .foregroundColor: NSColor(calibratedWhite: 0.45, alpha: 1.0),
]
let captionSize = caption.size(withAttributes: captionAttrs)
caption.draw(
  at: NSPoint(x: (CGFloat(WIDTH) - captionSize.width) / 2, y: CENTER_Y + 46),
  withAttributes: captionAttrs)

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
  FileHandle.standardError.write(Data("make-dmg-background.swift: failed to encode PNG\n".utf8))
  exit(70)
}

do {
  try png.write(to: URL(fileURLWithPath: outPath))
} catch {
  FileHandle.standardError.write(Data("make-dmg-background.swift: write failed: \(error)\n".utf8))
  exit(71)
}
