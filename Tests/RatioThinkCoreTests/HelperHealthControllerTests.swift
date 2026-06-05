import XCTest
@testable import RatioThinkCore

/// Unit tests for `HelperHealthController` — the @MainActor owner of the
/// App-side helper-restart ladder (#412). Drives poll outcomes through the
/// controller with a fake repair seam (no ServiceManagement) and asserts the
/// published `HelperHealth` plus that the repair fires exactly when the pure
/// reducer says to and never overlaps.
@MainActor
final class HelperHealthControllerTests: XCTestCase {

  private let tiny = HelperHealthPolicy(transientThreshold: 2, maxRepairAttempts: 2, repairGap: 2)

  // MARK: - happy recovery

  func test_sustainedFailure_firesRepair_recoversWhenReachable() async {
    let fake = ScriptedRepair([true]) // first reconcile restores reachability
    let c = HelperHealthController(policy: tiny, repair: { await fake.run() })

    c.ingestPollOutcome(succeeded: false)
    XCTAssertEqual(c.health, .reconnecting(consecutiveFailures: 1))
    c.ingestPollOutcome(succeeded: false)
    XCTAssertEqual(c.health, .repairing(attempt: 1), "crossing the transient window starts repair attempt 1")

    await c.awaitRepairForTesting()
    XCTAssertEqual(c.health, .healthy, "a reachable repair returns the helper to healthy")
    XCTAssertEqual(fake.calls, 1)
  }

  func test_healthy_pollSuccess_keepsHealthy_noRepair() async {
    let fake = ScriptedRepair([])
    let c = HelperHealthController(policy: tiny, repair: { await fake.run() })
    for _ in 0..<5 { c.ingestPollOutcome(succeeded: true) }
    XCTAssertEqual(c.health, .healthy)
    XCTAssertEqual(fake.calls, 0, "a reachable helper must never trigger a repair")
  }

  func test_transientBlip_recoversWithoutRepair() async {
    let fake = ScriptedRepair([])
    let c = HelperHealthController(policy: tiny, repair: { await fake.run() })
    c.ingestPollOutcome(succeeded: false)  // reconnecting(1) — below threshold 2
    c.ingestPollOutcome(succeeded: true)   // recovered
    XCTAssertEqual(c.health, .healthy)
    XCTAssertEqual(fake.calls, 0, "a blip inside the transient window must not fire a repair")
  }

  // MARK: - exhaustion

  func test_repairLadderExhausts_toUnreachable() async {
    let fake = ScriptedRepair([false, false]) // every reconcile fails
    let c = HelperHealthController(policy: tiny, repair: { await fake.run() })

    c.ingestPollOutcome(succeeded: false)  // reconnecting(1)
    c.ingestPollOutcome(succeeded: false)  // repairing(1)
    await c.awaitRepairForTesting()
    XCTAssertEqual(c.health, .repairCoolingDown(attempt: 1, failuresSinceRepair: 0))

    c.ingestPollOutcome(succeeded: false)  // coolingDown(1,1)
    c.ingestPollOutcome(succeeded: false)  // repairing(2)
    XCTAssertEqual(c.health, .repairing(attempt: 2))
    await c.awaitRepairForTesting()
    XCTAssertEqual(c.health, .unreachable, "the last failed attempt escalates to unreachable")
    XCTAssertEqual(fake.calls, 2)
  }

  func test_recoversOnLivePoll_evenAfterUnreachable() async {
    let fake = ScriptedRepair([false, false])
    let c = HelperHealthController(policy: tiny, repair: { await fake.run() })
    c.ingestPollOutcome(succeeded: false)
    c.ingestPollOutcome(succeeded: false)
    await c.awaitRepairForTesting()
    c.ingestPollOutcome(succeeded: false)
    c.ingestPollOutcome(succeeded: false)
    await c.awaitRepairForTesting()
    XCTAssertEqual(c.health, .unreachable)
    // launchd finally brings the helper back; a single reachable poll recovers.
    c.ingestPollOutcome(succeeded: true)
    XCTAssertEqual(c.health, .healthy)
  }

  // MARK: - manual restart

  func test_manualRestart_firesRepairImmediately() async {
    let fake = ScriptedRepair([true])
    let c = HelperHealthController(policy: tiny, repair: { await fake.run() })
    c.restartHelperManually()
    XCTAssertEqual(c.health, .repairing(attempt: 1), "Restart Helper fires a fresh attempt regardless of prior state")
    await c.awaitRepairForTesting()
    XCTAssertEqual(c.health, .healthy)
    XCTAssertEqual(fake.calls, 1)
  }

  // MARK: - no overlap

