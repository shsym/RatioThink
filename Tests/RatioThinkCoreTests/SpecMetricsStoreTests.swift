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

  // MARK: - corrupt-load quarantine (#625)

  /// Seed a valid multi-profile file, then ensure a clean load raises no
  /// diagnostic and leaves the file untouched.
  func test_valid_file_loads_without_diagnostic() {
    let seed = SpecMetricsStore(fileURL: fileURL)
    seed.record(drafted(10, 8), forProfileID: "a")
    seed.record(drafted(10, 6), forProfileID: "b")

    let reloaded = SpecMetricsStore(fileURL: fileURL)
    XCTAssertNil(reloaded.loadDiagnostic)
    XCTAssertEqual(reloaded.aggregate(forProfileID: "a")?.lastAcceptRatio, 0.8)
    XCTAssertEqual(reloaded.aggregate(forProfileID: "b")?.lastAcceptRatio, 0.6)
  }

  /// An absent file is the legitimate unset state — empty, no diagnostic.
  func test_absent_file_loads_clean() {
    let store = SpecMetricsStore(fileURL: fileURL)
    XCTAssertNil(store.loadDiagnostic)
    XCTAssertNil(store.aggregate(forProfileID: "any"))
  }

  /// The core bug: a corrupt file must NOT load as empty and then get
  /// silently overwritten on the next write. It is quarantined and signaled.
  func test_corrupt_file_is_quarantined_and_signaled() throws {
    try Data("{ this is not valid json".utf8).write(to: fileURL)

    let store = SpecMetricsStore(fileURL: fileURL)

    let quarantine = SpecMetricsStore.quarantineURL(for: fileURL)
    guard case let .quarantined(corrupt, moved)? = store.loadDiagnostic else {
      return XCTFail("expected a quarantine diagnostic, got \(String(describing: store.loadDiagnostic))")
    }
    XCTAssertEqual(corrupt, fileURL)
    XCTAssertEqual(moved, quarantine)
    XCTAssertNil(store.aggregate(forProfileID: "any"))
    // Corrupt bytes were moved aside, not left at the canonical path.
    XCTAssertTrue(FileManager.default.fileExists(atPath: quarantine.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    try? FileManager.default.removeItem(at: quarantine)
  }

  /// Quarantine preserves the exact corrupt bytes for manual recovery.
  func test_quarantine_preserves_corrupt_bytes() throws {
    let corruptBytes = Data("\u{0}\u{1}garbage-not-json".utf8)
    try corruptBytes.write(to: fileURL)

    _ = SpecMetricsStore(fileURL: fileURL)

    let quarantine = SpecMetricsStore.quarantineURL(for: fileURL)
    XCTAssertEqual(try Data(contentsOf: quarantine), corruptBytes)
    try? FileManager.default.removeItem(at: quarantine)
  }

  /// After quarantine, persistence resumes against the freed canonical path,
  /// so this session's telemetry is saved and reloads cleanly.
  func test_record_after_quarantine_persists_fresh_canonical() throws {
    try Data("not json".utf8).write(to: fileURL)

    let store = SpecMetricsStore(fileURL: fileURL)
    store.record(drafted(10, 9), forProfileID: "fast-think")

    let reloaded = SpecMetricsStore(fileURL: fileURL)
    XCTAssertNil(reloaded.loadDiagnostic, "the freshly written file is valid")
    XCTAssertEqual(reloaded.aggregate(forProfileID: "fast-think")?.lastAcceptRatio, 0.9)
    try? FileManager.default.removeItem(at: SpecMetricsStore.quarantineURL(for: fileURL))
  }

  /// A present-but-UNREADABLE file is not proven corrupt, so it must NOT be
  /// quarantined (#633) — moving bytes that might be valid would destroy real
  /// telemetry. It is left in place and persistence is disabled so the next
  /// write can't overwrite it. A real file with read permission stripped
  /// (mode 000) stands in for the read failure: it "exists" but
  /// `Data(contentsOf:)` throws EACCES, while the canonical path stays
  /// WRITABLE so a wrongly re-enabled `persist()` would visibly overwrite it.
  func test_present_but_unreadable_file_is_preserved_not_quarantined() throws {
    let original = Data("{ valid-bytes-we-just-can't-read".utf8)
    try original.write(to: fileURL)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o000], ofItemAtPath: fileURL.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
    }

    let store = SpecMetricsStore(fileURL: fileURL)
    XCTAssertEqual(store.loadDiagnostic, .unreadablePersistenceDisabled(fileURL))
    XCTAssertNil(store.aggregate(forProfileID: "any"))
    // Read failure is NOT corruption — nothing is moved aside.
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: SpecMetricsStore.quarantineURL(for: fileURL).path))

    // record() must NOT write — persistence is disabled. This discriminates:
    // a wrongly re-enabled persist() does an atomic write that renames over
    // the (writable-dir) canonical path, replacing these bytes with fresh
    // JSON. Restoring read access and comparing proves no such write ran.
    store.record(drafted(10, 9), forProfileID: "p")
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
    XCTAssertEqual(try Data(contentsOf: fileURL), original,
                   "persistence is disabled; the unreadable bytes must survive untouched")
  }

  /// When a corrupt file can't be moved aside, persistence is DISABLED so the
  /// bytes are never overwritten — the riskier half of the #625 fix: if a
  /// later change let `persist()` run after a failed move, the silent wipe
  /// returns. The `fileManager:` seam exists to reach this branch.
  func test_corrupt_file_unmovable_disables_persistence_and_preserves_bytes() throws {
    let corruptBytes = Data("{ unmovable corrupt".utf8)
    try corruptBytes.write(to: fileURL)

    let store = SpecMetricsStore(fileURL: fileURL, fileManager: MoveFailingFileManager())
    XCTAssertEqual(store.loadDiagnostic, .corruptPersistenceDisabled(fileURL))
    XCTAssertNil(store.aggregate(forProfileID: "any"))
    // Move failed → bytes stay at the canonical path, nothing quarantined.
    XCTAssertEqual(try Data(contentsOf: fileURL), corruptBytes)
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: SpecMetricsStore.quarantineURL(for: fileURL).path))

    // A record() must NOT overwrite the preserved corrupt bytes.
    store.record(drafted(10, 9), forProfileID: "fast-think")
    XCTAssertEqual(try Data(contentsOf: fileURL), corruptBytes,
                   "persistence is disabled; the corrupt file must survive untouched")

    // A fresh store over the same file still sees a corrupt (quarantine)
    // outcome — proof the bytes were never destroyed.
    let reloaded = SpecMetricsStore(fileURL: fileURL)
    guard case .quarantined? = reloaded.loadDiagnostic else {
      return XCTFail("expected the surviving corrupt bytes to quarantine on a clean reload")
    }
    try? FileManager.default.removeItem(at: SpecMetricsStore.quarantineURL(for: fileURL))
  }

  /// TOCTOU: the file passes `fileExists` but is gone by the time the read
  /// runs (deleted between the check and the load). That is a read failure,
  /// not corruption (#633) — degrade to in-memory, quarantine nothing, and
  /// create nothing, so a later run retries cleanly.
  func test_source_gone_after_fileExists_degrades_without_quarantine() {
    // The path holds no file; a FileManager that claims it exists forces the
    // read to run and throw, standing in for the delete-after-check race.
    let store = SpecMetricsStore(fileURL: fileURL, fileManager: ClaimsExistsFileManager())

    XCTAssertEqual(store.loadDiagnostic, .unreadablePersistenceDisabled(fileURL))
    XCTAssertNil(store.aggregate(forProfileID: "any"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path),
                   "a vanished source must not be recreated")
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: SpecMetricsStore.quarantineURL(for: fileURL).path),
                   "a read failure must never quarantine")
  }
}

/// A `FileManager` whose `moveItem` always throws, to exercise the
/// quarantine move-failure branch (persistence disabled, bytes preserved).
private final class MoveFailingFileManager: FileManager {
  override func moveItem(at srcURL: URL, to dstURL: URL) throws {
    throw CocoaError(.fileWriteNoPermission)
  }
}

/// A `FileManager` that always reports a path exists, to drive the
/// read-after-`fileExists`-but-source-gone branch (#633): the existence
/// check passes, then `Data(contentsOf:)` (which doesn't consult the
/// injected manager) throws because no file is actually there.
private final class ClaimsExistsFileManager: FileManager {
  override func fileExists(atPath path: String) -> Bool { true }
}
