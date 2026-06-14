import XCTest
import AppKit
@testable import RatioThink

/// #463: the chat composer swaps `NSTextView.scrollableTextView()`'s
/// documentView for a `SubmitNSTextView` (to intercept Return). A text view
/// built with `init(frame:textContainer:)` does NOT inherit the
/// vertically-resizable geometry that `scrollableTextView()` configures — it
/// is `isVerticallyResizable == false` with `min/maxSize` clamped to the seed
/// frame height (measured ~14pt). Frozen below the ~16pt line height, the
/// bottom of each line is clipped: descenders (q/g/p/y/j) lose their tails (a
/// "p" reads as a "D") and underline/marked-text decorations are cut off.
///
/// These tests install a real `SubmitNSTextView` as the scroll view's
/// documentView — the same seam production uses — and assert the laid-out
/// line via `sizeToFit()` against the view's actual frame, so the positive
/// check is falsifiable: remove `applyResizableTextViewGeometry(to:)` and the
/// corrected view can no longer grow to contain a full descender line.
@MainActor
final class ComposerTextViewGeometryTests: XCTestCase {

  /// Mirrors the geometry-relevant part of
  /// `ComposerTextEditor.installSubmitTextView`: a `SubmitNSTextView` built
  /// from the container `scrollableTextView()` vends, installed as the scroll
  /// view's documentView. The view stays 0-width (the seed frame is 0-width and
  /// documentView assignment keeps it so), and a 0-width `widthTracksTextView`
  /// container does not wrap, so a short word lays out on a single line.
  /// Returns the seed frame height the bare view is clamped to, and the font's
  /// line height.
  private func makeInstalledSubmitTextView() throws -> (NSTextView, CGFloat, CGFloat) {
    let scroll = NSTextView.scrollableTextView()
    let seed = try XCTUnwrap(scroll.documentView as? NSTextView)
    let container = try XCTUnwrap(seed.textContainer)
    let seedHeight = seed.frame.height

    let custom = SubmitNSTextView(frame: seed.frame, textContainer: container)
    custom.font = .systemFont(ofSize: NSFont.systemFontSize)
    scroll.documentView = custom

    let lm = try XCTUnwrap(custom.layoutManager)
    let lineHeight = lm.defaultLineHeight(for: try XCTUnwrap(custom.font))
    return (custom, seedHeight, lineHeight)
  }

  /// Lays out an underlined descender line and returns its used height. Asserts
  /// the premises the frame differential rests on, so the guard can never pass
  /// for the wrong reason — the used height is exactly one full line:
  ///   · `>= lineHeight` rules out a collapsed/degenerate layout (and, since
  ///     lineHeight ~16pt > seedHeight ~14pt, transitively anchors
  ///     `usedHeight > seedHeight`, the premise behind the negative control).
  ///   · `< 2 * lineHeight` rules out a wrapped/degenerate layout. The line is
  ///     single because the 0-width `widthTracksTextView` container does not
  ///     wrap (`container.size.width` stays 0), so non-degeneracy is asserted
  ///     via the line count, not `container.size.width`.
  private func layOutDescenderLine(_ tv: NSTextView, lineHeight: CGFloat) throws -> CGFloat {
    tv.string = "pqgyj"
    let full = NSRange(location: 0, length: (tv.string as NSString).length)
    tv.textStorage?.addAttribute(.underlineStyle,
                                 value: NSUnderlineStyle.single.rawValue, range: full)
    let lm = try XCTUnwrap(tv.layoutManager)
    let container = try XCTUnwrap(tv.textContainer)
    lm.ensureLayout(for: container)

    let usedHeight = lm.usedRect(for: container).height
    XCTAssertGreaterThanOrEqual(usedHeight, lineHeight,
                                "premise: the laid-out line must span a full line height")
    XCTAssertLessThan(usedHeight, 2 * lineHeight,
                      "premise: the descender word lays out as a single line, not a degenerate 0-width wrap")
    return usedHeight
  }

  /// Negative control: without the geometry fix the installed view is frozen
  /// at its seed height and cannot grow to contain a full line — the clip.
  func test_installedTextView_withoutGeometryFix_isFrozenAndClipsTheLine() throws {
    let (tv, seedHeight, lineHeight) = try makeInstalledSubmitTextView()

    // Robust invariant: the swapped view starts non-resizable, with its max
    // height pinned to the seed frame (not the content) — independent of the
    // exact seed value AppKit happens to vend.
    XCTAssertFalse(tv.isVerticallyResizable)
    XCTAssertEqual(tv.maxSize.height, seedHeight, accuracy: 0.001,
                   "bare view's max height is clamped to the seed frame, not the content")

    let usedHeight = try layOutDescenderLine(tv, lineHeight: lineHeight)
    tv.sizeToFit()
    XCTAssertLessThan(tv.frame.height, usedHeight,
                      "frozen view cannot grow to contain a full descender+underline line — the clip (#463)")
  }

  /// Positive, falsifiable guard: after the fix the installed view grows to
  /// contain the full laid-out descender+underline line. Fails if
  /// `applyResizableTextViewGeometry(to:)` is removed (the view stays frozen
  /// at the seed height, below the line height).
  func test_installedTextView_withGeometryFix_growsToContainDescenderLine() throws {
    let (tv, _, lineHeight) = try makeInstalledSubmitTextView()

    applyResizableTextViewGeometry(to: tv)
    XCTAssertTrue(tv.isVerticallyResizable)
    XCTAssertFalse(tv.isHorizontallyResizable)

    let usedHeight = try layOutDescenderLine(tv, lineHeight: lineHeight)
    tv.sizeToFit()
    XCTAssertGreaterThanOrEqual(tv.frame.height, usedHeight,
                                "corrected view must grow to contain the full descender+underline line")
  }
}
