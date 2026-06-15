import AppKit
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
  /// #513: retry-from-this-turn affordance, assistant rows only. Nil hides
  /// the control — the scaffold passes nil while the chat is streaming
  /// (retry waits for the active stream to end) and `TranscriptView` passes
  /// nil for rows where no retained prefix exists to resend.
  var onRetry: (() -> Void)? = nil
  /// Edit-and-resend hook (#624), user rows only. Non-nil only for an
  /// editable prior user turn (the transcript passes `nil` while a turn is
  /// streaming), which is what gates the Edit affordance. The closure
  /// receives the new text and forks the conversation from here.
  var onEdit: ((String) -> Void)? = nil

  @State private var isEditing = false
  @State private var editText = ""

  var body: some View {
    switch message.role {
    case .user:
      HStack {
        Spacer(minLength: 60)
        if isEditing {
          editor
        } else {
          bubble(background: Color.accentColor,
                 foreground: .white,
                 alignment: .trailing)
        }
      }
      .contextMenu {
        copyMenuItems
        // #624: edit-and-fork from this user turn. Hidden while editing or
        // when the scaffold withholds the hook (a stream is in flight).
        if !isEditing, onEdit != nil {
          Divider()
          Button(action: beginEditing) {
            Label("Edit", systemImage: "pencil")
          }
          .accessibilityIdentifier("message.user.edit")
        }
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
          if let text = message.generationPerformanceText {
            GenerationPerformanceRow(text: text)
              .reportMessageBubbleFrame(.generationPerformance(message.id))
          }
          // One quiet chrome row under the turn: the deterministic copy
          // path (#515 — right-click on selectable MarkdownUI text surfaces
          // AppKit's text menu, not our `.contextMenu`, so the guaranteed
          // affordance is this explicit button; see `MessageCopyPlan`) and
          // the #513 retry control. Retry reads as turn chrome, not a
          // primary action — the destructive part is guarded by the
          // scaffold's confirmation when retry would erase anything beyond
          // this stale assistant.
          if !message.content.isEmpty || onRetry != nil {
            HStack(spacing: 12) {
              if !message.content.isEmpty {
                CopyAnswerButton(text: message.content)
              }
              if let onRetry {
                Button(action: onRetry) {
                  Label("Retry", systemImage: "arrow.counterclockwise")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Retry from here — regenerates this response; affected responses and any later conversation are erased after you confirm")
                .accessibilityIdentifier("transcript.retry")
              }
            }
          }
        }
        Spacer(minLength: 60)
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("message.assistant")
      .contextMenu { copyMenuItems }
    case .system:
      HStack {
        Spacer()
        Text(message.content)
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
      }
      .contextMenu { copyMenuItems }
    }
  }

  /// Deterministic copy path (#515): MarkdownUI splits one message into
  /// many selectable `Text` blocks, so mouse selection cannot span a whole
  /// rendered message. The context menu copies the canonical backing text
  /// from `ChatMessageItem` instead — see `MessageCopyPlan` for the
  /// answer/thinking boundary policy.
  @ViewBuilder
  private var copyMenuItems: some View {
    ForEach(MessageCopyPlan.plan(for: message).items, id: \.label) { item in
      Button(item.label) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.text, forType: .string)
      }
    }
  }

  // MARK: - inline edit (#624)

  private func beginEditing() {
    editText = message.content
    isEditing = true
  }

  private func commitEdit() {
    let trimmed = editText.trimmingCharacters(in: .whitespacesAndNewlines)
    isEditing = false
    guard !trimmed.isEmpty else { return }
    onEdit?(trimmed)
  }

  /// Inline editor that replaces the user bubble while editing. Saving
  /// forks the conversation from this turn and re-runs it; Cancel restores
  /// the bubble untouched. Right-aligned to match the user bubble.
  private var editor: some View {
    VStack(alignment: .trailing, spacing: 6) {
      TextEditor(text: $editText)
        .font(.body)
        .frame(minHeight: 60, maxHeight: 200)
        .padding(6)
        .background(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.accentColor.opacity(0.6))
        )
        .accessibilityIdentifier("message.edit.field")
      HStack(spacing: 8) {
        Button("Cancel") { isEditing = false }
          .accessibilityIdentifier("message.edit.cancel")
        Button("Save & Resend") { commitEdit() }
          .keyboardShortcut(.return, modifiers: .command)
          .buttonStyle(.borderedProminent)
          .accessibilityIdentifier("message.edit.save")
      }
    }
    .frame(maxWidth: .infinity, alignment: .trailing)
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
      .reportMessageBubbleFrame(.content(message.id))
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
      .frame(maxWidth: .infinity, alignment: alignment == .trailing ? .trailing : .leading)
  }
}

// MARK: - layout frame reporting

/// Internal, no-op-unless-observed layout telemetry for app-unit geometry
/// guards. The production transcript does not read this preference; tests use
/// it to validate the real SwiftUI/AppKit-hosted `MessageBubble` tree instead
/// of duplicating fragile headless layout math.
enum MessageBubbleLayoutFrameID: Hashable {
  case content(UUID)
  case generationPerformance(UUID)
}

struct MessageBubbleLayoutFramePreferenceKey: PreferenceKey {
  static var defaultValue: [MessageBubbleLayoutFrameID: CGRect] = [:]

  static func reduce(
    value: inout [MessageBubbleLayoutFrameID: CGRect],
    nextValue: () -> [MessageBubbleLayoutFrameID: CGRect]
  ) {
    value.merge(nextValue(), uniquingKeysWith: { _, new in new })
  }
}

private struct MessageBubbleFrameReporter: View {
  let id: MessageBubbleLayoutFrameID

  var body: some View {
    GeometryReader { proxy in
      Color.clear.preference(key: MessageBubbleLayoutFramePreferenceKey.self,
                             value: [id: proxy.frame(in: .global)])
    }
  }
}

private extension View {
  func reportMessageBubbleFrame(_ id: MessageBubbleLayoutFrameID) -> some View {
    background(MessageBubbleFrameReporter(id: id))
  }
}

// MARK: - copy button

/// Quiet always-available "Copy" under an assistant answer (#515). Writes
/// the message's canonical Markdown source to the general pasteboard and
/// flips to a brief "Copied" confirmation.
private struct CopyAnswerButton: View {
  let text: String
  @State private var copied = false

  var body: some View {
    Button {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
      copied = true
      Task {
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        copied = false
      }
    } label: {
      HStack(spacing: 3) {
        Image(systemName: copied ? "checkmark" : "doc.on.doc")
        Text(copied ? "Copied" : "Copy")
      }
      .font(.caption2)
      .foregroundStyle(.secondary)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("Copy the full answer as Markdown source")
    .accessibilityIdentifier("message.copyAnswer")
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

private struct GenerationPerformanceRow: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.caption2)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityIdentifier("message.generationPerformance")
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
