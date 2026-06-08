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
  /// view's documentView. A realistic width is set so a short word lays out as
  /// a single line (the seed frame is 0-width). Returns the seed frame height
  /// the bare view is clamped to, and the font's line height.
  private func makeInstalledSubmitTextView() throws -> (NSTextView, CGFloat, CGFloat) {
    let scroll = NSTextView.scrollableTextView()
    let seed = try XCTUnwrap(scroll.documentView as? NSTextView)
    let container = try XCTUnwrap(seed.textContainer)
    let seedHeight = seed.frame.height

    let custom = SubmitNSTextView(frame: seed.frame, textContainer: container)
    custom.font = .systemFont(ofSize: NSFont.systemFontSize)
    custom.frame = NSRect(x: 0, y: 0, width: 300, height: seedHeight)
    scroll.documentView = custom

    let lm = try XCTUnwrap(custom.layoutManager)
    let lineHeight = lm.defaultLineHeight(for: try XCTUnwrap(custom.font))
    return (custom, seedHeight, lineHeight)
  }

  /// Lays out an underlined descender line and returns its used height.
  private func layOutDescenderLine(_ tv: NSTextView) throws -> CGFloat {
    tv.string = "pqgyj"
    let full = NSRange(location: 0, length: (tv.string as NSString).length)
    tv.textStorage?.addAttribute(.underlineStyle,
                                 value: NSUnderlineStyle.single.rawValue, range: full)
    let lm = try XCTUnwrap(tv.layoutManager)
    let container = try XCTUnwrap(tv.textContainer)
    lm.ensureLayout(for: container)
    return lm.usedRect(for: container).height
  }

  /// Negative control: without the geometry fix the installed view is frozen
  /// at its seed height and cannot grow to contain a full line — the clip.
  func test_installedTextView_withoutGeometryFix_isFrozenAndClipsTheLine() throws {
    let (tv, seedHeight, _) = try makeInstalledSubmitTextView()

    // Robust invariant: the swapped view starts non-resizable, with its max
    // height pinned to the seed frame (not the content) — independent of the
    // exact seed value AppKit happens to vend.
    XCTAssertFalse(tv.isVerticallyResizable)
    XCTAssertEqual(tv.maxSize.height, seedHeight, accuracy: 0.001,
                   "bare view's max height is clamped to the seed frame, not the content")

    let usedHeight = try layOutDescenderLine(tv)
    tv.sizeToFit()
    XCTAssertLessThan(tv.frame.height, usedHeight,
                      "frozen view cannot grow to contain a full descender+underline line — the clip (#463)")
  }

  /// Positive, falsifiable guard: after the fix the installed view grows to
  /// contain the full laid-out descender+underline line. Fails if
  /// `applyResizableTextViewGeometry(to:)` is removed (the view stays frozen
  /// at the seed height, below the line height).
  func test_installedTextView_withGeometryFix_growsToContainDescenderLine() throws {
    let (tv, _, _) = try makeInstalledSubmitTextView()

    applyResizableTextViewGeometry(to: tv)
    XCTAssertTrue(tv.isVerticallyResizable)
    XCTAssertFalse(tv.isHorizontallyResizable)

    let usedHeight = try layOutDescenderLine(tv)
    tv.sizeToFit()
    XCTAssertGreaterThanOrEqual(tv.frame.height, usedHeight,
                                "corrected view must grow to contain the full descender+underline line")
  }
}
