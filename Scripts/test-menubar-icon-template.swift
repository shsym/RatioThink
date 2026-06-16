// Verifies the helper menu-bar status glyph follows native macOS
// status-item template semantics instead of colored LED/status-dot semantics.
// Compiled with Helper/MenuBarBrandIcon.swift so it exercises the production
// renderer, not a duplicate preview implementation.

import AppKit
import Foundation

struct RasterStats {
  let litPixels: Int
  let alphaCoverage: Double
}

struct RegionStats {
  let transparentPixels: Int
  let averageAlpha: Double
}

struct TriangleHoleStats {
  let centerAlpha: Double
  let lowerBodyAlpha: Double
  let sideRingAlpha: Double
  let apexAlpha: Double
}

@main
struct MenuBarIconTemplateTest {
  static func main() {
    let states: [(name: String, filled: Bool, errorBadge: Bool)] = [
      ("stopped", false, false),
      ("loading", false, false),
      ("running", true, false),
      ("error", true, true),
    ]

    var failures: [String] = []
    var stats: [String: RasterStats] = [:]

    for state in states {
      let image = MenuBarBrandIcon.image(filled: state.filled,
                                         errorBadge: state.errorBadge,
                                         pointSize: 18)
      if !image.isTemplate {
        failures.append("\(state.name) image is not a template image")
      }
      if image.size != NSSize(width: 18, height: 18) {
        failures.append("\(state.name) image size was \(image.size), expected 18x18")
      }

      let largeImage = MenuBarBrandIcon.image(filled: state.filled,
                                              errorBadge: state.errorBadge,
                                              pointSize: 96)
      let raster = rasterize(largeImage, pixels: 96)
      stats[state.name] = raster
      if raster.alphaCoverage <= 1 {
        failures.append("\(state.name) alpha mask is empty: coverage=\(raster.alphaCoverage)")
      }

      // The down-triangle's mass must sit vertically centered in the
      // canvas. Before the centroid shift the ink rode ~14% high; assert the
      // alpha-weighted centroid is within 7% of the image center (the fix
      // lands it at ~3%). A regression in either direction — drifting back up
      // or over-shooting and clipping the apex low — trips this.
      let offset = verticalCentroidOffsetFraction(largeImage, pixels: 96)
      if abs(offset) > 0.07 {
        failures.append(String(format: "%@ ink centroid must be vertically centered: offset=%+.1f%% (limit ±7%%)",
                               state.name, offset * 100))
      }

      if state.name == "running" {
        let largeCenter = centerKnockoutStats(largeImage, pixels: 96, radius: 7)
        if largeCenter.averageAlpha >= 0.35 || largeCenter.transparentPixels < 50 {
          failures.append(
            "running center must be visibly knocked out at preview size: avgAlpha=\(largeCenter.averageAlpha), transparentPixels=\(largeCenter.transparentPixels)"
          )
        }
        let largeTriangle = runningTriangleHoleStats(largeImage, pixels: 96)
        if largeTriangle.centerAlpha >= 0.15 {
          failures.append("running triangle hole center must be transparent at preview size: alpha=\(largeTriangle.centerAlpha)")
        }
        if largeTriangle.lowerBodyAlpha <= 0.60 {
          failures.append("running hole must point DOWN — solid body below the hole apex at preview size: alpha=\(largeTriangle.lowerBodyAlpha)")
        }
        if largeTriangle.sideRingAlpha <= 0.60 {
          failures.append("running hollow must be triangular, not circular, at preview size: side ring alpha=\(largeTriangle.sideRingAlpha)")
        }
        if largeTriangle.apexAlpha >= 0.30 {
          failures.append("running hollow triangle apex must be transparent at preview size: alpha=\(largeTriangle.apexAlpha)")
        }

        let nativeCenter = centerKnockoutStats(image, pixels: 18, radius: 2)
        if nativeCenter.averageAlpha >= 0.75 || nativeCenter.transparentPixels < 3 {
          failures.append(
            "running center must remain hollow at native menu-bar size: avgAlpha=\(nativeCenter.averageAlpha), transparentPixels=\(nativeCenter.transparentPixels)"
          )
        }
        let nativeTriangle = runningTriangleHoleStats(image, pixels: 18)
        if nativeTriangle.centerAlpha >= 0.35 {
          failures.append("running triangle hole center must be transparent at native size: alpha=\(nativeTriangle.centerAlpha)")
        }
        if nativeTriangle.lowerBodyAlpha <= 0.60 {
          failures.append("running hole must point DOWN — solid body below the hole apex at native size: alpha=\(nativeTriangle.lowerBodyAlpha)")
        }
        if nativeTriangle.sideRingAlpha <= 0.35 {
          failures.append("running hollow must stay triangular, not circular, at native size: side ring alpha=\(nativeTriangle.sideRingAlpha)")
        }
        if nativeTriangle.apexAlpha >= 0.90 {
          failures.append("running hollow triangle apex must remain transparent at native size: alpha=\(nativeTriangle.apexAlpha)")
        }
      }

      if state.name == "error" {
        let badge = errorBadgeKnockoutStats(largeImage, pixels: 96, radius: 5)
        if badge.averageAlpha >= 0.60 || badge.transparentPixels < 20 {
          failures.append(
            "error badge knockout must remain visible: avgAlpha=\(badge.averageAlpha), transparentPixels=\(badge.transparentPixels)"
          )
        }
      }
    }

    if let stopped = stats["stopped"],
       let loading = stats["loading"],
       let running = stats["running"],
       let error = stats["error"] {
      let maxOutlineCoverage = max(stopped.alphaCoverage, loading.alphaCoverage)
      if running.alphaCoverage <= maxOutlineCoverage * 1.10 {
        failures.append(
          "running filled-ring coverage \(running.alphaCoverage) must exceed outline coverage \(maxOutlineCoverage) by at least 10%"
        )
      }
      if error.alphaCoverage <= maxOutlineCoverage * 1.25 {
        failures.append(
          "error filled coverage \(error.alphaCoverage) must exceed outline coverage \(maxOutlineCoverage) by at least 25% despite badge knockout"
        )
      }
    } else {
      failures.append("missing raster stats for one or more states")
    }

    if !failures.isEmpty {
      fputs(failures.joined(separator: "\n") + "\n", stderr)
      exit(1)
    }

    let summary = states.compactMap { state -> String? in
      guard let stat = stats[state.name] else { return nil }
      return "\(state.name):lit=\(stat.litPixels),alpha=\(String(format: "%.1f", stat.alphaCoverage))"
    }.joined(separator: " ")
    print("menu-bar icon template contract passed (\(states.count) states; \(summary))")
  }

