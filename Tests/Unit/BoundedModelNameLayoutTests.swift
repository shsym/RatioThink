import XCTest
import SwiftUI
import AppKit
@testable import RatioThink

/// #462: deterministic (no XCUITest) proof that `boundedModelName` fixes the
/// long-model-name layout break headlessly, in the app-unit tier. The seated
/// `S462` GUI test proves it end-to-end in the real window; this pins the
/// SwiftUI layout contract so the regression is caught even where CI can't
/// drive a GUI.
///
/// The bug was a `.fixedSize()` model label: `.fixedSize()` makes a view
/// REFUSE to compress — it demands its full ideal width no matter how little
/// space the enclosing toolbar/menu offers — so a long GGUF leaf pushed
/// neighbouring controls past the window edge. The fix drops `.fixedSize()`
/// and caps the leaf, making the label both COMPRESSIBLE (the HStack can
/// shrink it under pressure) and bounded (it never exceeds the cap when space
/// is ample). Both properties are measured here via `NSHostingController`.
@MainActor
final class BoundedModelNameLayoutTests: XCTestCase {
  private let longSlug =
    "bartowski/Meta-Llama-3.1-8B-Instruct-GGUF/Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf"
  private let cap: CGFloat = 240

  /// Width SwiftUI needs for `view` given a definite `proposal` of horizontal
  /// space. A compressible view returns ≈ the (narrow) proposal; a
  /// `.fixedSize()` view ignores it and returns its full ideal width.
  private func neededWidth(_ view: some View, proposal: CGFloat) -> CGFloat {
    let host = NSHostingController(rootView: view)
    return host.sizeThatFits(in: CGSize(width: proposal, height: 100)).width
  }

  /// THE FIX: offered only 120pt, the bounded label accepts it (truncates)
  /// rather than demanding the full leaf — so its enclosing row can shrink it
  /// instead of overflowing the window.
  func test_boundedLeaf_compressesUnderPressure() {
    let bounded = Text(ModelDisplayName.leaf(longSlug)).boundedModelName(maxWidth: cap)
    let squeezed = neededWidth(bounded, proposal: 120)
    XCTAssertLessThanOrEqual(squeezed, 121,
      "bounded leaf must accept a narrow proposal (truncate), not demand its full width; got \(squeezed)pt")
  }

  /// THE BUG (regression sentinel): the SAME leaf under `.fixedSize()` refuses
  /// to compress — offered 120pt it still demands its full width. If a future
  /// change re-adds `.fixedSize()` to a model label, the compress test above
  /// flips; this proves the two behaviours are genuinely different.
  func test_fixedSizeLeaf_refusesToCompress() {
    let unbounded = Text(ModelDisplayName.leaf(longSlug)).fixedSize()
    let squeezed = neededWidth(unbounded, proposal: 120)
    XCTAssertGreaterThan(squeezed, 200,
      "a .fixedSize() leaf must refuse to compress (the #462 bug); got \(squeezed)pt")
  }

  /// When space is ample the bounded label still stops at the cap — never the
  /// full leaf width — so even a wide toolbar can't be widened past the cap by
  /// a long id.
  func test_boundedLeaf_capsWidthWhenSpaceIsAmple() {
    let bounded = Text(ModelDisplayName.leaf(longSlug)).boundedModelName(maxWidth: cap)
    let ample = neededWidth(bounded, proposal: 100_000)
    XCTAssertLessThanOrEqual(ample, cap + 1, "bounded leaf must cap at \(cap)pt; got \(ample)pt")

    // And the leaf genuinely exceeds the cap, so capping is a real constraint.
    let full = neededWidth(Text(ModelDisplayName.leaf(longSlug)).fixedSize(), proposal: 100_000)
    XCTAssertGreaterThan(full, cap,
      "the unbounded leaf is wider than the cap (\(full)pt) — capping is not a no-op")
  }
}
