import XCTest
import SwiftUI
import AppKit
@testable import RatioThink

/// Renders the real #421 surfaces to PNGs so the visual polish can be
/// eyeballed without a seated GUI session: the sampling popover (coarse
/// labelled ticks, NO Max-tokens row) and the engine-status pip in a
/// toolbar-like row (the `.offline` "Model not loaded" copy + the spacing
/// fix — the short label hugs the dot at the trailing edge instead of being
/// right-pushed inside a reserved 200pt slot when slack is available).
///
/// Uses `ImageRenderer` (macOS 13+; deploy target is 14) so it runs under
/// plain `xcodebuild test`, not XCUITest. These are artifact generators with
/// a light sanity assertion (non-trivial PNG), not pixel-diff gates — the
/// copy/geometry contracts are pinned in `ModelLoadIndicatorLabelTests` /
/// `SliderTickScaleTests`. PNGs land in `$TMPDIR` (or /tmp) and attach.
@MainActor
final class SamplingAndIndicatorSnapshotTests: XCTestCase {

  private var outDir: URL {
    URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rt421-snapshots", isDirectory: true)
  }

  override func setUpWithError() throws {
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
  }

  func test_render_sampling_popover() throws {
    let view = ParamsPopover(sampling: .constant(
      ChatSampling(temperature: 0.7, topP: 0.9, maxTokens: 2048)
    ))
    try render(view, name: "sampling-popover")
  }

  func test_render_offline_pip_in_toolbar_row() throws {
    try render(toolbarRow(indicator(.stopped)), name: "pip-offline")
  }

  func test_render_starting_pip_in_toolbar_row() throws {
    // `startingSince` 5 s in the past so the live counter reads "Starting… (5s)".
    let started = indicator(.starting, now: { Date().addingTimeInterval(-5) })
    try render(toolbarRow(started), name: "pip-starting")
  }

  func test_render_running_pip_in_toolbar_row() throws {
    // Running stays quiet — a bare dot, no inline copy (scope 3).
    try render(toolbarRow(indicator(.running(port: 8123, profileID: "chat"))), name: "pip-running")
  }

  // MARK: - builders

  /// A faithful slice of `ContentToolbar`'s right group: sibling icons, the
  /// greedy `Spacer`, then the pip — at a WIDE width so layout slack exists.
  /// This is exactly the condition under which the old unconditional
  /// `maxWidth: 200` label frame expanded and detached the text; with the
  /// fix the label sizes to content and the Spacer absorbs all the slack.
  private func toolbarRow(_ pip: ModelLoadIndicator) -> some View {
    HStack(spacing: 10) {
      Image(systemName: "slider.horizontal.3")
      Image(systemName: "paperclip").foregroundStyle(.secondary)
      Image(systemName: "scroll")
      Spacer(minLength: 12)
      pip
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .frame(width: 520)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private func indicator(
    _ status: EngineStatus,
    now: @escaping @Sendable () -> Date = { Date() }
  ) -> ModelLoadIndicator {
    let xpc = SnapshotStubXPC(status: status)
    let engineStatus = EngineStatusStore(client: xpc, initialStatus: status, now: now)
    let center = ModelLoadCenter()
    let lifecycle = EngineLifecycle(engineStatus: engineStatus, modelLoad: center)
    let helper = HelperHealthController(repair: { false })
    return ModelLoadIndicator(
      center: center,
      engineStatus: engineStatus,
      helperHealth: helper,
      lifecycle: lifecycle
    )
  }

  private func render(_ view: some View, name: String) throws {
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    let image = try XCTUnwrap(renderer.nsImage, "ImageRenderer produced no image for \(name)")
    let png = try XCTUnwrap(Self.png(from: image), "no PNG bytes for \(name)")
    let url = outDir.appendingPathComponent("\(name).png")
    try png.write(to: url)
    add(XCTAttachment(contentsOfFile: url))
    print("RT421-SNAPSHOT \(name): \(url.path) (\(png.count) bytes)")
    XCTAssertGreaterThan(png.count, 1000, "\(name) PNG is implausibly small")
  }

  private static func png(from image: NSImage) -> Data? {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { return nil }
    return rep.representation(using: .png, properties: [:])
  }
}

/// Minimal no-op XPC client so the snapshot can stand up the engine-status
/// graph in a fixed state without a Helper. The poll loop is never started,
/// so `engineStatus()` is never actually called — the state comes from
/// `initialStatus`.
private struct SnapshotStubXPC: AppXPCClient {
  let status: EngineStatus
  func engineStatus() async throws -> EngineStatus { status }
  func stopEngine() async throws {}
  func startEngine(profileID: String) async throws {}
}
