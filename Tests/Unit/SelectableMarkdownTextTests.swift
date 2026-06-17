import AppKit
import XCTest
@testable import RatioThink

/// #158 / #636 — the message body now renders into a SINGLE selectable
/// `NSAttributedString` (`MarkdownAttributedString.build`) so a drag selection
/// spans every paragraph. These tests pin the rendering contract that makes
/// that possible and preserve the link/image security MarkdownUI used to own:
///   · one contiguous string across all blocks (one selection scope),
///   · links activate only for allowlisted schemes,
///   · code renders monospaced with the prior shaded background,
///   · the per-role foreground color is honored,
///   · images never become a fetchable attachment,
///   · the height measurement obeys the wrap contract.
final class SelectableMarkdownTextTests: XCTestCase {

  /// The exact multi-section shape MarkdownUI split into separate selectable
  /// blocks — now rendered into one selectable surface.
  private let multiSection = """
    Intro paragraph.

    - item one
    - item two

    ```swift
    let x = 1 < 2
    ```

    Inline `code` and a [link](https://example.com).
    """

  // MARK: one contiguous selection scope

  func test_build_producesOneContiguousStringAcrossAllBlocks() {
    let attributed = MarkdownAttributedString.build(multiSection, foreground: .labelColor)
    let plain = attributed.string

    // Every block's text is present, in document order…
    for fragment in ["Intro paragraph", "item one", "item two", "let x = 1 < 2", "code", "link"] {
      XCTAssertTrue(plain.contains(fragment), "missing \(fragment) in: \(plain)")
    }
    let order = ["Intro paragraph", "item one", "item two", "let x = 1 < 2", "Inline"]
    var cursor = plain.startIndex
    for fragment in order {
      guard let range = plain.range(of: fragment, range: cursor..<plain.endIndex) else {
        return XCTFail("\(fragment) out of order in: \(plain)")
      }
      cursor = range.upperBound
    }

    // …and there is NO blank-line padding between blocks — a multi-paragraph
    // drag-copy must yield clean contiguous text.
    XCTAssertFalse(plain.contains("\n\n"), "blank-line padding leaked into the rendered text: \(plain)")
  }

  // MARK: link allowlist

  func test_build_activatesLinkOnlyForAllowedSchemes() {
    let source = """
      A [ok](https://example.com), a [mail](mailto:a@b.com), a [bad](javascript:alert(1)), \
      and a [file](file:///etc/passwd).
      """
    let attributed = MarkdownAttributedString.build(source, foreground: .labelColor)

    let links = allLinks(in: attributed)
    let schemes = Set(links.compactMap { $0.scheme?.lowercased() })
    XCTAssertEqual(schemes, ["https", "mailto"],
                   "only allowlisted schemes may carry a clickable .link; got \(schemes)")

    // The disallowed links keep their visible text — they are not erased.
    for fragment in ["bad", "file"] {
      XCTAssertTrue(attributed.string.contains(fragment),
                    "disallowed link text \(fragment) should remain visible")
    }
    // The allowlist is sourced from SafeLinkOpenURLAction, not a local literal.
    XCTAssertTrue(schemes.isSubset(of: SafeLinkOpenURLAction.allowedSchemes))
  }

  // MARK: code styling

  func test_build_rendersCodeMonospacedWithSharedBackground() {
    let attributed = MarkdownAttributedString.build(multiSection, foreground: .labelColor)

    // Inline `code`: monospaced + the exact prior black @ 0.10 background.
    let inline = firstRange(of: "code", in: attributed)
    let inlineAttrs = attributed.attributes(at: inline.location, effectiveRange: nil)
    XCTAssertTrue(isMonospaced(inlineAttrs[.font]), "inline code run should be monospaced")
    XCTAssertEqual(inlineAttrs[.backgroundColor] as? NSColor, MarkdownAttributedString.codeBackground)

    // Fenced block: monospaced.
    let block = firstRange(of: "let x = 1 < 2", in: attributed)
    let blockAttrs = attributed.attributes(at: block.location, effectiveRange: nil)
    XCTAssertTrue(isMonospaced(blockAttrs[.font]), "fenced code run should be monospaced")
    XCTAssertEqual(blockAttrs[.backgroundColor] as? NSColor, MarkdownAttributedString.codeBackground)
  }

  // MARK: foreground honored

  func test_build_honorsForegroundColorOnNonLinkRuns() {
    for color in [NSColor.white, NSColor.labelColor] {
      let attributed = MarkdownAttributedString.build("Plain **bold** text.", foreground: color)
      let range = firstRange(of: "Plain", in: attributed)
      let attrs = attributed.attributes(at: range.location, effectiveRange: nil)
      XCTAssertEqual(attrs[.foregroundColor] as? NSColor, color)
    }
  }

  // MARK: images never fetch

  func test_build_imageNeverBecomesFetchableAttachment() {
    let attributed = MarkdownAttributedString.build("![diagram](https://evil.example/x.png)",
                                                    foreground: .labelColor)
    // No NSTextAttachment is ever synthesized, so no image bytes are loaded —
    // the BlockedImageProvider guarantee, by construction.
    attributed.enumerateAttribute(.attachment,
                                  in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
      XCTAssertNil(value, "markdown image must not become an attachment")
    }
    XCTAssertGreaterThan(attributed.length, 0, "image markdown should still render a text placeholder")
  }

  // MARK: height / wrap contract

