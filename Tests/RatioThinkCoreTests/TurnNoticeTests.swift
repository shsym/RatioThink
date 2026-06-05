import XCTest
@testable import RatioThinkCore

/// #434: a finished assistant turn must NEVER render as a silent blank. A
/// thinking model can spend its whole `max_tokens` budget inside the
/// `<think>` phase and truncate (finish_reason "length") before emitting an
/// answer — the turn persists with empty content + full reasoning, and the
/// old renderer showed only the Thinking section, so the reply looked empty.
///
/// `TurnNotice.classify` maps (content, reasoning, finish_reason) to the
/// honest end-state the renderer surfaces. Pure + value-type so the full
/// state matrix is covered without a `ModelContainer` or a live engine.
final class TurnNoticeTests: XCTestCase {
  /// Streaming: no terminal chunk yet (finishReason == nil) → never a
  /// notice, so a freshly-inserted empty bubble can't flash a truncation
  /// warning mid-stream.
  func test_streaming_has_no_notice() {
    XCTAssertEqual(TurnNotice.classify(content: "", reasoning: "", finishReason: nil), .none)
    XCTAssertEqual(TurnNotice.classify(content: "", reasoning: "thinking…", finishReason: nil), .none)
    XCTAssertEqual(TurnNotice.classify(content: "partial", reasoning: "", finishReason: nil), .none)
  }

  /// Row 1 — a normal completed answer carries no notice, with or without
  /// a thinking block.
  func test_completed_answer_has_no_notice() {
    XCTAssertEqual(TurnNotice.classify(content: "Hello!", reasoning: "", finishReason: "stop"), .none)
    XCTAssertEqual(TurnNotice.classify(content: "Hello!", reasoning: "thought", finishReason: "stop"), .none)
  }

  /// Row 2 — truncated mid-answer (content present + "length"): keep the
  /// produced answer, attach a footnote inviting a higher limit.
  func test_length_with_content_is_partial_footnote() {
    let n = TurnNotice.classify(content: "Half an answ", reasoning: "thought", finishReason: "length")
    XCTAssertEqual(n, .truncatedPartial)
    XCTAssertTrue(n.isFootnote)
    XCTAssertEqual(n.message?.contains("Max tokens"), true)
  }

  /// Row 3 — THE BUG: the whole budget went to reasoning, no answer was
  /// produced. Stand-alone notice (not a footnote — there's no bubble).
  func test_length_after_thinking_no_answer() {
    let n = TurnNotice.classify(content: "", reasoning: "lots of thinking", finishReason: "length")
    XCTAssertEqual(n, .truncatedAfterThinking)
    XCTAssertFalse(n.isFootnote)
    XCTAssertEqual(
      n.message,
      "No answer — the model used its whole token budget thinking. Raise the Max tokens limit and ask again."
    )
  }

  /// Row 4 — truncated before any output at all (no reasoning, no answer).
  func test_length_no_output() {
    let n = TurnNotice.classify(content: "  ", reasoning: "", finishReason: "length")
    XCTAssertEqual(n, .truncatedNoOutput)
    XCTAssertEqual(n.message?.contains("Max tokens"), true)
  }

  /// Rows 5/6 — a clean stop (or any non-length reason) that produced no
  /// answer. Surface it instead of a blank bubble; not token-limit framed.
  func test_stop_without_answer() {
    XCTAssertEqual(TurnNotice.classify(content: "", reasoning: "thought", finishReason: "stop"), .finishedWithoutAnswer)
    XCTAssertEqual(TurnNotice.classify(content: "", reasoning: "", finishReason: "stop"), .finishedWithoutAnswer)
  }

  /// Cancel is handled by the send pipeline (partial content kept, empty
  /// rows deleted) — the renderer adds no notice on top.
  func test_cancelled_has_no_notice() {
    XCTAssertEqual(TurnNotice.classify(content: "", reasoning: "x", finishReason: "cancelled"), .none)
    XCTAssertEqual(TurnNotice.classify(content: "partial", reasoning: "", finishReason: "cancelled"), .none)
  }

  /// An unknown future finish_reason that produced no answer still gets a
  /// notice rather than a silent blank.
  func test_unknown_reason_without_answer_surfaces() {
    XCTAssertEqual(TurnNotice.classify(content: "", reasoning: "x", finishReason: "content_filter"), .finishedWithoutAnswer)
  }

  /// Whitespace-only content is "no answer", so a budget-exhausted thinking
  /// turn whose only "content" is a stray newline is row 3, not row 2.
  func test_whitespace_content_counts_as_empty() {
    XCTAssertEqual(TurnNotice.classify(content: "\n  \t", reasoning: "x", finishReason: "length"), .truncatedAfterThinking)
  }
}
