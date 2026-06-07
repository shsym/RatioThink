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
          // Show the answer bubble once content arrives. When it is still
          // empty, render a placeholder bubble ONLY for a fresh streaming row
          // — not when a reasoning section (#329) or a live tree (#413) is
          // already showing, and not when the turn FINISHED with no answer
          // (#434: the notice below explains that instead of a silent blank).
          if !message.content.isEmpty
            || (message.reasoning.isEmpty && message.tot == nil && message.finishReason == nil) {
            bubble(background: Color.secondary.opacity(0.15),
                   foreground: .primary,
                   alignment: .leading)
          }
          // Honest end-state: explain a missing/truncated answer rather
          // than rendering nothing. (#434)
          if let text = message.notice.message {
            TurnNoticeRow(text: text, footnote: message.notice.isFootnote)
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

// MARK: - truncation notice

/// One-line honest end-state for an assistant turn that produced no answer
/// (or a truncated one). Distinct from the answer bubble and the Thinking
/// section: it explains WHY the reply is missing/short and points at the
/// composer's "Max tokens" control. The footnote variant sits quietly under
/// a partial answer; the stand-alone variant takes the place of a missing
/// one. Copy lives in `TurnNotice.message`. (#434)
private struct TurnNoticeRow: View {
  let text: String
  let footnote: Bool

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 5) {
      Image(systemName: "exclamationmark.triangle")
      Text(text)
        .fixedSize(horizontal: false, vertical: true)
    }
    .font(footnote ? .caption2 : .caption)
    .foregroundStyle(.secondary)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }
}

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
