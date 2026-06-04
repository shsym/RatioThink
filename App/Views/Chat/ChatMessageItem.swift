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
  /// Engine `finish_reason` for a completed turn (`"stop"`, `"length"`,
  /// `"cancelled"`, …), or `nil` while the turn is still streaming. Lets
  /// `MessageBubble` surface a truncated-before-answer turn instead of a
  /// silent blank. (#434)
  var finishReason: String?

  init(id: UUID = UUID(), role: ChatMessage.Role, content: String, reasoning: String = "", finishReason: String? = nil) {
    self.id = id
    self.role = role
    self.content = content
    self.reasoning = reasoning
    self.finishReason = finishReason
  }

  /// Honest terminal state for the turn — drives the truncation notice so
  /// a reply that ran out of budget while thinking never renders blank.
  var notice: TurnNotice {
    TurnNotice.classify(content: content, reasoning: reasoning, finishReason: finishReason)
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
    self.init(id: message.id, role: role, content: message.content, reasoning: message.reasoning, finishReason: message.finishReason)
  }
}
