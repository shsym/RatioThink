import Foundation

/// Canonical copy actions for one transcript turn (#515).
///
/// MarkdownUI renders a single assistant message as multiple native
/// SwiftUI `Text` blocks (paragraphs, lists, fenced code), and macOS
/// `.textSelection(.enabled)` only selects within ONE `Text` — so mouse
/// selection across a rendered message is structurally unreliable. The
/// deterministic path is an explicit copy action backed by the message's
/// canonical source text, independent of how the renderer split it.
///
/// Boundary policy (intentional, see tests):
///   · "Copy Answer" copies ONLY `content` — hidden or expanded reasoning
///     never leaks into an answer copy.
///   · "Copy Thinking" is offered separately, only when reasoning exists.
///   · Code blocks copy as Markdown source text, not a visual rendering.
///   · A copy taken mid-stream returns the committed content at that
///     moment — a consistent prefix, never a torn string.
struct MessageCopyPlan: Equatable {
  struct Item: Equatable {
    let label: String
    let text: String
  }

  let items: [Item]

  static func plan(for message: ChatMessageItem) -> MessageCopyPlan {
    var items: [Item] = []
    switch message.role {
    case .user:
      if !message.content.isEmpty {
        items.append(Item(label: "Copy Message", text: message.content))
      }
    case .assistant:
      if !message.content.isEmpty {
        items.append(Item(label: "Copy Answer", text: message.content))
      }
      if !message.reasoning.isEmpty {
        items.append(Item(label: "Copy Thinking", text: message.reasoning))
      }
    case .system:
      if !message.content.isEmpty {
        items.append(Item(label: "Copy", text: message.content))
      }
    }
    return MessageCopyPlan(items: items)
  }
}