  /// Alpha-weighted vertical centroid offset from the image center, as a
  /// fraction of the edge. Positive = centroid sits ABOVE center (the
  /// off-center failure mode), negative = below.
  private static func verticalCentroidOffsetFraction(_ image: NSImage, pixels: Int) -> Double {
    let rep = bitmapRep(for: image, pixels: pixels)
    var sumA = 0.0, sumRow = 0.0
    for y in 0..<pixels {
      for x in 0..<pixels {
        guard let color = rep.colorAt(x: x, y: y) else { continue }
        let a = Double(color.alphaComponent)
        if a > 0.01 { sumA += a; sumRow += a * Double(y) }
      }
    }
    guard sumA > 0 else { return 0 }
    let centerRow = Double(pixels) / 2.0
    // colorAt rows count from the TOP, so a small row index = high on screen.
    return (centerRow - sumRow / sumA) / Double(pixels)
  }

  private static func rasterize(_ image: NSImage, pixels: Int) -> RasterStats {
    let rep = bitmapRep(for: image, pixels: pixels)
    var litPixels = 0
    var alphaCoverage = 0.0
    for y in 0..<pixels {
      for x in 0..<pixels {
        guard let color = rep.colorAt(x: x, y: y) else { continue }
        let alpha = color.alphaComponent
        if alpha > 0.01 { litPixels += 1 }
        alphaCoverage += alpha
      }
    }
    return RasterStats(litPixels: litPixels, alphaCoverage: alphaCoverage)
  }

