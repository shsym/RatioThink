import XCTest
@testable import RatioThinkCore

/// Exhaustive unit tests for the pure `HelperHealthReducer` — the App-side
/// helper-restart ladder (#412). Drives event streams through the reducer and
/// asserts both the resulting state AND the emitted action, so the controller
/// (Phase 3) can rely on a fully-pinned decision table.
final class HelperHealthReducerTests: XCTestCase {

  /// Small policy so the ladder is short enough to walk explicitly.
  private let tiny = HelperHealthPolicy(transientThreshold: 2, maxRepairAttempts: 2, repairGap: 2)

  private func reduce(_ state: HelperHealth, _ event: HelperHealthEvent,
                      _ policy: HelperHealthPolicy) -> (HelperHealth, HelperHealthAction) {
    HelperHealthReducer.reduce(state, event, policy: policy)
  }

  // MARK: - healthy / reconnecting

  func test_healthy_pollSucceeded_stays_healthy_without_recovered_noise() {
    let (state, action) = reduce(.healthy, .pollSucceeded, tiny)
    XCTAssertEqual(state, .healthy)
    XCTAssertEqual(action, .none, "a healthy tick must NOT re-emit .recovered every second")
  }

  func test_healthy_pollFailed_enters_reconnecting() {
    let (state, action) = reduce(.healthy, .pollFailed,
                                 HelperHealthPolicy(transientThreshold: 12))
    XCTAssertEqual(state, .reconnecting(consecutiveFailures: 1))
    XCTAssertEqual(action, .none, "the first blip is transient — no repair yet")
  }

  func test_reconnecting_accumulates_below_threshold() {
    // threshold 12: failures 1..11 stay reconnecting; no action.
    var state: HelperHealth = .healthy
    let policy = HelperHealthPolicy(transientThreshold: 12)
    for n in 1...11 {
      let (next, action) = reduce(state, .pollFailed, policy)
      XCTAssertEqual(next, .reconnecting(consecutiveFailures: n))
      XCTAssertEqual(action, .none)
      state = next
    }
  }

  func test_crossing_transientThreshold_starts_first_repair() {
    // threshold 2: failure 1 → reconnecting(1); failure 2 → repairing(1)+startRepair.
    let policy = HelperHealthPolicy(transientThreshold: 2, maxRepairAttempts: 2, repairGap: 2)
    let (s1, a1) = reduce(.healthy, .pollFailed, policy)
    XCTAssertEqual(s1, .reconnecting(consecutiveFailures: 1))
    XCTAssertEqual(a1, .none)
    let (s2, a2) = reduce(s1, .pollFailed, policy)
    XCTAssertEqual(s2, .repairing(attempt: 1))
    XCTAssertEqual(a2, .startRepair(attempt: 1), "crossing the transient window fires repair attempt 1")
  }

  func test_reconnecting_pollSucceeded_recovers() {
    let (state, action) = reduce(.reconnecting(consecutiveFailures: 5), .pollSucceeded, tiny)
    XCTAssertEqual(state, .healthy)
    XCTAssertEqual(action, .recovered, "a reachable poll during reconnecting clears the transient state")
  }

  // MARK: - repairing

  func test_repairing_pollFailed_does_not_double_fire() {
    let (state, action) = reduce(.repairing(attempt: 1), .pollFailed, tiny)
    XCTAssertEqual(state, .repairing(attempt: 1), "failed polls during an in-flight reconcile must not advance the ladder")
    XCTAssertEqual(action, .none)
  }

  func test_repairing_repairFinished_reachable_recovers() {
    let (state, action) = reduce(.repairing(attempt: 1), .repairFinished(reachable: true), tiny)
    XCTAssertEqual(state, .healthy)
    XCTAssertEqual(action, .recovered)
  }

  func test_repairing_repairFinished_unreachable_below_cap_cools_down() {
    let (state, action) = reduce(.repairing(attempt: 1), .repairFinished(reachable: false), tiny)
    XCTAssertEqual(state, .repairCoolingDown(attempt: 1, failuresSinceRepair: 0))
    XCTAssertEqual(action, .none)
  }

  func test_repairing_repairFinished_unreachable_at_cap_escalates() {
    let (state, action) = reduce(.repairing(attempt: 2), .repairFinished(reachable: false), tiny)
    XCTAssertEqual(state, .unreachable)
    XCTAssertEqual(action, .escalate, "the last failed attempt exhausts the ladder → loud escalation")
  }

  func test_stale_repairFinished_when_already_healthy_is_ignored() {
    // A live poll recovered the helper while a reconcile was still in flight;
    // the late failure report must NOT drag a healthy helper back down.
    let (state, action) = reduce(.healthy, .repairFinished(reachable: false), tiny)
    XCTAssertEqual(state, .healthy)
    XCTAssertEqual(action, .none)
  }

  // MARK: - cooling down

