import XCTest
import AppKit
@testable import RatioThink

/// #446: the composer must auto-grow for SOFT-WRAPPED lines, not just hard
/// newlines. The old height counted `\n`s only, so a long line that wrapped
/// stayed one line tall and the wrapped text (descenders included) clipped.
/// These exercise the pure measurement + clamp the live editor uses, so the
/// wrap contract is guarded without a view host.
final class ComposerSizingTests: XCTestCase {

  private let width: CGFloat = 120  // narrow enough that a sentence wraps

  /// The regression: a long line with NO newlines wraps to multiple visual
  /// lines and must measure TALLER than a short single line at the same
  /// width. Hard-`\n` counting reported both as one line — the clip.
  func test_soft_wrapped_line_measures_taller_than_short_line() {
    let short = ComposerView.contentHeight(forText: "Hi", containerWidth: width)
    let wrapped = ComposerView.contentHeight(
      forText: "The capital of France is a long sentence with no newlines that wraps",
      containerWidth: width)
    XCTAssertGreaterThan(wrapped, short + 1,
                         "a soft-wrapped line must grow the box beyond one line")
    // And the visible box follows: wrapped is taller than short.
    XCTAssertGreaterThan(
      ComposerView.editorBoxHeight(forContentHeight: wrapped),
      ComposerView.editorBoxHeight(forContentHeight: short))
  }

  /// A short single line is ~one line of 13pt system body (~16pt) — not the
  /// over-reported height a 0-width pre-layout pass would give.
  func test_single_short_line_is_one_line_tall() {
    let h = ComposerView.contentHeight(forText: "Hi", containerWidth: 300)
    XCTAssertLessThanOrEqual(h, 20, "a short line must measure ~one line, got \(h)")
    XCTAssertGreaterThan(h, 0)
  }

  /// Hard newlines still grow the box (no regression to the explicit-newline
  /// path the old code handled).
  func test_hard_newlines_grow_the_box() {
    let one = ComposerView.contentHeight(forText: "a", containerWidth: 300)
    let three = ComposerView.contentHeight(forText: "a\nb\nc", containerWidth: 300)
    XCTAssertGreaterThan(three, one * 2, "three newlines must be ~3x one line")
  }

  /// A 0/empty container width falls back to the single-line floor rather
  /// than over-reporting (a width-tracking container at width 0 wraps every
  /// glyph).
  func test_zero_width_falls_back_to_floor() {
    XCTAssertEqual(ComposerView.contentHeight(forText: "anything", containerWidth: 0), 18)
  }

  // MARK: - editorHeight composition (the wiring the first cut of #446 missed)

  /// The composition the live view uses: draft + live width → box height. A
  /// soft-wrapping draft at a real width must yield a TALLER box than a short
  /// draft at the same width. (The first fix derived height from the NSTextView
  /// at a not-yet-valid width and stayed one line — caught only here, not by
  /// the static measure tests above.)
  func test_editorHeight_grows_for_wrapping_draft_at_real_width() {
    let short = ComposerView.editorHeight(forDraft: "Hi", editorWidth: width)
    let wrapped = ComposerView.editorHeight(
      forDraft: "The capital of France is a long sentence with no newlines that wraps",
      editorWidth: width)
    XCTAssertEqual(short, 18, "a short draft is one line")
    XCTAssertGreaterThan(wrapped, short + 8, "a soft-wrapped draft must grow the box")
  }

  /// Before the editor width is measured (0), fall back to the one-line floor
  /// rather than a 0-width over-report.
  func test_editorHeight_floors_before_width_known() {
    XCTAssertEqual(ComposerView.editorHeight(forDraft: "anything wrapping long", editorWidth: 0), 18)
  }

  // MARK: - editorBoxHeight clamp

  func test_editorBoxHeight_floors_at_one_line() {
    // Below the single-line floor (e.g. empty/measured-0) → 18pt box.
    XCTAssertEqual(ComposerView.editorBoxHeight(forContentHeight: 0), 18)
    XCTAssertEqual(ComposerView.editorBoxHeight(forContentHeight: 10), 18)
  }

  func test_editorBoxHeight_caps_at_eight_lines() {
    // Past the 8-line ceiling the editor scrolls internally; the box caps.
    XCTAssertEqual(ComposerView.editorBoxHeight(forContentHeight: 10_000), 18 * 8)
  }

  func test_editorBoxHeight_passes_through_in_range() {
    XCTAssertEqual(ComposerView.editorBoxHeight(forContentHeight: 50), 50)
  }
}
