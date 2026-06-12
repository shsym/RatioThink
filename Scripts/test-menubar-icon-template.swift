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
    }

    if let stopped = stats["stopped"],
       let loading = stats["loading"],
       let running = stats["running"],
       let error = stats["error"] {
      let maxOutlineCoverage = max(stopped.alphaCoverage, loading.alphaCoverage)
      if running.alphaCoverage <= maxOutlineCoverage * 1.35 {
        failures.append(
          "running filled coverage \(running.alphaCoverage) must exceed outline coverage \(maxOutlineCoverage) by at least 35%"
        )
      }
      if error.alphaCoverage <= maxOutlineCoverage * 1.25 {
        failures.append(
          "error filled coverage \(error.alphaCoverage) must exceed outline coverage \(maxOutlineCoverage) by at least 25% despite badge knockout"
        )
      }

      let knockoutCoverage = running.alphaCoverage - error.alphaCoverage
      if knockoutCoverage < 25 {
        failures.append(
          "error badge knockout too small: running=\(running.alphaCoverage), error=\(error.alphaCoverage), delta=\(knockoutCoverage)"
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

  private static func rasterize(_ image: NSImage, pixels: Int) -> RasterStats {
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
}
