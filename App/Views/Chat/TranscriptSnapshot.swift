import Foundation

#if DEBUG
/// #530 DEBUG-only counter of full transcript SORT PASSES performed by the
/// render projection (`TranscriptSnapshot.init(messages: [Message])`). One
/// increment == one `.sorted(by: Message.transcriptPrecedes)` pass over the
/// transcript — NOT one pairwise comparison.
///
/// The #521 fix builds the projection ONCE per `TranscriptView` body evaluation,
/// so a body eval records exactly one pass. The pre-#521 pattern re-derived a
/// re-sorting `sortedMessages` several times per body (≈4 passes). A unit test
/// evaluates `TranscriptView.body` and asserts exactly one pass, so reintroducing
/// the N-sorts churn fails deterministically — an exact count, independent of
/// timing or hardware (which the S530 GUI watchdog provably cannot separate).
public enum TranscriptSortProbe {
  // Render projection runs on the main actor; the lock keeps the counter safe if
  // a test ever drives it off-main and silences Swift 6 concurrency diagnostics.
  nonisolated(unsafe) private static var passes = 0
  private static let lock = NSLock()

  public static func reset() {
    lock.lock(); defer { lock.unlock() }
    passes = 0
  }

  static func recordSortPass() {
    lock.lock(); defer { lock.unlock() }
    passes += 1
  }

  public static var sortPasses: Int {
    lock.lock(); defer { lock.unlock() }
    return passes
  }
}
#endif

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
    #if DEBUG
    // One increment per render sort pass (#530). The body builds this once;
    // re-deriving it N times per body (the pre-#521 churn) shows up as N.
    TranscriptSortProbe.recordSortPass()
    #endif
    // Shared transcript order (ts, id-tiebreak — `Message.transcriptPrecedes`):
    // the same comparator the request builder and the #513 retry truncation
    // use, so what renders and what "everything after this turn" deletes can
    // never disagree on timestamp ties.
    self.init(items: messages
      .sorted(by: Message.transcriptPrecedes)
      .map { ChatMessageItem($0) })
  }
}
