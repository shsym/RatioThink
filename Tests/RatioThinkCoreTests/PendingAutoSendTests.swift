import XCTest
@testable import RatioThinkCore

/// #516 — the pending-send state machine behind the chat send gate.
/// Covers the acceptance matrix: arm conditions, fire-once on the intended
/// model, hold across not-yet/failure, and disarm on every stale-context
/// path (chat switch, model/profile switch).
final class PendingAutoSendTests: XCTestCase {
  private let chatID = UUID()
  private let target = "org/model-a"

  private func armed() -> PendingAutoSend {
    PendingAutoSend.arm(chatID: chatID, targetModelID: target,
                        messageText: "hello world")!
  }

  // MARK: - arming

  func test_arms_with_message_and_target() {
    let p = PendingAutoSend.arm(chatID: chatID, targetModelID: target,
                                messageText: "  hello world \n")
    XCTAssertEqual(p?.chatID, chatID)
    XCTAssertEqual(p?.targetModelID, target)
    XCTAssertEqual(p?.messageText, "hello world", "draft is stored trimmed — the composer's edit guard compares trimmed text")
  }

  func test_does_not_arm_without_message() {
    // The launch-time engine-start prompt raises the gate with an empty
    // composer — nothing to promise, nothing to arm.
    XCTAssertNil(PendingAutoSend.arm(chatID: chatID, targetModelID: target, messageText: "   \n"))
  }

  func test_does_not_arm_without_target() {
    // `.noDefault` block: the gate offers Choose/Settings, not Load — there
    // is no specific model whose arrival should fire the send.
    XCTAssertNil(PendingAutoSend.arm(chatID: chatID, targetModelID: nil, messageText: "hi"))
    XCTAssertNil(PendingAutoSend.arm(chatID: chatID, targetModelID: "", messageText: "hi"))
  }

  // MARK: - verdicts

  func test_fires_when_intended_model_resolves_for_same_chat() {
    XCTAssertEqual(armed().verdict(chatID: chatID, resolvedModelID: target, isSending: false), .fire)
  }

  func test_holds_while_nothing_resolves() {
    // Engine still starting, model still loading — and the load-FAILURE
    // case (nothing resolvable) also lands here: stay armed so a retry
    // that succeeds still delivers the message.
    XCTAssertEqual(armed().verdict(chatID: chatID, resolvedModelID: nil, isSending: false), .hold)
    XCTAssertEqual(armed().verdict(chatID: chatID, resolvedModelID: "", isSending: false), .hold)
  }

  func test_disarms_when_a_different_model_resolves() {
    // The user switched model/profile mid-load; the gate's promise is stale.
    XCTAssertEqual(armed().verdict(chatID: chatID, resolvedModelID: "org/model-b", isSending: false), .disarm)
  }

  func test_disarms_on_chat_mismatch_even_for_the_intended_model() {
    XCTAssertEqual(armed().verdict(chatID: UUID(), resolvedModelID: target, isSending: false), .disarm)
  }

  // MARK: - review v1 F2: fire defers while a send is in flight

  func test_holds_while_a_send_is_in_flight_then_fires_when_clear() {
    // The composer's submit() bails on its !isSending guard — a fire
    // delivered mid-flight would be silently swallowed with the pending
    // already cleared. The verdict must hold instead, and fire on the
    // re-evaluation once in-flight clears.
    let p = armed()
    XCTAssertEqual(p.verdict(chatID: chatID, resolvedModelID: target, isSending: true), .hold,
                   "fire must defer while a send is in flight")
    XCTAssertEqual(p.verdict(chatID: chatID, resolvedModelID: target, isSending: false), .fire,
                   "deferred fire must deliver once in-flight clears")
  }

  func test_stale_context_still_disarms_while_in_flight() {
    // Staleness wins over deferral: a wrong model/chat must not stay armed
    // just because a send happens to be streaming.
    XCTAssertEqual(armed().verdict(chatID: chatID, resolvedModelID: "org/model-b", isSending: true), .disarm)
    XCTAssertEqual(armed().verdict(chatID: UUID(), resolvedModelID: target, isSending: true), .disarm)
  }
}