  func test_contentHeight_isPositiveAndTallerWhenNarrower() {
    let attributed = MarkdownAttributedString.build(
      "A reasonably long single paragraph that will certainly wrap onto multiple lines " +
      "once the container width is small enough to force several line fragments.",
      foreground: .labelColor)

    let wide = SelectableMarkdownText.contentHeight(forAttributed: attributed, containerWidth: 600)
    let narrow = SelectableMarkdownText.contentHeight(forAttributed: attributed, containerWidth: 120)

    XCTAssertGreaterThan(wide, 0)
    XCTAssertGreaterThanOrEqual(narrow, wide, "a narrower width must wrap at least as tall")
    XCTAssertEqual(SelectableMarkdownText.contentHeight(forAttributed: attributed, containerWidth: 0), 0)
  }

  func test_layoutWidth_hugsShortContentAndCapsLongContent() {
    let short = MarkdownAttributedString.build("hello", foreground: .labelColor)
    let shortWidth = SelectableMarkdownText.layoutWidth(forAttributed: short, maxWidth: 400)
    XCTAssertGreaterThan(shortWidth, 0)
    XCTAssertLessThan(shortWidth, 100,
                      "a short word must hug to a small width, not stretch to the cap")

    let long = MarkdownAttributedString.build(
      String(repeating: "wide unwrapped content ", count: 40), foreground: .labelColor)
    XCTAssertEqual(SelectableMarkdownText.layoutWidth(forAttributed: long, maxWidth: 400), 400,
                   "content wider than the cap clamps to maxWidth, then wraps")

    XCTAssertEqual(SelectableMarkdownText.layoutWidth(forAttributed: short, maxWidth: 0), 1,
                   "a non-positive cap floors to 1")
  }

  // MARK: parse-failure fallback

  func test_plainTextFallback_rendersSourceAsPlainSelectableText() {
    let source = "raw **bold** and `code` and [x](https://e.com) verbatim"
    let attributed = MarkdownAttributedString.plainText(source, foreground: .labelColor)

    // The whole source is present verbatim as ONE plain run — no markdown was
    // applied (no link, no code background), foreground honored, body font.
    XCTAssertEqual(attributed.string, source)
    let attrs = attributed.attributes(at: 0, effectiveRange: nil)
    XCTAssertEqual(attrs[.foregroundColor] as? NSColor, .labelColor)
    XCTAssertEqual(attrs[.font] as? NSFont, NSFont.preferredFont(forTextStyle: .body))
    attributed.enumerateAttribute(.link, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
      XCTAssertNil(value, "fallback must not synthesize links")
    }
    attributed.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
      XCTAssertNil(value, "fallback must not apply code backgrounds")
    }
  }

  // MARK: nested mixed-list markers

  /// A bulleted sublist nested inside an ordered list must keep its bullet
  /// marker — the inner list's type, not an ordered ancestor's, decides the
  /// marker. Regression for #641: the bullet items rendered as "1." because
  /// the marker was derived from "any ordered list in the ancestry" rather
  /// than the innermost enclosing list.
  func test_build_nestedBulletInOrderedListKeepsBulletMarker() {
    let source = """
      1. first ordered
      2. second ordered
         - bullet a
         - bullet b
      3. third ordered
      """
    let plain = MarkdownAttributedString.build(source, foreground: .labelColor).string

    // The bullet items carry "•", never a decimal marker.
    XCTAssertTrue(plain.contains("•\tbullet a"), "bullet a lost its bullet marker in: \(plain)")
    XCTAssertTrue(plain.contains("•\tbullet b"), "bullet b lost its bullet marker in: \(plain)")
    XCTAssertFalse(plain.contains("1.\tbullet a"), "bullet a wrongly rendered as ordered in: \(plain)")

    // The outer ordered items keep their decimal markers and numbering.
    for marker in ["1.\tfirst ordered", "2.\tsecond ordered", "3.\tthird ordered"] {
      XCTAssertTrue(plain.contains(marker), "missing ordered item \(marker) in: \(plain)")
    }
  }

  /// The symmetric case: an ordered sublist nested inside a bulleted list must
  /// render decimal markers, not the bullet of its unordered ancestor.
  func test_build_nestedOrderedInBulletListKeepsDecimalMarker() {
    let source = """
      - outer bullet
        1. inner one
        2. inner two
      """
    let plain = MarkdownAttributedString.build(source, foreground: .labelColor).string

    XCTAssertTrue(plain.contains("•\touter bullet"), "outer bullet lost its marker in: \(plain)")
    XCTAssertTrue(plain.contains("1.\tinner one"), "inner one lost its decimal marker in: \(plain)")
    XCTAssertTrue(plain.contains("2.\tinner two"), "inner two lost its decimal marker in: \(plain)")
  }

  func test_build_doesNotCrashOnDegenerateInput() {
    // Empty, whitespace, control chars, and deeply nested markup must all
    // render *something* without crashing — the fallback path (or partial
    // parse) keeps the bubble honest rather than blank.
    for source in ["", "   ", "\u{0}\u{1}\u{7}", String(repeating: "> ", count: 200) + "deep"] {
      let attributed = MarkdownAttributedString.build(source, foreground: .labelColor)
      XCTAssertNotNil(attributed)
    }
  }

  // MARK: helpers

  private func allLinks(in attributed: NSAttributedString) -> [URL] {
    var urls: [URL] = []
    attributed.enumerateAttribute(.link, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
      if let url = value as? URL { urls.append(url) }
      else if let s = value as? String, let url = URL(string: s) { urls.append(url) }
    }
    return urls
  }

  private func firstRange(of substring: String, in attributed: NSAttributedString) -> NSRange {
    let range = (attributed.string as NSString).range(of: substring)
    XCTAssertNotEqual(range.location, NSNotFound, "expected to find \(substring)")
    return range
  }

  private func isMonospaced(_ font: Any?) -> Bool {
    guard let font = font as? NSFont else { return false }
    return font.fontDescriptor.symbolicTraits.contains(.monoSpace)
  }
}
