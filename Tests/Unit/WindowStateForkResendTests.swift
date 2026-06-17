import XCTest
@testable import RatioThink

/// #624 Issue 2 regression guard for the fork→resend handoff state machine.
/// `forkAndResend` arms the signal via `beginForkResend`; the freshly-mounted
/// scaffold's `.task` consumes it via `consumePendingForkResend`. The send is
/// gated on that consume returning `true`, so proving it returns `true`
/// exactly once is what proves the resend fires exactly once.
@MainActor
final class WindowStateForkResendTests: XCTestCase {
  func test_beginForkResend_arms_signal_and_navigates() {
    let state = WindowState()
    let target = UUID()
    state.selectedSection = .apiEndpoints

    state.beginForkResend(to: target)

    XCTAssertEqual(state.pendingForkResendChatID, target)
    XCTAssertEqual(state.selectedSection, .chats)
    XCTAssertEqual(state.selectedItemID, target)
  }

  func test_consume_fires_once_then_is_inert() {
    let state = WindowState()
    let target = UUID()
    state.beginForkResend(to: target)

    XCTAssertTrue(state.consumePendingForkResend(target),
                  "first consume for the armed chat must fire the resend")
    XCTAssertNil(state.pendingForkResendChatID, "consume must clear the one-shot flag")
    XCTAssertFalse(state.consumePendingForkResend(target),
                   "a second consume (re-mount) must NOT fire a duplicate resend")
  }

  func test_consume_ignores_a_non_armed_chat() {
    let state = WindowState()
    let armed = UUID()
    let other = UUID()
    state.beginForkResend(to: armed)

    XCTAssertFalse(state.consumePendingForkResend(other),
                   "a sibling/source scaffold must not consume another chat's signal")
    XCTAssertEqual(state.pendingForkResendChatID, armed,
                   "a non-matching consume must leave the signal intact for the real target")
  }
}
