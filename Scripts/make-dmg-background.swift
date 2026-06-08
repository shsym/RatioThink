#!/usr/bin/env swift
// Generate the Rational DMG drag-install background art programmatically so
// the package build is self-contained (no committed binary art, no ImageMagick
// dependency). Draws a left->right arrow between the app icon slot (left) and
// the Applications slot (right).
//
// The geometry (canvas size + the two icon slot positions) is read from the
// shared geometry file passed as the second argument — the SAME file
// make-dmg-dsstore.py uses to pin the icon Iloc positions and
// verify-dmg-layout.sh uses to assert them. The arrow endpoints are derived
// from those icon positions, so editing Scripts/dmg-window.json moves both the
// icons and the arrow together (no separate copy to keep in sync). There is no
// Finder/osascript involved; the window layout is written to the .DS_Store
// directly by make-dmg-dsstore.py.
//
// TODO: replace this placeholder art with a designed background asset.
//
// Usage: make-dmg-background.swift <out.png> <geometry.json>

import AppKit

func die(_ msg: String, _ code: Int32) -> Never {
  FileHandle.standardError.write(Data("make-dmg-background.swift: \(msg)\n".utf8))
  exit(code)
}

let args = CommandLine.arguments
guard args.count >= 3 else {
  die("usage: make-dmg-background.swift <out.png> <geometry.json>", 64)
}
let outPath = args[1]
let geomPath = args[2]

// --- Read the shared geometry contract ---
guard let geomData = FileManager.default.contents(atPath: geomPath),
  let geom = try? JSONSerialization.jsonObject(with: geomData) as? [String: Any],
  let window = geom["window"] as? [String: Any],
  let width = (window["width"] as? NSNumber)?.intValue,
  let height = (window["height"] as? NSNumber)?.intValue,
  let icons = geom["icons"] as? [String: Any],
  let appIcon = icons["Rational.app"] as? [String: Any],
  let appsIcon = icons["Applications"] as? [String: Any],
  let appX = (appIcon["x"] as? NSNumber)?.doubleValue,
  let appY = (appIcon["y"] as? NSNumber)?.doubleValue,
  let appsX = (appsIcon["x"] as? NSNumber)?.doubleValue
else {
  die("could not read geometry from \(geomPath)", 65)
}

let WIDTH = width
let HEIGHT = height
// Icon positions use Finder's top-left origin; AppKit draws bottom-left, so the
// arrow's vertical row is HEIGHT - iconY. Both icons share a row (appY), so the
// arrow stays aligned even if that row moves off-center.
let centerY = CGFloat(HEIGHT) - CGFloat(appY)
let slotAppX = CGFloat(appX)
let slotAppsX = CGFloat(appsX)

// Render into an explicit 1x bitmap so the PNG is exactly WIDTH x HEIGHT pixels
// regardless of the build host's display scale. Finder maps the background
// picture point-for-point onto the window, so the pixel size must equal the
// point geometry the icon positions assume.
guard
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: WIDTH, pixelsHigh: HEIGHT,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)
else {
  die("failed to allocate bitmap", 70)
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Soft neutral backdrop.
NSColor(calibratedWhite: 0.96, alpha: 1.0).setFill()
NSRect(x: 0, y: 0, width: WIDTH, height: HEIGHT).fill()

// Arrow shaft from just right of the app slot to just left of the Applications
// slot (128pt icons span ~64pt each side of centre, so stay in the gap).
let shaftStart = slotAppX + 80
let shaftEnd = slotAppsX - 92
let arrowColor = NSColor(calibratedWhite: 0.62, alpha: 1.0)
arrowColor.setStroke()
let shaft = NSBezierPath()
shaft.lineWidth = 6
shaft.lineCapStyle = .round
shaft.move(to: NSPoint(x: shaftStart, y: centerY))
shaft.line(to: NSPoint(x: shaftEnd, y: centerY))
shaft.stroke()

// Arrowhead pointing right (app -> Applications).
arrowColor.setFill()
let head = NSBezierPath()
head.move(to: NSPoint(x: shaftEnd + 16, y: centerY))
head.line(to: NSPoint(x: shaftEnd - 6, y: centerY + 14))
head.line(to: NSPoint(x: shaftEnd - 6, y: centerY - 14))
head.close()
head.fill()

// Caption above the arrow.
let caption = "Drag Rational to Applications" as NSString
let captionAttrs: [NSAttributedString.Key: Any] = [
  .font: NSFont.systemFont(ofSize: 15, weight: .medium),
  .foregroundColor: NSColor(calibratedWhite: 0.45, alpha: 1.0),
]
let captionSize = caption.size(withAttributes: captionAttrs)
caption.draw(
  at: NSPoint(x: (CGFloat(WIDTH) - captionSize.width) / 2, y: centerY + 80),
  withAttributes: captionAttrs)

NSGraphicsContext.restoreGraphicsState()

// Guard against a blank render (e.g. headless AppKit drawing no-op): require
// more than one distinct color so an all-one-color PNG fails the build instead
// of silently shipping an empty background.
guard let pixels = rep.bitmapData else {
  die("bitmap has no pixel data", 70)
}
let spp = rep.samplesPerPixel
let bpr = rep.bytesPerRow
let (r0, g0, b0) = (pixels[0], pixels[1], pixels[2])
var distinct = false
outer: for y in 0..<rep.pixelsHigh {
  for x in 0..<rep.pixelsWide {
    let off = y * bpr + x * spp
    if pixels[off] != r0 || pixels[off + 1] != g0 || pixels[off + 2] != b0 {
      distinct = true
      break outer
    }
  }
}
if !distinct {
  die("rendered background is a single flat color (nothing drawn)", 73)
}

guard let png = rep.representation(using: .png, properties: [:]) else {
  die("failed to encode PNG", 70)
}

do {
  try png.write(to: URL(fileURLWithPath: outPath))
} catch {
  die("write failed: \(error)", 71)
}
