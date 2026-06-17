import XCTest
import SwiftData
import SwiftUI
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

  // MARK: - #530 N-sorts discriminator (exact count, not timing)

  /// The render-projection seam sorts the transcript exactly ONCE per call —
  /// the #521 single-sort invariant, counted (`TranscriptSortProbe`) rather than
  /// timed. A regression that re-sorts inside the projection trips this.
  func test_render_projection_sorts_transcript_exactly_once() {
    let messages = (0..<50).map { i in
      Message(role: "user", content: "m\(i)", ts: Date(timeIntervalSince1970: TimeInterval(50 - i)))
    }
    TranscriptSortProbe.reset()
    let snapshot = TranscriptView.projectedSnapshot(messages)
    XCTAssertEqual(TranscriptSortProbe.sortPasses, 1,
                   "projectedSnapshot must perform exactly one transcript sort pass; got \(TranscriptSortProbe.sortPasses)")
    // #521's other half — render value rows, not @Model — is a type-level
    // guarantee of the seam: the projection yields `ChatMessageItem` values, so a
    // `ForEach` over `snapshot.items` can never iterate `@Model Message` rows.
    XCTAssertEqual(snapshot.items.count, messages.count)
    XCTAssert(type(of: snapshot.items) == [ChatMessageItem].self)
  }

  /// THE discriminator for acceptance #1: RENDERING `TranscriptView` once must
  /// build the transcript projection exactly ONCE. The pre-#521 pattern
  /// re-derived a re-sorting `sortedMessages` for the empty-check, the `ForEach`
  /// data source, the retry set and the scroll key — several sort passes per
  /// render. The fix binds one snapshot the whole body reuses.
  ///
  /// The view is hosted and laid out (not merely `.body`-accessed) because the
  /// pre-#521 re-derivations live inside the lazy view-builder closures, which a
  /// bare `.body` read never evaluates — so this drives the real render path and
  /// the count is robust to whether the retry/edit hooks are wired.
  @MainActor
  func test_transcript_view_render_projects_transcript_exactly_once() throws {
    let container = try RatioThinkModelContainer.makeInMemory()
    let context = container.mainContext
    let chat = Chat(title: "probe")
    context.insert(chat)
    for i in 0..<50 {
      chat.messages.append(
        Message(role: i.isMultiple(of: 2) ? "user" : "assistant",
                content: "m\(i)",
                ts: Date(timeIntervalSince1970: TimeInterval(i)))
      )
    }

    TranscriptSortProbe.reset()
    // Wire the retry/edit hooks so the retry-anchor projection is live too, then
    // force one real layout pass so the lazy ForEach/scroll-key/empty-check
    // closures actually evaluate.
    let view = TranscriptView(chat: chat, onRetryTurn: { _ in }, onEditUserTurn: { _, _ in })
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(x: 0, y: 0, width: 480, height: 640)
    host.layoutSubtreeIfNeeded()

    XCTAssertEqual(TranscriptSortProbe.sortPasses, 1,
                   "rendering TranscriptView must build the transcript projection exactly once; got "
                     + "\(TranscriptSortProbe.sortPasses) sort passes — the pre-#521 re-sort-per-access "
                     + "churn (or an equivalent N-sorts pattern) is back")
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
