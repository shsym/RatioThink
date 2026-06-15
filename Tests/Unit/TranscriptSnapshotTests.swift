import XCTest
@testable import RatioThink

@available(macOS 14, *)
final class TranscriptSnapshotTests: XCTestCase {
  private struct ProbeMessage {
    let id: UUID
    let role: ChatMessage.Role
    let content: String
    let reasoning: String
    let finishReason: String?
    let ts: Date
  }

  private final class Counter {
    var makeIteratorCalls = 0
    var projectionCalls = 0
  }

  private struct CountingMessages: Sequence {
    let rows: [ProbeMessage]
    let counter: Counter

    func makeIterator() -> IndexingIterator<[ProbeMessage]> {
      counter.makeIteratorCalls += 1
      return rows.makeIterator()
    }
  }

  func test_snapshot_sorts_projects_and_builds_scroll_key_once() {
    let firstID = UUID()
    let secondID = UUID()
    let thirdID = UUID()
    let rows = [
      ProbeMessage(id: secondID, role: .assistant, content: "middle", reasoning: "", finishReason: "stop", ts: Date(timeIntervalSince1970: 20)),
      ProbeMessage(id: thirdID, role: .system, content: "tail", reasoning: "", finishReason: nil, ts: Date(timeIntervalSince1970: 30)),
      ProbeMessage(id: firstID, role: .user, content: "head", reasoning: "", finishReason: nil, ts: Date(timeIntervalSince1970: 10)),
    ]

    let snapshot = TranscriptSnapshot(messages: rows, timestamp: { $0.ts }) { row in
      ChatMessageItem(
        id: row.id,
        role: row.role,
        content: row.content,
        reasoning: row.reasoning,
        finishReason: row.finishReason
      )
    }

    XCTAssertEqual(snapshot.items.map(\.id), [firstID, secondID, thirdID])
    XCTAssertEqual(snapshot.items.map(\.content), ["head", "middle", "tail"])
    XCTAssertEqual(snapshot.scrollKey, "3:14")
  }

  func test_snapshot_scroll_key_changes_when_reasoning_only_stream_grows() {
    let id = UUID()
    let first = TranscriptSnapshot(items: [
      ChatMessageItem(id: id, role: .assistant, content: "", reasoning: "think")
    ])
    let updated = TranscriptSnapshot(items: [
      ChatMessageItem(id: id, role: .assistant, content: "", reasoning: "thinking…")
    ])

    XCTAssertEqual(first.scrollKey, "1:5")
    XCTAssertEqual(updated.scrollKey, "1:9")
    XCTAssertNotEqual(first.scrollKey, updated.scrollKey)
  }

  func test_snapshot_traverses_source_and_projects_each_message_once() {
    let counter = Counter()
    let rows = (0..<200).map { index in
      ProbeMessage(
        id: UUID(),
        role: .assistant,
        content: String(repeating: "x", count: index % 7),
        reasoning: "",
        finishReason: nil,
        ts: Date(timeIntervalSince1970: TimeInterval(200 - index))
      )
    }

    _ = TranscriptSnapshot(messages: CountingMessages(rows: rows, counter: counter), timestamp: { $0.ts }) { row in
      counter.projectionCalls += 1
      return ChatMessageItem(id: row.id, role: row.role, content: row.content)
    }

    XCTAssertEqual(counter.makeIteratorCalls, 1)
    XCTAssertEqual(counter.projectionCalls, rows.count)
  }

  // #634 (GH #163): a chat switch rebuilds the scaffold and fires
  // TranscriptView.onAppear, which must jump to the bottom WITHOUT
  // animation — animating there replayed a scroll up from y=0 on every
  // switch. In-session content growth still animates.
  func test_scroll_animation_is_nil_on_appear_and_present_on_content_change() {
    XCTAssertNil(TranscriptView.scrollAnimation(animated: false))
    XCTAssertNotNil(TranscriptView.scrollAnimation(animated: true))
  }
}
