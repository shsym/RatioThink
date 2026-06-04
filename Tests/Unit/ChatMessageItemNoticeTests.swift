import XCTest
@testable import RatioThink

/// #434: the renderer's projection must carry the engine `finish_reason` so
/// `MessageBubble` can surface a truncated-before-answer turn instead of a
/// silent blank. Guards the #329-class "projection silently drops a field"
/// regression (there, `reasoning` was received but dropped).
@available(macOS 14, *)
final class ChatMessageItemNoticeTests: XCTestCase {
  /// Mirrors `ChatSendController.finishMeta` — snake_case `finish_reason`.
  private func meta(_ reason: String) -> Data {
    try! JSONSerialization.data(withJSONObject: ["finish_reason": reason])
  }

  func test_item_lifts_finish_reason_from_message() {
    let m = Message(role: "assistant", content: "", reasoning: "thinking", meta: meta("length"))
    XCTAssertEqual(ChatMessageItem(m).finishReason, "length")
  }

  func test_streaming_turn_has_no_finish_reason_and_no_notice() {
    let item = ChatMessageItem(Message(role: "assistant", content: "", reasoning: "thinking…"))
    XCTAssertNil(item.finishReason)
    XCTAssertEqual(item.notice, .none)
  }

  /// The reported bug: budget spent thinking, no answer → a stand-alone
  /// notice, not a blank.
  func test_truncated_after_thinking_surfaces_notice() {
    let m = Message(role: "assistant", content: "", reasoning: "lots of thinking", meta: meta("length"))
    let item = ChatMessageItem(m)
    XCTAssertEqual(item.notice, .truncatedAfterThinking)
    XCTAssertNotNil(item.notice.message)
  }

  func test_normal_answer_has_no_notice() {
    let m = Message(role: "assistant", content: "Hello!", meta: meta("stop"))
    XCTAssertEqual(ChatMessageItem(m).notice, .none)
  }
}