  func test_failedPollsDuringInFlightRepair_doNotSpawnAnotherRepair() async {
    let gate = GatedRepair()
    let c = HelperHealthController(
      policy: HelperHealthPolicy(transientThreshold: 2, maxRepairAttempts: 3, repairGap: 2),
      repair: { await gate.run() }
    )
    c.ingestPollOutcome(succeeded: false)  // reconnecting(1)
    c.ingestPollOutcome(succeeded: false)  // repairing(1) → spawns repair, which parks in the gate

    // Let the in-flight repair Task reach the gate.
    for _ in 0..<200 where gate.pending == 0 { await Task.yield() }
    XCTAssertEqual(gate.pending, 1)
    XCTAssertEqual(c.health, .repairing(attempt: 1))

    // Failed polls WHILE a reconcile is in flight must not spawn a second.
    c.ingestPollOutcome(succeeded: false)
    c.ingestPollOutcome(succeeded: false)
    XCTAssertEqual(c.health, .repairing(attempt: 1), "stays repairing — no overlap")
    XCTAssertEqual(gate.calls, 1, "exactly one reconcile in flight")

    gate.release(returning: true)
    await c.awaitRepairForTesting()
    XCTAssertEqual(c.health, .healthy)
  }

  // MARK: - generation gate (#413)

  func test_generationGate_holdsFailedPolls_noRepair() async {
    let fake = ScriptedRepair([])
    let c = HelperHealthController(policy: tiny, repair: { await fake.run() })
    c.setGenerating(true)
    // Far past transientThreshold (2): a long ToT search saturates the poll
    // path so many polls time out. Without the gate this bounces the engine
    // mid-stream (#413).
    for _ in 0..<10 { c.ingestPollOutcome(succeeded: false) }
    XCTAssertEqual(c.health, .healthy, "a streaming generation holds busy-timeout polls — no false reconnecting/repair")
    XCTAssertEqual(fake.calls, 0, "the restart ladder must not reconcile (bounce the helper) mid-stream")
  }

  func test_generationGate_successPollStillRecovers() async {
    let fake = ScriptedRepair([])
    let c = HelperHealthController(policy: tiny, repair: { await fake.run() })
    c.ingestPollOutcome(succeeded: false)  // reconnecting(1), before the stream
    XCTAssertEqual(c.health, .reconnecting(consecutiveFailures: 1))
    c.setGenerating(true)
    c.ingestPollOutcome(succeeded: true)   // success is never gated
    XCTAssertEqual(c.health, .healthy, "a live successful poll recovers even mid-generation")
    XCTAssertEqual(fake.calls, 0)
  }

  func test_generationGate_release_reArmsLadder() async {
    let fake = ScriptedRepair([true])
    let c = HelperHealthController(policy: tiny, repair: { await fake.run() })
    c.setGenerating(true)
    for _ in 0..<5 { c.ingestPollOutcome(succeeded: false) }  // all held
    XCTAssertEqual(c.health, .healthy)
    c.setGenerating(false)                                    // stream ended
    // A helper that is genuinely unreachable AFTER the stream still repairs —
    // the gate only suppresses busy-timeouts DURING a generation.
    c.ingestPollOutcome(succeeded: false)                     // reconnecting(1)
    XCTAssertEqual(c.health, .reconnecting(consecutiveFailures: 1))
    c.ingestPollOutcome(succeeded: false)                     // repairing(1)
    XCTAssertEqual(c.health, .repairing(attempt: 1), "after the stream ends a real unreachable helper still repairs")
    await c.awaitRepairForTesting()
    XCTAssertEqual(c.health, .healthy)
    XCTAssertEqual(fake.calls, 1)
  }

  // MARK: - fakes

  /// Returns scripted reachability results (defaults to `false` once drained).
  /// Thread-safe so the repair Task can call it off the test's await points.
  private final class ScriptedRepair: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Bool]
    private var _calls = 0
    init(_ results: [Bool]) { self.results = results }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    func run() async -> Bool {
      lock.lock(); defer { lock.unlock() }
      _calls += 1
      return results.isEmpty ? false : results.removeFirst()
    }
  }

  /// Repair that PARKS on a continuation until the test releases it, so a
  /// no-overlap test can interleave failed polls while one reconcile is in
  /// flight. @MainActor — matches the controller's actor; the repair Task
  /// runs on main.
  @MainActor
  private final class GatedRepair {
    private(set) var calls = 0
    private var continuation: CheckedContinuation<Bool, Never>?
    var pending: Int { continuation == nil ? 0 : 1 }
    func run() async -> Bool {
      calls += 1
      return await withCheckedContinuation { self.continuation = $0 }
    }
    func release(returning value: Bool) {
      let c = continuation
      continuation = nil
      c?.resume(returning: value)
    }
  }
}
