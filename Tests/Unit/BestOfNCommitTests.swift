import XCTest
@testable import RatioThink

/// #708 review v5 F1: the Best-of-N commit path (`Use this` / think-more) must
/// surface a save failure and must NOT discard recovery state (candidate
/// snapshot release) before the chosen answer is durable. `commitBestOfNAnswer`
/// is the shared core so `.stop` and `.thinkMore` cannot diverge;
/// `performBestOfNStop` gates the release on a successful save. Both take
/// injected `save`/`report`/`releaseSnapshots` closures so the failure path is
/// deterministically testable without a View or a real store rejection.
@MainActor
final class BestOfNCommitTests: XCTestCase {
  private struct SaveError: Error {}

  func test_commit_success_sets_content_returns_true_no_report() {
    let message = Message(role: "assistant", content: "")
    var reported: Error?
    let ok = ChatScaffoldView.commitBestOfNAnswer(
      "the chosen answer", on: message, save: {}, report: { reported = $0 })
    XCTAssertTrue(ok)
    XCTAssertEqual(message.content, "the chosen answer")
    XCTAssertNil(reported, "a successful commit reports nothing")
  }

  func test_commit_failure_returns_false_and_reports() {
    let message = Message(role: "assistant", content: "")
    var reported: Error?
    let ok = ChatScaffoldView.commitBestOfNAnswer(
      "the chosen answer", on: message, save: { throw SaveError() }, report: { reported = $0 })
    XCTAssertFalse(ok, "a rejected save must be observable, not swallowed")
    XCTAssertTrue(reported is SaveError, "the save failure must be reported to PersistenceStatus")
  }

  func test_stop_releases_snapshots_after_durable_save() {
    let message = Message(role: "assistant", content: "")
    var released = false
    ChatScaffoldView.performBestOfNStop(
      text: "answer", on: message, save: {}, report: { _ in },
      releaseSnapshots: { released = true })
    XCTAssertEqual(message.content, "answer")
    XCTAssertTrue(released, "Use this releases the candidate snapshots once the answer is durable")
  }

  func test_stop_does_not_release_snapshots_when_save_fails() {
    let message = Message(role: "assistant", content: "")
    var reported: Error?
    var released = false
    ChatScaffoldView.performBestOfNStop(
      text: "answer", on: message, save: { throw SaveError() },
      report: { reported = $0 }, releaseSnapshots: { released = true })
    XCTAssertTrue(reported is SaveError, "a failed Use this save must be reported")
    XCTAssertFalse(released,
                   "candidate snapshots must NOT be released before the answer is durable — "
                     + "discarding recovery state on a failed save could lose the selected answer")
  }
}
