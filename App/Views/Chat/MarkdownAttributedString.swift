import AppKit
import Foundation
import os

private let markdownAttributedLog = Logger(subsystem: "com.ratiothink.app", category: "markdown")

/// Renders GitHub-flavored Markdown into a SINGLE `NSAttributedString` whose
/// visual styling tracks the previous MarkdownUI output closely (#158 / #636).
///
/// One attributed string = one text-storage = one selection scope, so the
/// hosting `NSTextView` lets a drag span every paragraph — the thing MarkdownUI's
/// per-block `Text` rendering structurally could not do.
///
/// Pipeline: Foundation's `AttributedString(markdown:options:)` with
/// `interpretedSyntax: .full` parses the source into runs carrying
/// `presentationIntent` (block structure: paragraph / heading / list / code
/// block / block quote) and `inlinePresentationIntent` (emphasis / strong /
/// inline code / strikethrough) plus `.link`. We group runs into blocks, render
/// each block's inline runs with the matching fonts/colors, prepend list
/// markers, apply a per-block paragraph style, and join blocks with a single
/// newline (never blank-line padding — a multi-paragraph drag-copy stays clean).
///
/// The whole thing is a pure function (`String` + foreground `NSColor` →
/// `NSAttributedString`), so the rendering contract is unit-tested without a
/// view host.
enum MarkdownAttributedString {
  /// Inline-code / fenced-code background — exact match to the previous
  /// `BackgroundColor(.black.opacity(0.10))` MarkdownUI style.
  static let codeBackground = NSColor.black.withAlphaComponent(0.10)

  static func build(_ markdown: String, foreground: NSColor) -> NSAttributedString {
    let baseFont = NSFont.preferredFont(forTextStyle: .body)
    let parsed: AttributedString
    do {
      parsed = try AttributedString(
        markdown: markdown,
        options: AttributedString.MarkdownParsingOptions(
          allowsExtendedAttributes: true,
          interpretedSyntax: .full,
          failurePolicy: .returnPartiallyParsedIfPossible
        )
      )
    } catch {
      // `.returnPartiallyParsedIfPossible` means Foundation returns partial
      // results for ordinary malformed Markdown and only THROWS on genuinely
      // unrecoverable input — so reaching here is a real parse failure worth
      // telemetry, not a routine event. Render the source as plain selectable
      // text (honest degradation, never a blank bubble), but log the dropped
      // error so a class of bubbles regressing to raw `**bold**` is visible.
      markdownAttributedLog.error("markdown parse failed, rendering plain text: \(error, privacy: .public)")
      return plainText(markdown, baseFont: baseFont, foreground: foreground)
    }

    let blocks = groupIntoBlocks(parsed)
    let result = NSMutableAttributedString()
    for (index, block) in blocks.enumerated() {
      if index > 0 { result.append(NSAttributedString(string: "\n")) }
      result.append(render(block: block, baseFont: baseFont, foreground: foreground))
    }
    return result
  }

  /// The parse-failure fallback: the raw source as plain, selectable body text
  /// in the bubble's foreground color — no link/code/markdown attributes.
  /// Internal so the degradation contract is unit-tested directly (forcing a
  /// real parser throw is unreliable).
  static func plainText(_ markdown: String,
                        baseFont: NSFont = .preferredFont(forTextStyle: .body),
                        foreground: NSColor) -> NSAttributedString {
    NSAttributedString(string: markdown, attributes: [
      .font: baseFont,
      .foregroundColor: foreground,
    ])
  }

  // MARK: - block model

  private struct InlineRun {
    let text: String
    let inline: InlinePresentationIntent
    let link: URL?
  }

  private struct Block {
    let intent: PresentationIntent?
    var runs: [InlineRun]
  }

  /// Splits the parsed string's runs into contiguous blocks sharing one
  /// `presentationIntent`. Foundation emits one intent instance (distinct
  /// `identity`) per source block, so an intent change marks a block boundary.
  private static func groupIntoBlocks(_ parsed: AttributedString) -> [Block] {
    var blocks: [Block] = []
    var started = false
    for run in parsed.runs {
      let text = String(parsed[run.range].characters)
      let inline = InlineRun(text: text,
                             inline: run.inlinePresentationIntent ?? [],
                             link: run.link)
      let intent = run.presentationIntent
      if started, let last = blocks.last, last.intent == intent {
        blocks[blocks.count - 1].runs.append(inline)
      } else {
        blocks.append(Block(intent: intent, runs: [inline]))
        started = true
      }
    }
    return blocks
  }

  // MARK: - block rendering