  func test_coolingDown_accumulates_then_starts_next_attempt() {
    // gap 2: one failure stays cooling; the second fires attempt 2.
    let policy = HelperHealthPolicy(transientThreshold: 2, maxRepairAttempts: 3, repairGap: 2)
    let (s1, a1) = reduce(.repairCoolingDown(attempt: 1, failuresSinceRepair: 0), .pollFailed, policy)
    XCTAssertEqual(s1, .repairCoolingDown(attempt: 1, failuresSinceRepair: 1))
    XCTAssertEqual(a1, .none)
    let (s2, a2) = reduce(s1, .pollFailed, policy)
    XCTAssertEqual(s2, .repairing(attempt: 2))
    XCTAssertEqual(a2, .startRepair(attempt: 2))
  }

  func test_coolingDown_pollSucceeded_recovers() {
    let (state, action) = reduce(.repairCoolingDown(attempt: 1, failuresSinceRepair: 1), .pollSucceeded, tiny)
    XCTAssertEqual(state, .healthy)
    XCTAssertEqual(action, .recovered)
  }

  // MARK: - unreachable

  func test_unreachable_pollFailed_stays_quiet() {
    let (state, action) = reduce(.unreachable, .pollFailed, tiny)
    XCTAssertEqual(state, .unreachable)
    XCTAssertEqual(action, .none, "no re-escalation spam while stuck unreachable")
  }

  func test_unreachable_pollSucceeded_recovers() {
    let (state, action) = reduce(.unreachable, .pollSucceeded, tiny)
    XCTAssertEqual(state, .healthy)
    XCTAssertEqual(action, .recovered)
  }

  func test_manualRestart_from_unreachable_restarts_ladder_at_attempt1() {
    let (state, action) = reduce(.unreachable, .manualRestart, tiny)
    XCTAssertEqual(state, .repairing(attempt: 1))
    XCTAssertEqual(action, .startRepair(attempt: 1), "the user's Restart Helper resets the ladder and fires a fresh attempt")
  }

  // MARK: - auto-repair disabled

  func test_maxRepairAttempts_zero_escalates_past_transient_window() {
    let policy = HelperHealthPolicy(transientThreshold: 1, maxRepairAttempts: 0)
    let (state, action) = reduce(.healthy, .pollFailed, policy)
    XCTAssertEqual(state, .unreachable)
    XCTAssertEqual(action, .escalate, "with auto-repair disabled, crossing the window escalates straight away")
  }

  // MARK: - full ladder walk (integration of the pure machine)

  func test_full_ladder_walk_to_escalation_then_recovery() {
    // tiny policy: threshold 2, maxAttempts 2, gap 2. Walk a pure poll stream
    // and assert the exact action sequence, then prove a success recovers.
    let policy = tiny
    var state: HelperHealth = .healthy
    func step(_ e: HelperHealthEvent) -> HelperHealthAction {
      let (next, action) = reduce(state, e, policy); state = next; return action
    }
    XCTAssertEqual(step(.pollFailed), .none)                 // reconnecting(1)
    XCTAssertEqual(step(.pollFailed), .startRepair(attempt: 1)) // repairing(1)
    XCTAssertEqual(step(.repairFinished(reachable: false)), .none) // coolingDown(1,0)
    XCTAssertEqual(step(.pollFailed), .none)                 // coolingDown(1,1)
    XCTAssertEqual(step(.pollFailed), .startRepair(attempt: 2)) // repairing(2)
    XCTAssertEqual(step(.repairFinished(reachable: false)), .escalate) // unreachable
    XCTAssertEqual(state, .unreachable)
    // Helper finally comes back on a later poll.
    XCTAssertEqual(step(.pollSucceeded), .recovered)
    XCTAssertEqual(state, .healthy)
  }

  func test_repair_attempt1_success_short_circuits_ladder() {
    // The common case: the first reconcile fixes a stale launchd job.
    let policy = tiny
    var state: HelperHealth = .healthy
    func step(_ e: HelperHealthEvent) -> HelperHealthAction {
      let (next, action) = reduce(state, e, policy); state = next; return action
    }
    _ = step(.pollFailed)                                    // reconnecting(1)
    XCTAssertEqual(step(.pollFailed), .startRepair(attempt: 1))
    XCTAssertEqual(step(.repairFinished(reachable: true)), .recovered)
    XCTAssertEqual(state, .healthy)
  }

  // MARK: - default policy timing

  func test_default_policy_first_repair_at_12_failures() {
    let policy = HelperHealthPolicy()  // 12 / 2 / 5
    var state: HelperHealth = .healthy
    var firstRepairAt: Int?
    for n in 1...12 {
      let (next, action) = reduce(state, .pollFailed, policy)
      state = next
      if case .startRepair = action, firstRepairAt == nil { firstRepairAt = n }
    }
    XCTAssertEqual(firstRepairAt, 12, "default policy must wait ~12 failed polls (>launchd's ~10s throttle) before the first repair")
  }
}
