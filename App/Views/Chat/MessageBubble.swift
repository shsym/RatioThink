import SwiftUI
import MarkdownUI
import os

/// One transcript turn rendered Messages-style:
///
///   · user     — right-aligned, accent-tinted bubble, white text
///   · assistant — left-aligned, secondary-fill bubble, primary text
///   · system    — center-aligned hairline meta row (rendered as plain
///                 secondary text, no bubble — it's transcript chrome,
///                 not a conversational turn)
///
/// Markdown is rendered via `MarkdownUI` so fenced code blocks, lists,
/// and inline emphasis come out native instead of as raw `**bold**`
/// literals. System turns deliberately skip Markdown — they're status
/// breadcrumbs, not prose.
///
/// Security: assistant turns are untrusted model output. We gate link
/// activation through `SafeLinkOpenURLAction` (http / https / mailto
/// only) and replace MarkdownUI's default `ImageProvider` with
/// `BlockedImageProvider` so remote image URLs cannot pull bytes off
/// the network until an explicit policy lands. Review v1 F3.
struct MessageBubble: View {
  let message: ChatMessageItem

  var body: some View {
    switch message.role {
    case .user:
      HStack {
        Spacer(minLength: 60)
        bubble(background: Color.accentColor,
               foreground: .white,
               alignment: .trailing)
      }
    case .assistant:
      HStack {
        VStack(alignment: .leading, spacing: 6) {
          // #413: a tree-of-thought turn renders its live search above the
          // answer, the structured sibling of the reasoning section.
          if let tot = message.tot {
            TreeSearchSection(tree: tot, answerStarted: !message.content.isEmpty)
          }
          if !message.reasoning.isEmpty {
            ReasoningDisclosure(
              reasoning: message.reasoning,
              answerStarted: !message.content.isEmpty
            )
          }
          // Show the answer bubble once content arrives; when there's
          // neither reasoning nor a tree, keep rendering it even while
          // empty so the freshly-inserted streaming row still shows a
          // placeholder bubble (preserves prior behavior). A ToT turn
          // mid-search has empty content + a tree, so it shows only the
          // tree until the final answer lands.
          if !message.content.isEmpty || (message.reasoning.isEmpty && message.tot == nil) {
            bubble(background: Color.secondary.opacity(0.15),
                   foreground: .primary,
                   alignment: .leading)
          }
        }
        Spacer(minLength: 60)
      }
    case .system:
      HStack {
        Spacer()
        Text(message.content)
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
      }
    }
  }

  private func bubble(background: Color, foreground: Color, alignment: HorizontalAlignment) -> some View {
    Markdown(message.content)
      .markdownTextStyle(\.text) { ForegroundColor(foreground) }
      .markdownTextStyle(\.code) {
        FontFamilyVariant(.monospaced)
        BackgroundColor(.black.opacity(0.10))
      }
      .markdownImageProvider(BlockedImageProvider())
      .environment(\.openURL, SafeLinkOpenURLAction.action)
      .textSelection(.enabled)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
      .frame(maxWidth: .infinity, alignment: alignment == .trailing ? .trailing : .leading)
  }
}

// MARK: - thinking section

// The assistant turn's reasoning disclosure (#329) is now the shared
// `ReasoningDisclosure` (see ReasoningDisclosure.swift) — the same component
// each tree-of-thought node uses for its per-node thinking (#413).

// MARK: - link policy

private let markdownLog = Logger(subsystem: "com.ratiothink.app", category: "markdown")

/// Allowlist for link activation inside assistant-authored Markdown.
/// Anything outside `{http, https, mailto}` is dropped before reaching
/// `NSWorkspace.shared.open`, so a `[click](javascript:…)` payload from
/// the model can't pop a sheet, file an XPC, or hijack the focused
/// session. Review v1 F3.
enum SafeLinkOpenURLAction {
  static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

  static let action = OpenURLAction { url in
    let scheme = url.scheme?.lowercased() ?? ""
    guard allowedSchemes.contains(scheme) else {
      markdownLog.error("dropped markdown link with disallowed scheme: \(scheme, privacy: .public)")
      return .discarded
    }
    return .systemAction(url)
  }
}

// MARK: - image policy

/// Image provider that never fetches. Renders a small placeholder so
/// the user knows an image was suppressed; the model cannot use it as
/// a beacon (no GET to attacker-controlled origin). Phase 4+ can swap
/// in a same-origin or content-addressed provider once we have one.
/// Review v1 F3.
struct BlockedImageProvider: ImageProvider {
  func makeImage(url: URL?) -> some View {
    HStack(spacing: 4) {
      Image(systemName: "photo")
        .foregroundStyle(.secondary)
      Text("image suppressed")
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 2)
    .background(
      RoundedRectangle(cornerRadius: 4)
        .strokeBorder(Color.secondary.opacity(0.3))
    )
    .help(url?.absoluteString ?? "")
  }
}
