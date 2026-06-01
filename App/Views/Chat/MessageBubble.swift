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
          if !message.reasoning.isEmpty {
            ThinkingSection(
              reasoning: message.reasoning,
              answerStarted: !message.content.isEmpty
            )
          }
          // Show the answer bubble once content arrives; when there's
          // no reasoning at all, keep rendering it even while empty so
          // the freshly-inserted streaming row still shows a placeholder
          // bubble (preserves prior behavior).
          if !message.content.isEmpty || message.reasoning.isEmpty {
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

/// Collapsible "Thinking" disclosure for an assistant turn's reasoning
/// (`reasoning_content`). Distinct from the answer bubble so the model's
/// scratchpad never mixes into — or gets copied with — the visible
/// answer.
///
/// Expansion policy: auto-expanded while the answer hasn't started
/// (reasoning streaming live), auto-folds the moment visible content
/// arrives. A manual toggle wins and sticks for the turn's lifetime, so
/// a user who opens the section to watch the model think keeps it open
/// past the answer's first token. Folded by default once a completed
/// turn is reloaded from disk.
///
/// Reasoning is rendered as plain (monospaced, secondary) text rather
/// than Markdown — it's an internal scratchpad, not authored prose, and
/// keeping it un-rendered avoids re-interpreting half-formed markup mid
/// stream. It is selectable only while expanded; collapsed, it is absent
/// from the view tree so a copy of the answer can't pull it in.
private struct ThinkingSection: View {
  let reasoning: String
  let answerStarted: Bool
  @State private var userExpanded: Bool?

  private var isExpanded: Bool { userExpanded ?? !answerStarted }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Button {
        userExpanded = !isExpanded
      } label: {
        HStack(spacing: 4) {
          Image(systemName: "brain")
          Text("Thinking")
            .fontWeight(.medium)
          Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(isExpanded ? "Hide the model's reasoning" : "Show the model's reasoning")

      if isExpanded {
        Text(reasoning)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 10)
          .padding(.vertical, 8)
          .background(
            Color.secondary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
          )
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .animation(.easeInOut(duration: 0.15), value: isExpanded)
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
