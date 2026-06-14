import XCTest
@testable import RatioThink

/// #513 review v2 F1 — the stale-retry notice must live on its own channel.
///
/// The first cut rode `engineActionError`, which renders through
/// `MissingModelRecovery.engineActionFailureBannerMessage` and is cleared by
/// the scaffold on the next engine-status flip. These tests pin the channel
/// behavior that made that wrong for a transcript-condition notice, so a
/// future "simplify by reusing the engine banner" change re-trips it: while
/// the engine is `.failed`, that channel is hidden because the unified status
/// banner owns the live failure, so the notice would never display. The
/// dedicated `StaleRetryNotice` row reads `ChatScaffoldView.staleRetryNotice`
/// state, which no engine-status code path touches.
final class StaleRetryNoticeChannelTests: XCTestCase {
  func test_engine_failure_channel_hides_action_errors_while_failed() {
    let message = MissingModelRecovery.engineActionFailureBannerMessage(
      engineStatus: .failed(code: .spawnFailed, message: "engine exploded"),
      actionError: ChatScaffoldView.staleRetryNoticeCopy
    )
    XCTAssertNil(message,
                 "a .failed status is owned by the unified status banner, not the action-error banner")
    XCTAssertNotEqual(message, ChatScaffoldView.staleRetryNoticeCopy,
                      "the stale-retry notice would be invisible on this channel while the engine is .failed — it must render from its own state instead")
  }

  func test_notice_copy_names_both_stale_conditions() {
    // The copy must explain BOTH ways a retry click goes stale: the
    // transcript changed underneath, or a stream is (now) in flight.
    let copy = ChatScaffoldView.staleRetryNoticeCopy
    XCTAssertTrue(copy.contains("conversation changed"))
    XCTAssertTrue(copy.contains("response is in progress"))
  }
}
