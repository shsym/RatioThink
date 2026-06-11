import AppKit

/// Renders the Rational brand mark — a rounded, downward-pointing
/// triangle (the app-icon glyph, see `Resources/AppIcon/`) — as a
/// menu-bar status image (#424).
///
/// Status is carried by native menu-bar glyph treatment rather than a
/// colored LED/status-dot language:
///   · `filled`     — solid mark (engine present: running/error) vs a
///                    thick rounded OUTLINE (idle/working: stopped/loading).
///   · `errorBadge` — an exclamation knocked OUT of the solid mark, so
///                    `.error` reads as the universal warning sign and
///                    is distinguishable from `.running` without color.
///
/// The live status-item image is a TEMPLATE image. macOS supplies the
/// foreground color for the current menu-bar appearance, so `.running`
/// remains the same native monochrome glyph family as `.stopped` and
/// `.loading`; fill/motion/badge carry state, and the menu remains the
/// detailed status surface.
///
/// Deliberately self-contained (only AppKit/CoreGraphics, no Helper
/// state) so the EXACT same drawing code can be compiled by
/// `Scripts/render-menubar-icon.swift` for visual verification — there is
/// no separate preview implementation to drift from production. The
/// menu-bar `NSStatusItem` image itself is not XCUITest-assertable (the
/// sandboxed UI-test runner cannot read the status button's pixels), so
/// the render harness + the pure `HelperStatusItemModel.Dot` contract are
/// the authoritative coverage.
enum MenuBarBrandIcon {

  /// Build the status-button image for one `Dot` rendering.
  ///
  /// - Parameters:
  ///   - filled: solid mark vs rounded outline.
  ///   - errorBadge: knock an exclamation out of the (solid) mark.
  ///   - pointSize: square edge in points. ~18 matches the macOS menu-bar
  ///     icon area; the image is resolution-independent (the drawing
  ///     handler re-runs per backing scale).
  static func image(filled: Bool,
                    errorBadge: Bool,
                    pointSize: CGFloat = 18) -> NSImage {
    let img = image(filled: filled,
                    errorBadge: errorBadge,
                    color: .black,
                    pointSize: pointSize)
    img.isTemplate = true
    return img
  }

  /// Build a non-template preview image with an explicit color. This is
  /// intentionally kept out of `HelperMain`: production status items use
  /// `image(filled:errorBadge:pointSize:)` so macOS owns the menu-bar
  /// foreground color. The render harness uses this to simulate light/dark
  /// template tinting in a PNG grid without an `NSStatusBarButton`.
  static func previewImage(filled: Bool,
                           errorBadge: Bool,
                           color: NSColor,
                           pointSize: CGFloat = 18) -> NSImage {
    image(filled: filled,
          errorBadge: errorBadge,
          color: color,
          pointSize: pointSize)
  }

  private static func image(filled: Bool,
                            errorBadge: Bool,
                            color: NSColor,
                            pointSize: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: pointSize, height: pointSize),
                      flipped: false) { rect in
      draw(in: rect, filled: filled, errorBadge: errorBadge, color: color)
      return true
    }
    img.isTemplate = false
    return img
  }

  /// Draw the brand triangle into `rect`. Factored out so both the
  /// `NSImage` drawing handler and any host (preview harness) share one
  /// routine.
  static func draw(in rect: NSRect,
                   filled: Bool,
                   errorBadge: Bool,
                   color: NSColor) {
    // A thick rounded stroke IS the brand outline; size everything
    // relative to the icon so it scales with `pointSize`. Inset by half
    // the stroke (plus a hair) so the thick outline never clips at the
    // image edge.
    let edge = min(rect.width, rect.height)
    let stroke = edge * 0.10
    // Gentle corner rounding that keeps the edges long + straight (the
    // brand mark). The apex's narrow ~53° angle amplifies the tangent
    // cutback, so a small radius is plenty — larger reads as a blob.
    let cornerRadius = edge * 0.085
    let inset = stroke / 2 + edge * 0.05
    let r = rect.insetBy(dx: inset, dy: inset)

    // Down-pointing triangle: two top corners + a bottom-center apex.
    // Non-flipped coordinates (origin bottom-left), so maxY is the top.
    let topLeft = NSPoint(x: r.minX, y: r.maxY)
    let topRight = NSPoint(x: r.maxX, y: r.maxY)
    let apex = NSPoint(x: r.midX, y: r.minY)
    let triangle = roundedTriangle(topLeft, topRight, apex, radius: cornerRadius)

    color.setFill()
    color.setStroke()
    if filled {
      // The rounded path's own corners give the solid silhouette its
      // brand curvature — no extra stroke needed.
      triangle.fill()
      if errorBadge {
        knockOutExclamation(in: r)
      }
    } else {
      // Thick rounded stroke = the brand outline.
      triangle.lineWidth = stroke
      triangle.lineJoinStyle = .round
      triangle.lineCapStyle = .round
      triangle.stroke()
    }
  }

  /// A triangle through `a`, `b`, `c` with all three corners rounded to
  /// `radius`, via tangent arcs. Starting mid-edge (not on a corner) so
  /// the first arc is well-defined.
  private static func roundedTriangle(_ a: NSPoint,
                                      _ b: NSPoint,
                                      _ c: NSPoint,
                                      radius: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    let startAB = NSPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    path.move(to: startAB)
    path.appendArc(from: b, to: c, radius: radius)   // round corner b
    path.appendArc(from: c, to: a, radius: radius)   // round corner c (apex)
    path.appendArc(from: a, to: b, radius: radius)   // round corner a
    path.close()
    return path
  }

  /// Carve an exclamation mark out of the solid triangle using
  /// `.destinationOut` compositing, so the menu-bar background shows
  /// through the "!" regardless of the bar's color. Centered on the
  /// triangle's visual centroid (one third down from the top edge for a
  /// down-pointing triangle), with proportions tuned to stay legible at
  /// ~18 pt.
  private static func knockOutExclamation(in r: NSRect) {
    let cx = r.midX
    let cy = r.maxY - r.height / 3      // centroid of a down triangle

    let glyphH = r.height * 0.40        // total "!" height
    let barW = r.width * 0.11
    let gap = glyphH * 0.12
    let dotD = barW
    let barH = glyphH - gap - dotD

    let top = cy + glyphH / 2
    let barRect = NSRect(x: cx - barW / 2, y: top - barH, width: barW, height: barH)
    let dotRect = NSRect(x: cx - dotD / 2, y: top - glyphH, width: dotD, height: dotD)

    guard let ctx = NSGraphicsContext.current else { return }
    ctx.saveGraphicsState()
    ctx.compositingOperation = .destinationOut
    // destinationOut keys on the SOURCE alpha, so any opaque color erases.
    NSColor.black.setFill()
    NSBezierPath(roundedRect: barRect, xRadius: barW / 2, yRadius: barW / 2).fill()
    NSBezierPath(ovalIn: dotRect).fill()
    ctx.restoreGraphicsState()
  }
}
