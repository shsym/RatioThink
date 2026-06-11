import XCTest
@testable import RatioThink

/// #515 — canonical copy actions for a rendered transcript turn.
///
/// MarkdownUI fragments one message into many selectable `Text` blocks,
/// so mouse selection can't span a whole rendered message. These tests
/// pin the deterministic copy path's boundary policy: what each role
/// offers, that answers never include reasoning, and that Markdown
/// source (code fences included) is copied verbatim.
final class MessageCopyPlanTests: XCTestCase {

  // MARK: role → offered actions

  func test_userMessage_offersCopyMessageWithFullContent() {
    let item = ChatMessageItem(role: .user, content: "line one\n\nline two")
    let plan = MessageCopyPlan.plan(for: item)
    XCTAssertEqual(plan.items.map(\.label), ["Copy Message"])
    XCTAssertEqual(plan.items[0].text, "line one\n\nline two")
  }

  func test_systemMessage_offersPlainCopy() {
    let item = ChatMessageItem(role: .system, content: "breadcrumb")
    let plan = MessageCopyPlan.plan(for: item)
    XCTAssertEqual(plan.items.map(\.label), ["Copy"])
    XCTAssertEqual(plan.items[0].text, "breadcrumb")
  }

  func test_assistantWithAnswerOnly_offersCopyAnswerOnly() {
    let item = ChatMessageItem(role: .assistant, content: "the answer")
    let plan = MessageCopyPlan.plan(for: item)
    XCTAssertEqual(plan.items.map(\.label), ["Copy Answer"])
    XCTAssertEqual(plan.items[0].text, "the answer")
  }

  // MARK: answer/thinking boundary

  func test_assistantWithReasoning_copyAnswerExcludesReasoning() {
    let item = ChatMessageItem(
      role: .assistant, content: "visible answer", reasoning: "hidden scratchpad")
    let plan = MessageCopyPlan.plan(for: item)
    XCTAssertEqual(plan.items.map(\.label), ["Copy Answer", "Copy Thinking"])
    XCTAssertEqual(plan.items[0].text, "visible answer")
    XCTAssertFalse(plan.items[0].text.contains("hidden scratchpad"))
    XCTAssertEqual(plan.items[1].text, "hidden scratchpad")
  }

  func test_assistantReasoningOnly_offersCopyThinkingOnly() {
    // A still-thinking (or truncated-before-answer) turn: no answer to copy
    // yet, but the reasoning is copyable.
    let item = ChatMessageItem(role: .assistant, content: "", reasoning: "thinking…")
    let plan = MessageCopyPlan.plan(for: item)
    XCTAssertEqual(plan.items.map(\.label), ["Copy Thinking"])
  }

  func test_emptyTurn_offersNothing() {
    let item = ChatMessageItem(role: .assistant, content: "")
    XCTAssertTrue(MessageCopyPlan.plan(for: item).items.isEmpty)
  }

  // MARK: canonical source fidelity

  func test_copyAnswer_preservesMarkdownSourceAcrossBlocks() {
    // Paragraphs, a list, a fenced code block, inline code, and a link —
    // exactly the shapes MarkdownUI splits into separate selectable
    // blocks. The copy must be the verbatim source spanning all of them.
    let source = """
      Intro paragraph.

      - item one
      - item two

      ```swift
      let x = 1 < 2
      ```

      Inline `code` and a [link](https://example.com).
      """
    let item = ChatMessageItem(role: .assistant, content: source)
    XCTAssertEqual(MessageCopyPlan.plan(for: item).items[0].text, source)
  }

  func test_streamingSnapshot_copyMatchesCommittedContentAtCopyTime() {
    // Mid-stream the item holds the committed prefix; the plan copies
    // exactly that — never more, never a torn string.
    var item = ChatMessageItem(role: .assistant, content: "partial ans")
    XCTAssertEqual(MessageCopyPlan.plan(for: item).items[0].text, "partial ans")
    item.content = "partial answer, now longer"
    XCTAssertEqual(
      MessageCopyPlan.plan(for: item).items[0].text, "partial answer, now longer")
  }
}
