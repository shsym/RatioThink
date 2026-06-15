import AppKit
import SwiftUI
import os

/// A single, drag-selectable Markdown surface for one chat message body (#158
/// / #636).
///
/// MarkdownUI renders a message as MANY separate SwiftUI `Text` blocks, and on
/// Apple platforms `.textSelection(.enabled)` cannot span more than one `Text`
/// — so a drag selection is trapped inside a single paragraph/list/code block
/// (the structural limit #515 worked around with an explicit copy button).
/// This view instead renders the whole message into ONE `NSAttributedString`
/// hosted in a read-only, selectable `NSTextView`: a single text storage means
/// a single selection scope, so a drag spans every paragraph and `Copy` yields
/// the full multi-paragraph selection.
///
/// Security parity with the old MarkdownUI path:
///   · Links activate only for `SafeLinkOpenURLAction.allowedSchemes`
///     ({http, https, mailto}); other schemes keep their text but carry no
///     clickable target, and a click is dropped + logged.
///   · Images never hit the network — `NSAttributedString(markdown:)` does not
///     fetch remote image bytes, and the builder renders a text placeholder
///     in their place (the `BlockedImageProvider` guarantee, by construction).
struct SelectableMarkdownText: View {
  let markdown: String
  /// The bubble's foreground color (user = white on accent, assistant =
  /// primary on fill). Applied as the default text color for every non-link
  /// run so the attributed string honors the role styling.
  let foreground: NSColor

  /// The view's live laid-out width, captured from SwiftUI via a background
  /// `GeometryReader`. Height is derived from the rendered attributed string
  /// measured at this width — computed where both inputs are known, avoiding
  /// the `NSTextView` round-trip whose width isn't valid yet at
  /// `updateNSView` time (the same timing trap `ComposerView` documents).
  @State private var width: CGFloat = 0

  private var attributed: NSAttributedString {
    MarkdownAttributedString.build(markdown, foreground: foreground)
  }

  var body: some View {
    let rendered = attributed
    return SelectableMarkdownTextView(attributed: rendered)
      .frame(height: Self.contentHeight(forAttributed: rendered, containerWidth: width))
      .background(
        GeometryReader { geo in
          Color.clear.preference(key: SelectableMarkdownWidthKey.self, value: geo.size.width)
        }
      )
      .onPreferenceChange(SelectableMarkdownWidthKey.self) { width = $0 }
  }

  /// The attributed string's real laid-out height at a given container width —
  /// the measurement that drives the SwiftUI frame. Pure (throwaway TextKit
  /// stack, no view host) and the single source the live text view's layout
  /// also reproduces (same width, zero line-fragment padding), so the wrap
  /// contract is unit-testable: a narrower width wraps taller. Mirrors
  /// `ComposerView.contentHeight`.
  static func contentHeight(forAttributed attributed: NSAttributedString,
                            containerWidth: CGFloat) -> CGFloat {
    guard containerWidth > 1, attributed.length > 0 else { return 0 }
    let storage = NSTextStorage(attributedString: attributed)
    let layout = NSLayoutManager()
    storage.addLayoutManager(layout)
    let container = NSTextContainer(size: CGSize(width: containerWidth,
                                                 height: CGFloat.greatestFiniteMagnitude))
    container.lineFragmentPadding = 0
    layout.addTextContainer(container)
    layout.ensureLayout(for: container)
    return ceil(layout.usedRect(for: container).height)
  }
}

/// Carries the surface's measured width up so `SelectableMarkdownText` can
/// wrap-measure the rendered message at the real laid-out width.
private struct SelectableMarkdownWidthKey: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

// MARK: - AppKit bridge

private let selectableMarkdownLog = Logger(subsystem: "com.ratiothink.app", category: "markdown")

/// Read-only, selectable `NSTextView` host. No enclosing `NSScrollView`: the
/// surface sizes to its full content height (`SelectableMarkdownText.frame`),
/// and the transcript's outer scroll view owns scrolling. Background is
/// transparent so the bubble's rounded fill shows through.
private struct SelectableMarkdownTextView: NSViewRepresentable {
  let attributed: NSAttributedString

  func makeNSView(context: Context) -> NSTextView {
    // Build an explicit TextKit 1 stack so `textStorage` is always live and the
    // container tracks the view width (a bare `NSTextView()` defaults to
    // TextKit 2 on macOS 14, where the compatibility `textStorage` bridge is
    // surprising). Mirrors `ComposerTextEditor`'s fallback construction.
    let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    container.widthTracksTextView = true
    container.lineFragmentPadding = 0
    let layoutManager = NSLayoutManager()
    let storage = NSTextStorage()
    storage.addLayoutManager(layoutManager)
    layoutManager.addTextContainer(container)

    let textView = NSTextView(frame: NSRect.zero, textContainer: container)
    applyResizableTextViewGeometry(to: textView)
    textView.delegate = context.coordinator
    textView.isEditable = false
    textView.isSelectable = true
    textView.drawsBackground = false
    textView.textContainerInset = NSSize.zero
    // We author exactly the links we trust (allowlisted schemes only); do not
    // let AppKit synthesize extra clickable links from raw URLs in the text.
    textView.isAutomaticLinkDetectionEnabled = false
    textView.textStorage?.setAttributedString(attributed)
    return textView
  }

  func updateNSView(_ textView: NSTextView, context: Context) {
    // Re-render only on a real content/color change so a width-driven layout
    // pass never clobbers the user's live selection.
    if !(textView.textStorage?.isEqual(to: attributed) ?? false) {
      textView.textStorage?.setAttributedString(attributed)
    }
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  final class Coordinator: NSObject, NSTextViewDelegate {
    /// Enforce the link allowlist at click time (defense in depth — the
    /// builder already withholds `.link` for disallowed schemes). Mirrors
    /// `SafeLinkOpenURLAction.action`: open allowed schemes, drop + log the
    /// rest, and swallow the click so AppKit's default handler never opens it.
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
      let url: URL?
      switch link {
      case let u as URL: url = u
      case let s as String: url = URL(string: s)
      default: url = nil
      }
      guard let url else { return true }
      let scheme = url.scheme?.lowercased() ?? ""
      guard SafeLinkOpenURLAction.allowedSchemes.contains(scheme) else {
        selectableMarkdownLog.error("dropped markdown link with disallowed scheme: \(scheme, privacy: .public)")
        return true
      }
      NSWorkspace.shared.open(url)
      return true
    }
  }
}
