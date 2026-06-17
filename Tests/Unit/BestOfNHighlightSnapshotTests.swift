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

  // #708: read-only history render — chosen highlighted, others dimmed, no
  // pick affordance. Eyeball that the chosen card + dim still read in both.
  func test_render_readonly_dark() throws {
    try render(scheme: .dark, name: "bestofn-readonly-dark", interactive: false)
  }

  // #708 C probe — a chosen answer (`.primary`) above the candidate's reasoning
  // disclosure forced EXPANDED with `deEmphasized: true` (`.tertiary`). Static
  // snapshots render only the folded default; this exercises the expanded state
  // the operator saw, to confirm thinking is unmistakably dimmer than the answer.
  func test_probe_expanded_reasoning_is_subordinate() throws {
    let probe = VStack(alignment: .leading, spacing: 4) {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
          Text("Assign one owner per action item before anyone leaves.")
            .font(.caption.monospaced()).foregroundStyle(.primary)
        }
        Text("Assign one owner per action item before anyone leaves.")
          .font(.caption.monospaced()).foregroundStyle(.primary)
      }
      .padding(8)
      .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12)))
      .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1))
      ReasoningDisclosure(
        reasoning: "They want low-effort but memorable; an owner makes it stick, and a single name avoids diffusion of responsibility.",
        answerStarted: false, labelFont: .caption2, bodyFont: .caption2.monospaced(),
        deEmphasized: true)
        .padding(.leading, 8)
    }
    .padding().frame(width: 420)
    .environment(\.colorScheme, .dark).background(Color.black)
    let img = try XCTUnwrap(ImageRenderer(content: probe).nsImage)
    let png = try XCTUnwrap(Self.png(from: img))
    let url = outDir.appendingPathComponent("bestofn-thinking-tertiary.png")
    try png.write(to: url)
    print("BESTOFN-SNAPSHOT bestofn-thinking-tertiary: \(url.path)")
  }

  private func render(scheme: ColorScheme, name: String, interactive: Bool = true) throws {
    // The harness defaults to `chosenID = "n1"`, so n1 renders chosen
    // (accent-highlighted). n1 carries a reasoning trace (#708 C) so the
    // thinking-vs-answer contrast inside the chosen card is visible.
    let view = BestOfNHighlightPreviewHarness(interactive: interactive)
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
