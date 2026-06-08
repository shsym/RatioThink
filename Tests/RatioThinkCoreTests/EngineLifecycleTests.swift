import XCTest
@testable import RatioThinkCore

/// The unified engine-lifecycle SoT: the `ModelLoadCenter` residency
/// invalidation (`engineLeftRunning` / `engineServesNoModel`) and the
/// `EngineLifecycle` coordinator that folds engine + load into one published
/// `EngineIndicatorState` and fires the invalidation on the leave-`.running`
/// edge. Pinned synchronously — the coordinator's Combine sinks deliver on the
/// main actor as each `@Published` mutates.
@MainActor
final class EngineLifecycleTests: XCTestCase {

  private func makeStore(_ initial: EngineStatus) -> EngineStatusStore {
    EngineStatusStore(client: EngineStatusStoreTests.StubXPCClient(), initialStatus: initial)
  }

  // MARK: - ModelLoadCenter.engineLeftRunning (stop edge)

  func test_engineLeftRunning_clears_resident() {
    let center = ModelLoadCenter(initialResident: "org/model")
    center.engineLeftRunning()
    XCTAssertNil(center.residentModelID)
  }

  func test_engineLeftRunning_is_idempotent_noop_when_idle() {
    let center = ModelLoadCenter()
    center.engineLeftRunning()
    center.engineLeftRunning()
    XCTAssertNil(center.residentModelID)
  }

  // MARK: - ModelLoadCenter.engineServesNoModel (running-but-empty)

  func test_engineServesNoModel_clears_stale_resident_on_live_engine() {
    let center = ModelLoadCenter(initialResident: "org/model")
    center.engineServesNoModel()
    XCTAssertNil(center.residentModelID)
  }

  // MARK: - EngineLifecycle coordinator

  func test_initial_indicator_folds_engine_and_load() {
    let center = ModelLoadCenter(initialResident: "org/m")
    let store = makeStore(.running(port: 8080, profileID: "chat"))
    let lifecycle = EngineLifecycle(engineStatus: store, modelLoad: center)
    XCTAssertEqual(lifecycle.indicator, .running(modelID: "org/m"))
  }

  /// The operator's exact case: engine running + resident model, then the
  /// engine stops. The coordinator must (a) invalidate residency at the source
  /// and (b) refold to `.offline` — so the dot, popover, and gate all read a
  /// dead engine with no resident.
  func test_running_then_stop_invalidates_residency_and_folds_offline() {
    let center = ModelLoadCenter(initialResident: "org/m")
    let store = makeStore(.running(port: 8080, profileID: "chat"))
    let lifecycle = EngineLifecycle(engineStatus: store, modelLoad: center)
    XCTAssertEqual(lifecycle.indicator, .running(modelID: "org/m"))

    // Engine stops (clean) — drives the leave-`.running` edge.
    store._applyPollForTesting(next: .stopped, error: nil)

    XCTAssertNil(center.residentModelID, "residency must be cleared on the stop edge")
    XCTAssertEqual(lifecycle.indicator, .offline, "the fold must be offline, never resident")
  }

  /// A first-load engine that never reached `.running` must NOT be treated as
  /// a leave-`.running` edge, and an engine death after a real run must.
  func test_leave_running_edge_only_fires_after_a_real_run() {
    let center = ModelLoadCenter()
    let store = makeStore(.starting)
    let lifecycle = EngineLifecycle(engineStatus: store, modelLoad: center)

    // starting → stopped is NOT a leave-running edge; nothing to invalidate.
    store._applyPollForTesting(next: .stopped, error: nil)
    XCTAssertNil(center.residentModelID)
    XCTAssertEqual(lifecycle.indicator, .offline)

    // Engine comes up and a model becomes resident (reconcile path).
    store._applyPollForTesting(next: .running(port: 8080, profileID: "chat"), error: nil)
    center.reconcileEngineResident("org/m")
    XCTAssertEqual(lifecycle.indicator, .running(modelID: "org/m"))

    // Now a real post-run death: residency must be invalidated.
    store._applyPollForTesting(next: .failed(code: .engineGone, message: "exited"), error: nil)
    XCTAssertNil(center.residentModelID, "residency must drop on a post-run engine death")
    if case .running = lifecycle.indicator {
      XCTFail("a failed engine must not fold to .running/resident")
    }
  }
}
