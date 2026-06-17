import XCTest
import SwiftUI
import AppKit

@testable import RatioThink

/// Renders the Best-of-N selection highlight (#690) in BOTH appearances via
/// `ImageRenderer` (macOS 13+; deploy target 14) so the chosen-vs-unpicked
/// emphasis can be eyeballed for light AND dark — the operator-flagged risk
/// (a hardcoded lightness would invert). The highlight is built from semantic
/// `Color.accentColor` + hierarchical styles + alpha, which adapt, so both
/// renders must read with `n1` accent-emphasized and `n0`/`n2` de-emphasized.
@MainActor
final class BestOfNHighlightSnapshotTests: XCTestCase {

  private var outDir: URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("bestofn-highlight-snapshots", isDirectory: true)
  }

  override func setUpWithError() throws {
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
  }

  func test_render_highlight_light() throws {
    try render(scheme: .light, name: "bestofn-highlight-light")
  }

  func test_render_highlight_dark() throws {
    try render(scheme: .dark, name: "bestofn-highlight-dark")
  }

  private func render(scheme: ColorScheme, name: String) throws {
    // The harness defaults to `chosenID = "n1"`, so n1 renders chosen
    // (accent-highlighted) and n0/n2 dimmed.
    let view = BestOfNHighlightPreviewHarness()
      .environment(\.colorScheme, scheme)
      .background(scheme == .dark ? Color.black : Color.white)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    let image = try XCTUnwrap(renderer.nsImage, "ImageRenderer produced no image for \(name)")
    let png = try XCTUnwrap(Self.png(from: image), "no PNG bytes for \(name)")
    let url = outDir.appendingPathComponent("\(name).png")
    try png.write(to: url)
    add(XCTAttachment(contentsOfFile: url))
    print("BESTOFN-SNAPSHOT \(name): \(url.path) (\(png.count) bytes)")
    XCTAssertGreaterThan(png.count, 1000, "\(name) PNG is implausibly small")
  }

  private static func png(from image: NSImage) -> Data? {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { return nil }
    return rep.representation(using: .png, properties: [:])
  }
}
