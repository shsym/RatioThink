import XCTest
@testable import RatioThinkCore

@MainActor
final class ContextUsageTrackerTests: XCTestCase {
  func test_requestLifecycle_recordsActiveThenDestroyedWithoutUsageGuess() {
    let tracker = ContextUsageTracker(now: { Date(timeIntervalSince1970: 10) })
    let chatID = UUID()

    tracker.markRequestStarted(chatID: chatID, modelID: "m", requestID: "r1")
    var record = tracker.records.first
    XCTAssertEqual(record?.chatID, chatID)
    XCTAssertEqual(record?.modelID, "m")
    XCTAssertEqual(record?.requestID, "r1")
    XCTAssertEqual(record?.residency, .requestLocalActive)
    XCTAssertNil(record?.usage, "v1 has no page frame yet; do not estimate")

    tracker.markRequestFinished(chatID: chatID, modelID: "m", requestID: "r1")
    record = tracker.records.first
    XCTAssertEqual(record?.residency, .requestLocalDestroyed)
    XCTAssertNil(record?.usage)
  }

  func test_staleFinishForOldRequestIDIsIgnored() {
    var now = Date(timeIntervalSince1970: 1)
    let tracker = ContextUsageTracker(now: { now })
    let chatID = UUID()

    tracker.markRequestStarted(chatID: chatID, modelID: "m", requestID: "new")
    now = Date(timeIntervalSince1970: 2)
    tracker.markRequestFinished(chatID: chatID, modelID: "m", requestID: "old")

    XCTAssertEqual(tracker.records.first?.requestID, "new")
    XCTAssertEqual(tracker.records.first?.residency, .requestLocalActive)
    XCTAssertEqual(tracker.records.first?.lastUsedAt, Date(timeIntervalSince1970: 1))
  }

  func test_modelSwitchCreatesDistinctRecordKey() {
    let chatID = UUID()
    let tracker = ContextUsageTracker(now: { Date(timeIntervalSince1970: 1) })
    tracker.markRequestStarted(chatID: chatID, modelID: "a", requestID: "ra")
    tracker.markRequestStarted(chatID: chatID, modelID: "b", requestID: "rb")

    XCTAssertEqual(Set(tracker.records.map(\.modelID)), ["a", "b"])
  }
}
