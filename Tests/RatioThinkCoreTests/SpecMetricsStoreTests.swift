import XCTest
@testable import RatioThinkCore

/// Unit coverage for the #621 speculative-decode telemetry: the pure
/// aggregate fold + badge formatting, and the file-backed per-profile store.
@MainActor
final class SpecMetricsStoreTests: XCTestCase {
  private var fileURL: URL!

  override func setUpWithError() throws {
    fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("spec-metrics-\(UUID().uuidString).json", isDirectory: false)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: fileURL)
  }

  private func drafted(_ proposed: Int, _ accepted: Int, tokPerStep: Double = 2.0) -> SpecMetrics {
    SpecMetrics(
      enabled: true, generatedTokens: 30, decodeSteps: 12,
      proposedDraftTokens: proposed, acceptedDraftTokens: accepted,
      rejectedDraftTokens: proposed - accepted,
      avgTokensPerStep: tokPerStep, decodeTokensPerSec: 60, leaderLen: 1, draftLen: 4)
  }

  // MARK: - acceptRatio

  func test_acceptRatio_is_accepted_over_proposed() {
    XCTAssertEqual(drafted(20, 15).acceptRatio, 0.75)
  }

  func test_acceptRatio_nil_when_no_drafts_proposed() {
    // Drafting requested but inactive → no 0/0 that reads as "0% accept".
    let inactive = SpecMetrics(
      enabled: false, fallbackReason: "non_greedy_sampling",
      generatedTokens: 5, decodeSteps: 5, proposedDraftTokens: 0,
      acceptedDraftTokens: 0, rejectedDraftTokens: 0,
      avgTokensPerStep: 1, decodeTokensPerSec: 10, leaderLen: 0, draftLen: 0)
    XCTAssertNil(inactive.acceptRatio)
  }

  // MARK: - fold + averaging

  func test_folding_updates_last_and_running_average_over_drafted_runs() {
    let a = SpecMetricsAggregate.empty
      .folding(drafted(10, 8, tokPerStep: 2.0))   // 80%
      .folding(drafted(10, 6, tokPerStep: 4.0))   // 60%
    XCTAssertEqual(a.runCount, 2)
    XCTAssertEqual(a.draftedRunCount, 2)
    XCTAssertEqual(a.lastAcceptRatio, 0.6)            // most recent
    XCTAssertEqual(a.avgAcceptRatio!, 0.7, accuracy: 1e-9)   // mean(0.8, 0.6)
    XCTAssertEqual(a.avgTokensPerStep, 3.0, accuracy: 1e-9)  // mean(2, 4)
  }

  func test_folding_inactive_run_bumps_count_but_not_averages() {
    let inactive = SpecMetrics(
      enabled: false, fallbackReason: "non_greedy_sampling",
      generatedTokens: 1, decodeSteps: 1, proposedDraftTokens: 0,
      acceptedDraftTokens: 0, rejectedDraftTokens: 0,
      avgTokensPerStep: 1, decodeTokensPerSec: 9, leaderLen: 0, draftLen: 0)
    let a = SpecMetricsAggregate.empty
      .folding(drafted(10, 9))   // 90%
      .folding(inactive)
    XCTAssertEqual(a.runCount, 2)
    XCTAssertEqual(a.draftedRunCount, 1, "inactive run must not count toward the drafted average")
    XCTAssertNil(a.lastAcceptRatio, "last run was inactive")
    XCTAssertEqual(a.lastFallbackReason, "non_greedy_sampling")
    XCTAssertEqual(a.avgAcceptRatio, 0.9, "average reflects only the one drafted run")
  }

  // MARK: - badge copy

  func test_lastRunSummary_drafted() {
    let a = SpecMetricsAggregate.empty.folding(drafted(10, 8, tokPerStep: 2.45))
    XCTAssertEqual(a.lastRunSummary, "accept 80%, 2.5 tok/step")
  }

  func test_lastRunSummary_inactive_explains_why() {
    let inactive = SpecMetrics(
      enabled: false, fallbackReason: "non_greedy_sampling",
      generatedTokens: 1, decodeSteps: 1, proposedDraftTokens: 0,
      acceptedDraftTokens: 0, rejectedDraftTokens: 0,
      avgTokensPerStep: 1, decodeTokensPerSec: 9, leaderLen: 0, draftLen: 0)
    let a = SpecMetricsAggregate.empty.folding(inactive)
    XCTAssertEqual(a.lastRunSummary, "didn’t speculate (non-greedy sampling)")
  }

  func test_averageSummary_nil_until_two_drafted_runs() {
    let one = SpecMetricsAggregate.empty.folding(drafted(10, 8))
    XCTAssertNil(one.averageSummary, "a single run's average duplicates last run")
    let two = one.folding(drafted(10, 6))
    XCTAssertEqual(two.averageSummary, "accept 70%, 2.0 tok/step over 2 runs")
  }

  // MARK: - store + persistence

  func test_record_persists_and_reloads_per_profile() {
    let store = SpecMetricsStore(fileURL: fileURL)
    store.record(drafted(10, 8), forProfileID: "fast-think")
    store.record(drafted(10, 6), forProfileID: "fast-think")
    store.record(drafted(20, 5), forProfileID: "other")

    // A fresh store over the same file sees the persisted aggregates.
    let reloaded = SpecMetricsStore(fileURL: fileURL)
    let fast = reloaded.aggregate(forProfileID: "fast-think")
    XCTAssertEqual(fast?.runCount, 2)
    XCTAssertEqual(fast?.lastAcceptRatio, 0.6)
    XCTAssertEqual(reloaded.aggregate(forProfileID: "other")?.lastAcceptRatio, 0.25)
    XCTAssertNil(reloaded.aggregate(forProfileID: "unknown"))
  }

  func test_store_without_file_is_in_memory_only() {
    let store = SpecMetricsStore(fileURL: nil)
    store.record(drafted(10, 7), forProfileID: "p")
    XCTAssertEqual(store.aggregate(forProfileID: "p")?.lastAcceptRatio, 0.7)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
  }
}
