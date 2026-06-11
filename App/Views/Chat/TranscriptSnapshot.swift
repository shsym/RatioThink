import Foundation

/// One render-pass value projection for a chat transcript.
///
/// `TranscriptView` invalidates frequently while the assistant is streaming.
/// Keep SwiftData relationship traversal, sorting, role coercion, and scroll-key
/// derivation together so the SwiftUI layout/identity path consumes cheap
/// values instead of repeatedly asking `Message` @Model rows for identity and
/// content during a single body evaluation.
struct TranscriptSnapshot: Equatable {
  let items: [ChatMessageItem]
  let scrollKey: String

  init(items: [ChatMessageItem]) {
    self.items = items
    let lengthSum = items.reduce(0) { partial, item in
      partial &+ item.content.count &+ item.reasoning.count
    }
    self.scrollKey = "\(items.count):\(lengthSum)"
  }

  init<MessageSource: Sequence>(
    messages: MessageSource,
    timestamp: (MessageSource.Element) -> Date,
    item: (MessageSource.Element) -> ChatMessageItem
  ) {
    let projected = messages.map { row in
      (timestamp: timestamp(row), item: item(row))
    }
    let sortedItems = projected
      .sorted { $0.timestamp < $1.timestamp }
      .map(\.item)
    self.init(items: sortedItems)
  }
}

@available(macOS 14, *)
extension TranscriptSnapshot {
  init(messages: [Message]) {
    self.init(
      messages: messages,
      timestamp: { $0.ts },
      item: { ChatMessageItem($0) }
    )
  }
}