  private static func render(block: Block, baseFont: NSFont, foreground: NSColor) -> NSAttributedString {
    let kind = blockKind(block.intent)

    // The per-block base font: monospaced for code, bold+scaled for headings,
    // body for everything else. Inline intents refine it further per run.
    let blockFont: NSFont
    switch kind {
    case .codeBlock:
      blockFont = monospacedFont(ofSize: baseFont.pointSize)
    case .heading(let level):
      blockFont = headingFont(baseFont: baseFont, level: level)
    default:
      blockFont = baseFont
    }

    let body = NSMutableAttributedString()
    if case .listItem(let marker, _) = kind {
      body.append(NSAttributedString(string: marker, attributes: [
        .font: baseFont, .foregroundColor: foreground,
      ]))
    }

    for run in block.runs {
      body.append(renderInline(run, blockFont: blockFont, foreground: foreground))
    }

    // A thematic break carries no text — render a horizontal rule line.
    if kind == .thematicBreak, body.length == 0 {
      body.append(NSAttributedString(string: "—————", attributes: [
        .font: baseFont,
        .foregroundColor: foreground.withAlphaComponent(0.4),
      ]))
    }

    // Trim trailing newlines a block (notably a fenced code block) may carry,
    // so joining blocks with a single "\n" never produces blank-line padding —
    // a multi-paragraph drag-copy then yields clean contiguous text.
    while body.string.hasSuffix("\n") {
      body.deleteCharacters(in: NSRange(location: body.length - 1, length: 1))
    }

    body.addAttribute(.paragraphStyle, value: paragraphStyle(for: kind),
                      range: NSRange(location: 0, length: body.length))
    if kind == .codeBlock, body.length > 0 {
      body.addAttribute(.backgroundColor, value: codeBackground,
                        range: NSRange(location: 0, length: body.length))
    }
    return body
  }

  private static func renderInline(_ run: InlineRun,
                                   blockFont: NSFont,
                                   foreground: NSColor) -> NSAttributedString {
    let inline = run.inline
    var font = blockFont
    let isInlineCode = inline.contains(.code)
    if isInlineCode { font = monospacedFont(ofSize: blockFont.pointSize) }
    font = applyTraits(font,
                       bold: inline.contains(.stronglyEmphasized),
                       italic: inline.contains(.emphasized))

    var attrs: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: foreground,
    ]
    if isInlineCode { attrs[.backgroundColor] = codeBackground }
    if inline.contains(.strikethrough) {
      attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
    }

    // Activate a link only for an allowlisted scheme; a disallowed-scheme link
    // keeps its visible text but carries no clickable target (matches
    // `SafeLinkOpenURLAction`, enforced again at click time).
    if let url = run.link, SafeLinkOpenURLAction.allowedSchemes.contains(url.scheme?.lowercased() ?? "") {
      attrs[.link] = url
      attrs[.foregroundColor] = NSColor.linkColor
      attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
    }

    return NSAttributedString(string: run.text, attributes: attrs)
  }

  // MARK: - block taxonomy

  private enum BlockKind: Equatable {
    case paragraph
    case heading(level: Int)
    /// `marker` is the rendered prefix ("•\t" or "2.\t"); `depth` the nesting.
    case listItem(marker: String, depth: Int)
    case codeBlock
    case blockQuote
    case thematicBreak
  }

  private static func blockKind(_ intent: PresentationIntent?) -> BlockKind {
    guard let intent else { return .paragraph }
    let components = intent.components
    if components.contains(where: { if case .codeBlock = $0.kind { return true }; return false }) {
      return .codeBlock
    }
    if let header = components.first(where: { if case .header = $0.kind { return true }; return false }),
       case .header(let level) = header.kind {
      return .heading(level: level)
    }
    if let listItem = components.first(where: { if case .listItem = $0.kind { return true }; return false }),
       case .listItem(let ordinal) = listItem.kind {
      let depth = components.filter {
        if case .orderedList = $0.kind { return true }
        if case .unorderedList = $0.kind { return true }
        return false
      }.count
      let ordered = components.contains { if case .orderedList = $0.kind { return true }; return false }
      let marker = ordered ? "\(ordinal).\t" : "•\t"
      return .listItem(marker: marker, depth: max(1, depth))
    }
    if components.contains(where: { if case .blockQuote = $0.kind { return true }; return false }) {
      return .blockQuote
    }
    if components.contains(where: { if case .thematicBreak = $0.kind { return true }; return false }) {
      return .thematicBreak
    }
    return .paragraph
  }

  // MARK: - styling helpers

  private static func paragraphStyle(for kind: BlockKind) -> NSParagraphStyle {
    let style = NSMutableParagraphStyle()
    style.paragraphSpacing = 8
    switch kind {
    case .heading:
      style.paragraphSpacingBefore = 4
    case .listItem(_, let depth):
      let indent = CGFloat(depth) * 18
      style.firstLineHeadIndent = indent - 18 + 2
      style.headIndent = indent
      style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
      style.paragraphSpacing = 2
    case .codeBlock:
      style.firstLineHeadIndent = 6
      style.headIndent = 6
    case .blockQuote:
      style.firstLineHeadIndent = 12
      style.headIndent = 12
    default:
      break
    }
    return style
  }

  /// Heading point sizes scale off the body font, bold — a close ramp to the
  /// previous MarkdownUI heading styling (not theme-pixel-matched).
  private static func headingFont(baseFont: NSFont, level: Int) -> NSFont {
    let scale: CGFloat
    switch level {
    case 1: scale = 1.6
    case 2: scale = 1.4
    case 3: scale = 1.25
    case 4: scale = 1.1
    case 5: scale = 1.0
    default: scale = 0.9
    }
    let bold = NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)
    return NSFont(descriptor: bold.fontDescriptor, size: baseFont.pointSize * scale) ?? bold
  }

  private static func monospacedFont(ofSize size: CGFloat) -> NSFont {
    NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
  }

  private static func applyTraits(_ font: NSFont, bold: Bool, italic: Bool) -> NSFont {
    var mask: NSFontTraitMask = []
    if bold { mask.insert(.boldFontMask) }
    if italic { mask.insert(.italicFontMask) }
    guard !mask.isEmpty else { return font }
    return NSFontManager.shared.convert(font, toHaveTrait: mask)
  }
}
