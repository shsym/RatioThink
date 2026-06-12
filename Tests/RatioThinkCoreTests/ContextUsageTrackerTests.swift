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

  func test_sameChatSameModelSuccessiveRequestsProduceDistinctRecords() {
    var tick: TimeInterval = 1
    let tracker = ContextUsageTracker(now: { Date(timeIntervalSince1970: tick) })
    let chatID = UUID()

    tracker.markRequestStarted(chatID: chatID, modelID: "m", requestID: "r1")
    tick = 2
    tracker.markRequestFinished(chatID: chatID, modelID: "m", requestID: "r1")
    tick = 3
    tracker.markRequestStarted(chatID: chatID, modelID: "m", requestID: "r2")

    XCTAssertEqual(tracker.records.map(\.requestID), ["r2", "r1"])
    XCTAssertEqual(tracker.records.map(\.residency), [.requestLocalActive, .requestLocalDestroyed])
    XCTAssertEqual(Set(tracker.records.map(\.id)), [
      ContextUsageID(chatID: chatID, modelID: "m", requestID: "r1"),
      ContextUsageID(chatID: chatID, modelID: "m", requestID: "r2"),
    ])
    XCTAssertTrue(tracker.records.allSatisfy { $0.usage == nil })
  }

  func test_staleFinishForPriorRequestDoesNotMutateNewerSameModelRecord() {
    var tick: TimeInterval = 1
    let tracker = ContextUsageTracker(now: { Date(timeIntervalSince1970: tick) })
    let chatID = UUID()

    tracker.markRequestStarted(chatID: chatID, modelID: "m", requestID: "r1")
    tick = 2
    tracker.markRequestStarted(chatID: chatID, modelID: "m", requestID: "r2")
    tick = 3
    tracker.markRequestFinished(chatID: chatID, modelID: "m", requestID: "r1")
    tick = 4
    tracker.markRequestFinished(chatID: chatID, modelID: "m", requestID: "missing")

    XCTAssertEqual(tracker.records.map(\.requestID), ["r1", "r2"])
    XCTAssertEqual(tracker.records.map(\.residency), [.requestLocalDestroyed, .requestLocalActive])
    XCTAssertEqual(
      tracker.records.first(where: { $0.requestID == "r2" })?.lastUsedAt,
      Date(timeIntervalSince1970: 2)
    )
  }

  func test_modelSwitchCreatesDistinctRecordKey() {
    let chatID = UUID()
    let tracker = ContextUsageTracker(now: { Date(timeIntervalSince1970: 1) })
    tracker.markRequestStarted(chatID: chatID, modelID: "a", requestID: "ra")
    tracker.markRequestStarted(chatID: chatID, modelID: "b", requestID: "rb")

    XCTAssertEqual(Set(tracker.records.map(\.modelID)), ["a", "b"])
  }
}
