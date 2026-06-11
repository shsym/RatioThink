import XCTest
@testable import RatioThink

/// #513 review v2 F1 — the stale-retry notice must live on its own channel.
///
/// The first cut rode `engineActionError`, which renders through
/// `MissingModelRecovery.engineFailureBannerMessage` and is cleared by the
/// scaffold on the next engine-status flip. These tests pin the two channel
/// behaviors that made that wrong for a transcript-condition notice, so a
/// future "simplify by reusing the engine banner" change re-trips them:
/// while the engine is `.failed`, that channel SHADOWS any action error
/// behind `statusDetail` — the notice would never display — and on a
/// non-failed status it displays the action error verbatim only until the
/// next status change wipes it. The dedicated `StaleRetryNotice` row reads
/// `ChatScaffoldView.staleRetryNotice` state, which no engine-status code
/// path touches.
final class StaleRetryNoticeChannelTests: XCTestCase {
  func test_engine_failure_channel_shadows_action_errors_while_failed() {
    let message = MissingModelRecovery.engineFailureBannerMessage(
      engineStatus: .failed(code: .spawnFailed, message: "engine exploded"),
      actionError: ChatScaffoldView.staleRetryNoticeCopy,
      statusDetail: "engine exploded",
      hasDownloadTarget: false
    )
    XCTAssertEqual(message, "engine exploded",
                   "a .failed status owns the engine banner outright")
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
