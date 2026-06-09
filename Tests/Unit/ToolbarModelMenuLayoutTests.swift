import XCTest
import SwiftUI
import AppKit
@testable import RatioThink

/// #462: deterministic, with-teeth guard for THIS PR's toolbar fix —
/// dropping the `Model:` menu label's `.fixedSize()` for the shared
/// `boundedModelName` cap so a long id lets the toolbar compress instead of
/// jamming its minimum width wide.
///
/// Renders the REAL `ContentToolbar` (not the modifier in isolation, so a
/// re-added `.fixedSize()` on the actual menu is caught) with a long current
/// model and measures the width SwiftUI demands under a narrow proposal via
/// `NSHostingController.sizeThatFits`. This is the reliable home for the
/// regression: the seated GUI window here runs effectively full-screen, where
/// the toolbar never has to compress, so a GUI assertion can't observe the
/// break — `S462_LongModelNameLayoutGUITests` stays a real-app smoke.
@MainActor
final class ToolbarModelMenuLayoutTests: XCTestCase {
  private let longSlug =
    "bartowski/Meta-Llama-3.1-8B-Instruct-GGUF/Meta-Llama-3.1-8B-Instruct-Q4_K_M-Imatrix-Calibrated-128k-Long-Context-Tool-Use-Fine-Tuned-Experimental-Preview-Release-Candidate.gguf"

  /// Width the real toolbar demands when offered only `proposal` points. A
  /// compressible model label lets it settle near the toolbar's small fixed
  /// chrome; a `.fixedSize()` label jams it up by the full long title.
  private func toolbarMinWidth(proposal: CGFloat) -> CGFloat {
    let summary = ToolbarModelOptions.CurrentSummary(
      slug: longSlug,
      displayName: ModelDisplayName.leaf(longSlug),
      annotation: "Profile default")
    let toolbar = ContentToolbar(
      viewModel: ChatTranscriptViewModel(),
      availableProfiles: ["chat"],
      modelOptions: [],
      currentModelSummary: summary,
      swapCoordinator: .previewDefault(),
      modelLoadCenter: nil,
      engineStatus: nil,
      helperHealth: nil,
      engineLifecycle: nil,
      onUnload: {},
      onStartEngine: {}
    )
    .environmentObject(SettingsNavigation())
    let host = NSHostingController(rootView: toolbar)
    return host.sizeThatFits(in: CGSize(width: proposal, height: 44)).width
  }

  func test_toolbar_compresses_a_long_model_label() {
    let w = toolbarMinWidth(proposal: 400)
    // Compressible: settles near the fixed chrome (profile menu + icons +
    // padding ≈ a few hundred pt). A `.fixedSize()` regression jams it up by
    // the full ~1000pt+ title. 800 cleanly separates the two.
    XCTAssertLessThan(w, 800,
      "toolbar must compress a long model label under a 400pt proposal; got \(w)pt — " +
      "a `.fixedSize()` regression on the model menu label jams the minimum width wide")
  }
}
