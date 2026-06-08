import XCTest
import AppKit
@testable import RatioThink

/// #463: the chat composer swaps `NSTextView.scrollableTextView()`'s
/// documentView for a `SubmitNSTextView` (to intercept Return). A text view
/// built with `init(frame:textContainer:)` does NOT inherit the
/// vertically-resizable geometry that `scrollableTextView()` configures — it
/// is `isVerticallyResizable == false` with `min/maxSize` clamped to the seed
/// frame height (14pt). Frozen below the ~16pt line height, the bottom of each
/// line is clipped: descenders (q/g/p/y/j) lose their tails (a "p" reads as a
/// "D") and underline/marked-text decorations are cut off.
///
/// `applyResizableTextViewGeometry(to:)` restores the contract. These tests
/// fail if the fix is removed — the bare text view is provably clamped below
/// the line height, and the corrected one is provably able to grow past it.
@MainActor
final class ComposerTextViewGeometryTests: XCTestCase {

  /// Builds a text view exactly the way `ComposerTextEditor` does: reuse the
  /// container vended by `scrollableTextView()`, seeded into a fresh
  /// `init(frame:textContainer:)` text view.
  private func makeSeededTextView() throws -> (NSTextView, NSLayoutManager, CGFloat) {
    let scroll = NSTextView.scrollableTextView()
    let seed = try XCTUnwrap(scroll.documentView as? NSTextView)
    let container = try XCTUnwrap(seed.textContainer)
    let tv = NSTextView(frame: seed.frame, textContainer: container)
    tv.font = .systemFont(ofSize: NSFont.systemFontSize)
    let lm = try XCTUnwrap(tv.layoutManager)
    let lineHeight = lm.defaultLineHeight(for: try XCTUnwrap(tv.font))
    return (tv, lm, lineHeight)
  }

  func test_bareTextView_isClampedBelowLineHeight_provingTheClip() throws {
    let (tv, _, lineHeight) = try makeSeededTextView()
    // The regression itself: without the fix the view cannot grow to a full
    // line, so the descender/underline band falls outside its bounds.
    XCTAssertFalse(tv.isVerticallyResizable,
                   "bare init(frame:textContainer:) must start non-resizable")
    XCTAssertLessThan(tv.maxSize.height, lineHeight,
                      "bare text view is frozen below the line height — this is the clip (#463)")
  }

  func test_applyResizableGeometry_letsTheViewGrowPastTheLineHeight() throws {
    let (tv, _, lineHeight) = try makeSeededTextView()

    applyResizableTextViewGeometry(to: tv)

    XCTAssertTrue(tv.isVerticallyResizable)
    XCTAssertFalse(tv.isHorizontallyResizable)
    XCTAssertGreaterThanOrEqual(tv.maxSize.height, lineHeight,
                                "corrected view must be able to contain a full line")
    XCTAssertEqual(tv.minSize.height, 0, accuracy: 0.001)
  }

  /// After the fix, laying out a real underlined descender line must fit
  /// inside the view's allowed height — i.e. the used line-fragment height
  /// (which spans ascender → descender and the underline band) is never
  /// clamped away.
  func test_descenderUnderlineLine_fitsWithinAllowedHeight() throws {
    let (tv, lm, lineHeight) = try makeSeededTextView()
    applyResizableTextViewGeometry(to: tv)
    let container = try XCTUnwrap(tv.textContainer)

    tv.string = "pqgyj"
    let full = NSRange(location: 0, length: (tv.string as NSString).length)
    tv.textStorage?.addAttribute(.underlineStyle,
                                 value: NSUnderlineStyle.single.rawValue, range: full)
    lm.ensureLayout(for: container)
    let usedHeight = lm.usedRect(for: container).height

    XCTAssertGreaterThanOrEqual(usedHeight, lineHeight,
                                "a descender line should occupy at least one full line height")
    XCTAssertGreaterThanOrEqual(tv.maxSize.height, usedHeight,
                                "the corrected view must contain the full laid-out line, descenders and underline included")
  }
}
