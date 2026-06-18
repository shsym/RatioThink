import Combine
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

  func test_markUsage_populatesRecordAndBothReaderSeams() {
    let chatID = UUID()
    let tracker = ContextUsageTracker(now: { Date(timeIntervalSince1970: 1) })
    tracker.markRequestStarted(chatID: chatID, modelID: "m", requestID: "r1")

    let usage = ContextUsage(usedTokens: 1200, windowTokens: 4096)
    tracker.markUsage(chatID: chatID, modelID: "m", requestID: "r1", usage: usage)

    XCTAssertEqual(tracker.records.first?.usage, usage)
    // The reader seams: the per-chat meter value and the model-global window.
    XCTAssertEqual(tracker.latestUsage(chatID: chatID), usage)
    XCTAssertEqual(tracker.latestWindow, 4096)
    // Usage alone must not flip residency — the finish defer owns that.
    XCTAssertEqual(tracker.records.first?.residency, .requestLocalActive)
  }

  func test_markUsage_forUnknownRequestIsIgnored() {
    let chatID = UUID()
    let tracker = ContextUsageTracker(now: { Date(timeIntervalSince1970: 1) })
    tracker.markRequestStarted(chatID: chatID, modelID: "m", requestID: "r1")

    tracker.markUsage(chatID: chatID, modelID: "m", requestID: "stale",
                      usage: ContextUsage(usedTokens: 9, windowTokens: 9))

    XCTAssertNil(tracker.records.first?.usage,
                 "a usage frame for a superseded/unknown request must not write onto a live record")
    XCTAssertNil(tracker.latestUsage(chatID: chatID))
    XCTAssertNil(tracker.latestWindow)
  }

  // MARK: - model-load zero-state (#711 follow-up)

  func test_seedFromModelLoad_computesEngineTrueWindowAndShowsZeroState() {
    let tracker = ContextUsageTracker(now: { Date(timeIntervalSince1970: 1) })
    let chatID = UUID()

    // No turn yet: window = kv_pages_total × tokens_per_page, used = 0.
    tracker.seedFromModelLoad(modelID: "m", pagesTotal: 256, tokensPerPage: 32)

    XCTAssertEqual(tracker.loadedModelID, "m")
    XCTAssertEqual(tracker.loadedWindow, 8192)
    XCTAssertEqual(tracker.latestWindow, 8192, "settings reads the seeded window with no turn")
    XCTAssertEqual(tracker.meterUsage(chatID: chatID), ContextUsage(usedTokens: 0, windowTokens: 8192))
  }

  func test_seedFromModelLoad_residentButUnreadablePagesShowsZeroWithUnknownWindow() {
    let tracker = ContextUsageTracker(now: { Date(timeIntervalSince1970: 1) })
    let chatID = UUID()

    // A model is resident but its KV-page total hasn't been polled yet.
    tracker.seedFromModelLoad(modelID: "m", pagesTotal: nil, tokensPerPage: 32)

    XCTAssertEqual(tracker.loadedModelID, "m")
    XCTAssertNil(tracker.loadedWindow)
    // Meter is visible (model loaded) but indeterminate — NOT hidden.
    XCTAssertEqual(tracker.meterUsage(chatID: chatID), ContextUsage(usedTokens: 0, windowTokens: nil))
  }

  func test_seedFromModelLoad_noResidentModelHidesMeter() {
    let tracker = ContextUsageTracker(now: { Date(timeIntervalSince1970: 1) })
    tracker.seedFromModelLoad(modelID: "m", pagesTotal: 256, tokensPerPage: 32)

    tracker.seedFromModelLoad(modelID: nil, pagesTotal: nil, tokensPerPage: nil)

    XCTAssertNil(tracker.loadedModelID)
    XCTAssertNil(tracker.loadedWindow)
    XCTAssertNil(tracker.meterUsage(chatID: UUID()), "no resident model → meter hidden")
  }

  func test_seedLoadedModel_sameModelUnchangedWindowDoesNotChurn() {
    let tracker = ContextUsageTracker(now: { Date(timeIntervalSince1970: 1) })
    tracker.seedFromModelLoad(modelID: "m", pagesTotal: 256, tokensPerPage: 32)
    var ticks = 0
    let c = tracker.objectWillChange.sink { _ in ticks += 1 }
    defer { c.cancel() }

    // Re-seed the SAME model + window repeatedly (mirrors the KV poll firing).
    tracker.seedFromModelLoad(modelID: "m", pagesTotal: 256, tokensPerPage: 32)
    tracker.seedFromModelLoad(modelID: "m", pagesTotal: 256, tokensPerPage: 32)

    XCTAssertEqual(ticks, 0, "an unchanged window must not republish on every poll tick")
  }

  func test_liveTurnUsageOverridesZeroState() {
    let tracker = ContextUsageTracker(now: { Date(timeIntervalSince1970: 1) })
    let chatID = UUID()
    tracker.seedFromModelLoad(modelID: "m", pagesTotal: 256, tokensPerPage: 32)

    tracker.markRequestStarted(chatID: chatID, modelID: "m", requestID: "r1")
    tracker.markUsage(chatID: chatID, modelID: "m", requestID: "r1",
                      usage: ContextUsage(usedTokens: 1000, windowTokens: 8192))

    XCTAssertEqual(tracker.meterUsage(chatID: chatID),
                   ContextUsage(usedTokens: 1000, windowTokens: 8192),
                   "a real turn's usage replaces the 0/window zero-state")
  }

  func test_markUsage_fillsMissingWindowFromSeed() {
    // The ToT/Best-of-N paths omit the window in the frame; the tracker fills
    // it from the model-load seed so the fraction still renders.
    let tracker = ContextUsageTracker(now: { Date(timeIntervalSince1970: 1) })
    let chatID = UUID()
    tracker.seedFromModelLoad(modelID: "m", pagesTotal: 256, tokensPerPage: 32)

    tracker.markRequestStarted(chatID: chatID, modelID: "m", requestID: "r1")
    tracker.markUsage(chatID: chatID, modelID: "m", requestID: "r1",
                      usage: ContextUsage(usedTokens: 1500, windowTokens: nil))

    XCTAssertEqual(tracker.latestUsage(chatID: chatID),
                   ContextUsage(usedTokens: 1500, windowTokens: 8192))
  }

  func test_latestUsage_and_latestWindow_followMostRecentReportingRecord() {
    var tick: TimeInterval = 1
    let chatID = UUID()
    let tracker = ContextUsageTracker(now: { Date(timeIntervalSince1970: tick) })

    tracker.markRequestStarted(chatID: chatID, modelID: "m", requestID: "r1")
    tracker.markUsage(chatID: chatID, modelID: "m", requestID: "r1",
                      usage: ContextUsage(usedTokens: 100, windowTokens: 4096))
    tick = 5
    tracker.markRequestStarted(chatID: chatID, modelID: "m", requestID: "r2")
    tracker.markUsage(chatID: chatID, modelID: "m", requestID: "r2",
                      usage: ContextUsage(usedTokens: 300, windowTokens: 4096))

    // Newest reporting record wins for the chat meter.
    XCTAssertEqual(tracker.latestUsage(chatID: chatID),
                   ContextUsage(usedTokens: 300, windowTokens: 4096))
    XCTAssertEqual(tracker.latestWindow, 4096)
    // A different chat has no usage of its own.
    XCTAssertNil(tracker.latestUsage(chatID: UUID()))
  }
}