  private static func centerKnockoutStats(_ image: NSImage, pixels: Int, radius: Int) -> RegionStats {
    let rep = bitmapRep(for: image, pixels: pixels)
    let metrics = drawingMetrics(pixels: pixels)
    return regionStats(rep: rep,
                       pixels: pixels,
                       center: bitmapPoint(x: metrics.cx, drawingY: metrics.centroidY, pixels: pixels),
                       radius: radius)
  }

  private static func runningTriangleHoleStats(_ image: NSImage, pixels: Int) -> TriangleHoleStats {
    let rep = bitmapRep(for: image, pixels: pixels)
    let metrics = drawingMetrics(pixels: pixels)
    let edge = Double(pixels)
    let inset = edge * 0.10                 // stroke/2 + edge*0.05, mirrors draw()
    let innerHeight = edge - 2 * inset

    let sideDx = max(2, Int((edge * 0.105).rounded()))
    // The knockout is a down-triangle scaled 0.36 about the centroid, so its
    // own apex sits 0.24*innerHeight below the centroid. Sample halfway to it
    // so the probe stays inside the hole at both render sizes.
    let apexDy = max(2, Int((innerHeight * 0.12).rounded()))
    return triangleHoleStats(rep: rep,
                             pixels: pixels,
                             cx: metrics.cx,
                             centroidY: metrics.centroidY,
                             lowerBodyY: metrics.lowerBodyY,
                             sideDx: sideDx,
                             apexDy: apexDy)
  }

  private static func triangleHoleStats(rep: NSBitmapImageRep,
                                        pixels: Int,
                                        cx: Int,
                                        centroidY: Int,
                                        lowerBodyY: Int,
                                        sideDx: Int,
                                        apexDy: Int) -> TriangleHoleStats {
    let sideAlphas = [
      alpha(atDrawingX: cx - sideDx, drawingY: centroidY, rep: rep, pixels: pixels),
      alpha(atDrawingX: cx + sideDx, drawingY: centroidY, rep: rep, pixels: pixels),
    ]
    return TriangleHoleStats(
      centerAlpha: alpha(atDrawingX: cx, drawingY: centroidY, rep: rep, pixels: pixels),
      lowerBodyAlpha: alpha(atDrawingX: cx, drawingY: lowerBodyY, rep: rep, pixels: pixels),
      sideRingAlpha: sideAlphas.reduce(0, +) / Double(sideAlphas.count),
      apexAlpha: alpha(atDrawingX: cx, drawingY: centroidY - apexDy, rep: rep, pixels: pixels)
    )
  }

  // MenuBarBrandIcon drops the whole triangle by edge * 0.10 so its area
  // centroid moves back toward the image center. Mirror that shift
  // here so the knockout samplers track the actual centroid instead of where
  // it used to sit; keep it in lockstep with the production constant in draw().
  static let centroidShiftFraction = 0.10

  private static func drawingMetrics(pixels: Int) -> (cx: Int, centroidY: Int, lowerBodyY: Int) {
    let edge = Double(pixels)
    let stroke = edge * 0.10
    let inset = stroke / 2 + edge * 0.05
    let innerHeight = edge - 2 * inset
    let cx = Int((edge / 2).rounded())
    let centroidYDouble = (edge - inset) - innerHeight / 3 - edge * centroidShiftFraction
    let centroidY = Int(centroidYDouble.rounded())
    // A row below the hole's apex (which sits 0.24*innerHeight under the
    // centroid): solid for a DOWN-pointing triangle, hollow for an inverted
    // one — so it guards the mark's orientation now that the hole is centered.
    let lowerBodyY = Int((centroidYDouble - innerHeight * 0.34).rounded())
    return (cx, centroidY, lowerBodyY)
  }

