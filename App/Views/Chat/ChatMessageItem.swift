import Foundation
import os

private let chatMessageItemLog = Logger(subsystem: "com.ratiothink.app", category: "chat-message-item")

/// UI-side projection of a transcript turn used by `MessageBubble`.
///
/// SwiftData's `Message` is the persistent source of truth; this
/// struct is a value-type adapter that lets the renderer stay
/// `@Model`-agnostic (snapshot tests, previews and any future
/// pre-engine UI iteration can construct items without a
/// `ModelContainer`). `TranscriptView` builds an array of these on
/// the fly from `chat.messages`.
struct ChatMessageItem: Identifiable, Equatable {
  let id: UUID
  var role: ChatMessage.Role
  var content: String
  /// Model thinking-block text, rendered in a collapsible section
  /// separate from `content`. Empty when the turn has no
  /// reasoning.
  var reasoning: String
  /// Decoded tree-of-thought search for a ToT turn (#413), rendered in a
  /// collapsible live tree-search section — the structured analogue of
  /// the "Thinking" section. Nil for ordinary chat turns (and when a
  /// persisted snapshot fails to decode, treated as no tree).
  var tot: ToTTree?
  /// Engine `finish_reason` for a completed turn (`"stop"`, `"length"`,
  /// `"cancelled"`, …), or `nil` while the turn is still streaming. Lets
  /// `MessageBubble` surface a truncated-before-answer turn instead of a
  /// silent blank. (#434)
  var finishReason: String?
  /// Engine-reported generation throughput for a completed assistant turn.
  /// Nil for historical rows and turns whose metric policy is intentionally
  /// hidden (cancelled/failed/invalid metrics).
  var generationPerformance: GenerationMetrics?

  init(
    id: UUID = UUID(),
    role: ChatMessage.Role,
    content: String,
    reasoning: String = "",
    tot: ToTTree? = nil,
    finishReason: String? = nil,
    generationPerformance: GenerationMetrics? = nil
  ) {
    self.id = id
    self.role = role
    self.content = content
    self.reasoning = reasoning
    self.tot = tot
    self.finishReason = finishReason
    self.generationPerformance = generationPerformance
  }

  /// Honest terminal state for the turn — drives the truncation notice so
  /// a reply that ran out of budget while thinking never renders blank.
  var notice: TurnNotice {
    TurnNotice.classify(content: content, reasoning: reasoning, finishReason: finishReason)
  }

  var generationPerformanceText: String? {
    guard role == .assistant,
          finishReason != "cancelled",
          let generationPerformance,
          generationPerformance.outputTokens > 0,
          generationPerformance.elapsedSeconds > 0,
          generationPerformance.elapsedSeconds.isFinite,
          generationPerformance.tokensPerSecond > 0,
          generationPerformance.tokensPerSecond.isFinite else { return nil }
    let rounded = Int(generationPerformance.tokensPerSecond.rounded())
    guard rounded > 0 else { return nil }
    return "\(rounded) tok/s"
  }
}

extension ChatMessageItem {
  /// Lift a persisted `Message` into the renderer's projection.
  /// Unknown role strings fall back to `.system` rather than crash
  /// — the row is still display-worthy as a transcript breadcrumb.
  /// The fallback is logged so a wire-format drift (engine adds a
  /// new role like `"tool"`) or a corrupted JSON import surfaces in
  /// the console even when the user does not notice the row got
  /// rendered as a system breadcrumb ( F12).
  init(_ message: Message) {
    let role: ChatMessage.Role
    if let known = ChatMessage.Role(rawValue: message.role) {
      role = known
    } else {
      chatMessageItemLog.warning("unknown role string, coercing to .system: \(message.role, privacy: .public)")
      role = .system
    }
    // Tolerant decode: a snapshot written by a newer/older schema that no
    // longer decodes is treated as "no tree" rather than failing the row.
    let tot = message.tot.flatMap { try? JSONDecoder().decode(ToTTree.self, from: $0) }
    self.init(
      id: message.id, role: role, content: message.content,
      reasoning: message.reasoning, tot: tot, finishReason: message.finishReason,
      generationPerformance: message.generationPerformance)
  }
}
