import XCTest
@testable import RatioThink

/// Coverage for the renderer's reasoning projection: a persisted
/// `Message.reasoning` must reach `ChatMessageItem` so `MessageBubble`
/// can show it in its collapsible Thinking section, distinct from the
/// visible `content`.
final class ChatMessageItemReasoningTests: XCTestCase {
  func test_item_lifts_reasoning_separately_from_content() {
    let message = Message(role: "assistant", content: "Hello!", reasoning: "the user said hi")
    let item = ChatMessageItem(message)
    XCTAssertEqual(item.role, .assistant)
    XCTAssertEqual(item.content, "Hello!")
    XCTAssertEqual(item.reasoning, "the user said hi")
    XCTAssertFalse(item.content.contains("the user said"),
                   "reasoning must not be folded into visible content")
  }

  func test_item_reasoning_defaults_empty_for_turns_without_thinking() {
    let item = ChatMessageItem(Message(role: "assistant", content: "plain"))
    XCTAssertTrue(item.reasoning.isEmpty)
  }
}