  private static func errorBadgeKnockoutStats(_ image: NSImage, pixels: Int, radius: Int) -> RegionStats {
    let rep = bitmapRep(for: image, pixels: pixels)
    let edge = Double(pixels)
    let stroke = edge * 0.10
    let inset = stroke / 2 + edge * 0.05
    let innerHeight = edge - 2 * inset
    let cx = Int((edge / 2).rounded())
    let centroidY = (edge - inset) - innerHeight / 3 - edge * centroidShiftFraction  // centroid shift
    // Sample the exclamation bar, above the triangle centroid. Its dot is
    // intentionally smaller, so the bar gives the most stable mask signal.
    let barY = Int((centroidY + innerHeight * 0.10).rounded())
    let flippedBarY = pixels - 1 - barY
    return minAlphaRegionStats(rep: rep, pixels: pixels, centers: [(cx, barY), (cx, flippedBarY)], radius: radius)
  }

  private static func minAlphaRegionStats(rep: NSBitmapImageRep,
                                          pixels: Int,
                                          centers: [(Int, Int)],
                                          radius: Int) -> RegionStats {
    var best: RegionStats?
    for (cx, cy) in centers {
      var transparentPixels = 0
      var alphaTotal = 0.0
      var count = 0
      for y in max(0, cy - radius)...min(pixels - 1, cy + radius) {
        for x in max(0, cx - radius)...min(pixels - 1, cx + radius) {
          guard let color = rep.colorAt(x: x, y: y) else { continue }
          let alpha = color.alphaComponent
          if alpha < 0.10 { transparentPixels += 1 }
          alphaTotal += alpha
          count += 1
        }
      }
      let stat = RegionStats(
        transparentPixels: transparentPixels,
        averageAlpha: count == 0 ? 1 : alphaTotal / Double(count)
      )
      if best == nil || stat.averageAlpha < best!.averageAlpha {
        best = stat
      }
    }
    return best ?? RegionStats(transparentPixels: 0, averageAlpha: 1)
  }

  private static func regionStats(rep: NSBitmapImageRep,
                                  pixels: Int,
                                  center: (Int, Int),
                                  radius: Int) -> RegionStats {
    let (cx, cy) = center
    var transparentPixels = 0
    var alphaTotal = 0.0
    var count = 0
    for y in max(0, cy - radius)...min(pixels - 1, cy + radius) {
      for x in max(0, cx - radius)...min(pixels - 1, cx + radius) {
        guard let color = rep.colorAt(x: x, y: y) else { continue }
        let alpha = color.alphaComponent
        if alpha < 0.10 { transparentPixels += 1 }
        alphaTotal += alpha
        count += 1
      }
    }
    return RegionStats(
      transparentPixels: transparentPixels,
      averageAlpha: count == 0 ? 1 : alphaTotal / Double(count)
    )
  }

  private static func alpha(atDrawingX x: Int, drawingY: Int, rep: NSBitmapImageRep, pixels: Int) -> Double {
    let (_, y) = bitmapPoint(x: x, drawingY: drawingY, pixels: pixels)
    return alpha(atX: x, y: y, rep: rep, pixels: pixels)
  }

  private static func bitmapPoint(x: Int, drawingY: Int, pixels: Int) -> (Int, Int) {
    // MenuBarBrandIcon draws in non-flipped AppKit coordinates (origin at the
    // bottom-left). NSBitmapImageRep.colorAt reads rows from the top edge, so
    // convert once here instead of accepting whichever vertical mirror happens
    // to look more transparent.
    (x, pixels - 1 - drawingY)
  }

  private static func alpha(atX x: Int, y: Int, rep: NSBitmapImageRep, pixels: Int) -> Double {
    guard x >= 0, x < pixels, y >= 0, y < pixels,
          let color = rep.colorAt(x: x, y: y) else { return 1 }
    return color.alphaComponent
  }

  private static func bitmapRep(for image: NSImage, pixels: Int) -> NSBitmapImageRep {
    guard let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: pixels,
      pixelsHigh: pixels,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: rep) else {
      fputs("failed to allocate bitmap context\n", stderr)
      exit(1)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
               from: .zero,
               operation: .sourceOver,
               fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep
  }
}
