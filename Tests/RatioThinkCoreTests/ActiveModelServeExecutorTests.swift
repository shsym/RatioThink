import XCTest
import Foundation
@testable import RatioThinkCore

/// `ActiveModelServeExecutor` — the status-aware serve executor (#469) with
/// the deferred-pick queue (#488). The #469 leg (start a stopped engine /
/// restart a running one / no-op when resident) moved here from the
/// `RatioThinkApp` closure; the #488 leg queues a pick made while the engine
/// is `.starting`/`.stopping` (previously a silent drop), coalesces to the
/// latest pick, and re-serves it when the engine settles — re-running the
/// policy against the settled state so it converges honestly.
///
/// Transitions are driven through `EngineStatusStore._applyPollForTesting`
/// (the same reducer the 1 Hz poll loop runs), so the subscription under test
/// is the production one.
@MainActor
final class ActiveModelServeExecutorTests: XCTestCase {

  // MARK: - stub

  /// `AppXPCClient` spy recording `startEngine`/`restartEngine` with
  /// injectable results. `engineStatus()` is never polled here (the store's
  /// loop is not started); transitions are applied directly.
  private final class SpyXPCClient: AppXPCClient, @unchecked Sendable {
    private let lock = NSLock()

    func helperProtocolVersion() async throws -> Int {
      HelperProtocolCompatibility.currentVersion
    }
    func engineStatus() async throws -> EngineStatus { .stopped }
    func stopEngine() async throws {}

    private(set) var startCalls = 0
    private(set) var lastStartProfileID: String?
    private(set) var lastStartModelOverride: String?
    private var startResult: Result<Void, Error> = .success(())
    func setStartResult(_ result: Result<Void, Error>) {
      lock.withLock { startResult = result }
    }

    /// Review F2 race seam: a start for `gatedModel` suspends (recorded but
    /// unresolved) until `releaseGate()`, then resolves with `gatedResult` —
    /// lets a test interleave a newer direct pick while a deferred re-serve
    /// is mid-flight inside its minutes-long start budget. `gateResolved`
    /// flips just before the result is thrown/returned — the happens-before
    /// signal a test must await after `releaseGate()` so its assertions run
    /// AFTER the gated start actually resolved (review v2 F1: without it the
    /// nil-assertion raced the resolution and pinned nothing).
    private var gatedModel: String?
    private var gateOpen = false
    private(set) var gateResolved = false
    private var gatedResult: Result<Void, Error> = .success(())
    func gateStart(of model: String, result: Result<Void, Error>) {
      lock.withLock {
        gatedModel = model
        gatedResult = result
      }
    }
    func releaseGate() { lock.withLock { gateOpen = true } }

    func startEngine(profileID: String, modelOverride: String?) async throws {
      let gated: Bool = lock.withLock {
        startCalls += 1
        lastStartProfileID = profileID
        lastStartModelOverride = modelOverride
        return modelOverride != nil && modelOverride == gatedModel
      }
      if gated {
        // Bounded so a test that forgets releaseGate() fails loud, and the
        // sleep is un-swallowed so cancellation propagates (review v2 F1).
        let deadline = Date().addingTimeInterval(5)
        while !(lock.withLock { gateOpen }) {
          if Date() >= deadline {
            throw EngineError(code: .unknown, message: "test bug: start gate never released")
          }
          try await Task.sleep(nanoseconds: 10_000_000)
        }
        let result: Result<Void, Error> = lock.withLock {
          gateResolved = true
          return gatedResult
        }
        try result.get()
        return
      }
      try lock.withLock { startResult }.get()
    }

    private(set) var restartCalls = 0
    private(set) var lastRestartProfileID: String?
    private(set) var lastRestartModelOverride: String?
    func restartEngine(profileID: String, modelOverride: String?) async throws {
      lock.withLock {
        restartCalls += 1
        lastRestartProfileID = profileID
        lastRestartModelOverride = modelOverride
      }
    }
  }

  private struct Rig {
    let client: SpyXPCClient
    let store: EngineStatusStore
    let center: ModelLoadCenter
    let executor: ActiveModelServeExecutor
  }

  private func makeRig(initialStatus: EngineStatus,
                       resident: String? = nil) -> Rig {
    let client = SpyXPCClient()
    let store = EngineStatusStore(client: client, initialStatus: initialStatus)
    let center = ModelLoadCenter(initialResident: resident)
    let executor = ActiveModelServeExecutor(engineStatus: store, modelLoad: center)
    return Rig(client: client, store: store, center: center, executor: executor)
  }

  private func running(port: EnginePort = 8080) -> EngineStatus {
    .running(EngineSessionSnapshot(port: port, profileID: "chat"))
  }

  /// Wait for an async deferred re-serve (spawned in a Task off the status
  /// subscription) to land. Polls instead of a fixed sleep so the pass is
  /// fast and the failure carries the condition.
  private func waitUntil(timeout: TimeInterval = 2,
                         _ message: String,
                         _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertTrue(condition(), message)
  }

  /// Give any erroneously-spawned Task a chance to run before asserting a
  /// negative (no start/restart fired).
  private func settle() async {
    for _ in 0..<20 { await Task.yield() }
  }

  // MARK: - #469 leg (moved from the RatioThinkApp closure)

  func test_serve_starts_a_stopped_engine_bound_to_the_pick() async throws {
    let rig = makeRig(initialStatus: .stopped)
    try await rig.executor.serve(modelID: "m-A.gguf", profileID: "chat")
    XCTAssertEqual(rig.client.startCalls, 1)
    XCTAssertEqual(rig.client.lastStartProfileID, "chat")
    XCTAssertEqual(rig.client.lastStartModelOverride, "m-A.gguf")
    XCTAssertNil(rig.executor.deferredPick, "an executed pick must not queue")
  }

  func test_serve_restarts_a_running_engine_onto_a_different_pick() async throws {
    let rig = makeRig(initialStatus: running(), resident: "m-A.gguf")
    try await rig.executor.serve(modelID: "m-B.gguf", profileID: "chat")
    XCTAssertEqual(rig.client.restartCalls, 1)
    XCTAssertEqual(rig.client.lastRestartModelOverride, "m-B.gguf")
    XCTAssertEqual(rig.client.startCalls, 0)
    XCTAssertNil(rig.executor.deferredPick)
  }

  func test_serve_noops_when_the_pick_is_already_resident() async throws {
    let rig = makeRig(initialStatus: running(), resident: "m-A.gguf")
    try await rig.executor.serve(modelID: "m-A.gguf", profileID: "chat")
    XCTAssertEqual(rig.client.startCalls, 0)
    XCTAssertEqual(rig.client.restartCalls, 0)
    XCTAssertNil(rig.executor.deferredPick)
  }

  func test_serve_propagates_a_start_failure_to_the_caller() async {
    let rig = makeRig(initialStatus: .stopped)
    rig.client.setStartResult(.failure(EngineError(code: .modelMissing, message: "gone")))
    do {
      try await rig.executor.serve(modelID: "m-A.gguf", profileID: "chat")
      XCTFail("a resolver reject must throw to the caller (serveModelError path)")
    } catch {
      // expected — ProfileSwapCoordinator.startLoad surfaces it.
    }
  }

  // MARK: - #488: queue instead of drop

  func test_pick_during_starting_is_queued_not_dropped() async throws {
    let rig = makeRig(initialStatus: .starting)
    try await rig.executor.serve(modelID: "m-A.gguf", profileID: "chat")
    XCTAssertEqual(rig.client.startCalls, 0)
    XCTAssertEqual(rig.client.restartCalls, 0)
    XCTAssertEqual(rig.executor.deferredPick,
                   .init(modelID: "m-A.gguf", profileID: "chat"),
                   "a pick against a transitional engine must queue, not vanish")
  }

  func test_queued_pick_coalesces_to_the_latest() async throws {
    let rig = makeRig(initialStatus: .starting)
    try await rig.executor.serve(modelID: "m-A.gguf", profileID: "chat")
    try await rig.executor.serve(modelID: "m-B.gguf", profileID: "chat")
    XCTAssertEqual(rig.executor.deferredPick?.modelID, "m-B.gguf",
                   "the newest pick supersedes the queued one")

    rig.store._applyPollForTesting(next: .stopped, error: nil)
    await waitUntil("the settle must serve exactly the latest pick") {
      rig.client.startCalls == 1
    }
    XCTAssertEqual(rig.client.lastStartModelOverride, "m-B.gguf")
    await settle()
    XCTAssertEqual(rig.client.startCalls, 1, "the superseded pick must never fire")
    XCTAssertNil(rig.executor.deferredPick)
  }

  func test_queued_pick_starts_the_engine_on_a_stopped_settle() async throws {
    // Pick lands while the engine is shutting down → applied once stopped.
    let rig = makeRig(initialStatus: .stopping)
    try await rig.executor.serve(modelID: "m-A.gguf", profileID: "chat")
    XCTAssertNotNil(rig.executor.deferredPick)

    rig.store._applyPollForTesting(next: .stopped, error: nil)
    await waitUntil("a stopped settle must start the engine bound to the pick") {
      rig.client.startCalls == 1
    }
    XCTAssertEqual(rig.client.lastStartProfileID, "chat")
    XCTAssertEqual(rig.client.lastStartModelOverride, "m-A.gguf")
    XCTAssertNil(rig.executor.deferredPick)
  }

  func test_queued_pick_restarts_the_engine_on_a_running_settle_with_another_model() async throws {
    let rig = makeRig(initialStatus: .starting)
    try await rig.executor.serve(modelID: "m-B.gguf", profileID: "chat")

    // The in-flight launch lands serving a different model.
    rig.center.reconcileEngineResident("m-A.gguf")
    rig.store._applyPollForTesting(next: running(), error: nil)
    await waitUntil("a running settle on another model must restart onto the pick") {
      rig.client.restartCalls == 1
    }
    XCTAssertEqual(rig.client.lastRestartModelOverride, "m-B.gguf")
    XCTAssertEqual(rig.client.startCalls, 0)
    XCTAssertNil(rig.executor.deferredPick)
  }

  func test_queued_pick_is_dropped_when_the_settle_already_serves_it() async throws {
    let rig = makeRig(initialStatus: .starting)
    try await rig.executor.serve(modelID: "m-A.gguf", profileID: "chat")

    // The in-flight launch was already booting the pick.
    rig.center.reconcileEngineResident("m-A.gguf")
    rig.store._applyPollForTesting(next: running(), error: nil)
    await settle()
    XCTAssertEqual(rig.client.startCalls, 0)
    XCTAssertEqual(rig.client.restartCalls, 0)
    XCTAssertNil(rig.executor.deferredPick,
                 "an already-resident settle must consume the queued pick")
  }

  func test_queued_pick_starts_on_a_retryable_failure_settle() async throws {
    // .running first so the first-load transient-failure hold does not
    // mask the explicit .failed (EngineStatusStore #2 grace).
    let rig = makeRig(initialStatus: running(), resident: "m-A.gguf")
    rig.store._applyPollForTesting(next: .stopping, error: nil)
    try await rig.executor.serve(modelID: "m-B.gguf", profileID: "chat")
    XCTAssertNotNil(rig.executor.deferredPick)

    rig.store._applyPollForTesting(
      next: .failed(code: .engineGone, message: "died"), error: nil)
    await waitUntil("a retryable failure settle must start the engine on the pick") {
      rig.client.startCalls == 1
    }
    XCTAssertEqual(rig.client.lastStartModelOverride, "m-B.gguf")
    XCTAssertNil(rig.executor.deferredPick)
  }

  func test_queued_pick_is_dropped_on_a_terminal_failure_settle() async throws {
    let rig = makeRig(initialStatus: running(), resident: "m-A.gguf")
    rig.store._applyPollForTesting(next: .stopping, error: nil)
    try await rig.executor.serve(modelID: "m-B.gguf", profileID: "chat")

    rig.store._applyPollForTesting(
      next: .failed(code: .memoryRisk, message: "too big"), error: nil)
    await settle()
    XCTAssertEqual(rig.client.startCalls, 0,
                   "blockedTerminal must not re-fire a guaranteed-to-fail start")
    XCTAssertEqual(rig.client.restartCalls, 0)
    XCTAssertNil(rig.executor.deferredPick,
                 "the queue must not hold a pick the banner already owns")
  }

  func test_transitional_transitions_keep_the_pick_parked() async throws {
    let rig = makeRig(initialStatus: .starting)
    try await rig.executor.serve(modelID: "m-A.gguf", profileID: "chat")

    rig.store._applyPollForTesting(next: .stopping, error: nil)
    await settle()
    XCTAssertEqual(rig.client.startCalls, 0)
    XCTAssertEqual(rig.client.restartCalls, 0)
    XCTAssertEqual(rig.executor.deferredPick?.modelID, "m-A.gguf",
                   "a transitional transition must not consume the queue")
  }

  // MARK: - review F1: explicit stop wins over a queued pick

  func test_explicit_stop_cancels_the_queued_pick() async throws {
    // Pick lands while the engine is starting; the user then explicitly
    // stops it (Unload / Local API stop — both funnel through
    // `EngineStatusStore.stopEngine()`). The stop is the newest intent: the
    // `.stopped` settle must NOT revive the engine onto the stale pick.
    let rig = makeRig(initialStatus: .starting)
    try await rig.executor.serve(modelID: "m-A.gguf", profileID: "chat")
    XCTAssertNotNil(rig.executor.deferredPick)

    try await rig.store.stopEngine()
    XCTAssertNil(rig.executor.deferredPick,
                 "an explicit stop must drop the queued pick immediately")

    rig.store._applyPollForTesting(next: .stopped, error: nil)
    await settle()
    XCTAssertEqual(rig.client.startCalls, 0,
                   "a stopped engine must STAY stopped — the stale pick must not relaunch it")
    XCTAssertEqual(rig.client.restartCalls, 0)
  }

  func test_explicit_stop_invalidates_a_scheduled_revival() async throws {
    // Review v2 F2: the F1×F2 intersection — the settle already DEQUEUED the
    // pick (queue nil) and scheduled its revival when the user stops. Only
    // `cancelDeferredPick`'s unconditional generation bump discards that
    // scheduled revival; without it the engine relaunches onto the stale
    // pick despite the stop.
    let rig = makeRig(initialStatus: .stopping)
    try await rig.executor.serve(modelID: "m-A.gguf", profileID: "chat")

    // Sink runs synchronously: pick dequeued, revival Task scheduled.
    rig.store._applyPollForTesting(next: .stopped, error: nil)
    XCTAssertNil(rig.executor.deferredPick, "revival must have dequeued the pick")
    // The hook's bump lands synchronously at stopEngine() entry, ahead of
    // the scheduled revival getting the actor.
    try await rig.store.stopEngine()

    await settle()
    XCTAssertEqual(rig.client.startCalls, 0,
                   "an explicit stop must invalidate the scheduled revival, not just the queue")
    XCTAssertEqual(rig.client.restartCalls, 0)
  }

  // MARK: - review F2: supersede guards on the deferred re-serve

  func test_newer_pick_supersedes_a_scheduled_deferred_reserve() async throws {
    // The settle dequeues pick A and schedules its revival Task; a direct
    // pick B lands on the actor first. A's revival must observe the bump
    // and discard itself — only B may reach the engine.
    let rig = makeRig(initialStatus: .stopping)
    try await rig.executor.serve(modelID: "m-A.gguf", profileID: "chat")
    XCTAssertNotNil(rig.executor.deferredPick)

    // Sink runs synchronously here: A dequeued, revival Task scheduled.
    rig.store._applyPollForTesting(next: .stopped, error: nil)
    // No suspension between the settle and this serve, so B's generation
    // bump lands before the scheduled revival gets the actor.
    try await rig.executor.serve(modelID: "m-B.gguf", profileID: "chat")
    await settle()

    XCTAssertEqual(rig.client.startCalls, 1, "the superseded revival must not start the engine")
    XCTAssertEqual(rig.client.lastStartModelOverride, "m-B.gguf")
  }

  func test_stale_deferred_failure_is_discarded_when_superseded_mid_flight() async throws {
    // A's revived start hangs inside its (minutes-long) budget; the user
    // picks B, which succeeds. A's late failure must be discarded — a stale
    // "Couldn't load A" over B's clean outcome is exactly the dishonest
    // surfacing this ticket removes.
    let rig = makeRig(initialStatus: .stopping)
    var reported: String?
    rig.executor.onDeferredServeFailure = { modelID, _ in reported = modelID }
    rig.client.gateStart(of: "m-A.gguf",
                         result: .failure(EngineError(code: .modelMissing, message: "gone")))

    try await rig.executor.serve(modelID: "m-A.gguf", profileID: "chat")
    rig.store._applyPollForTesting(next: .stopped, error: nil)
    await waitUntil("A's revived start must be in flight (recorded, gated)") {
      rig.client.startCalls == 1
    }

    // Newer direct pick while A is suspended mid-start.
    try await rig.executor.serve(modelID: "m-B.gguf", profileID: "chat")
    XCTAssertEqual(rig.client.lastStartModelOverride, "m-B.gguf")

    // Review v2 F1: the nil-assertion is meaningful only AFTER the gated
    // start actually resolved (threw) and the revival's catch had the actor
    // — without the resolution signal the assert raced the throw and passed
    // even with the supersede guard deleted.
    rig.client.releaseGate()
    await waitUntil("the gated start must resolve after release") {
      rig.client.gateResolved
    }
    await settle()
    XCTAssertNil(reported,
                 "a superseded revival's failure must be discarded — B's outcome owns the surface")
  }

  func test_unsuperseded_gated_failure_still_reports_through_the_sink() async throws {
    // Positive-control twin of the test above (review v2 F1): identical
    // gated harness, NO superseding pick — the failure MUST surface,
    // proving the harness can observe a report at all (so the twin's nil
    // means "discarded", not "never delivered").
    let rig = makeRig(initialStatus: .stopping)
    var reported: String?
    rig.executor.onDeferredServeFailure = { modelID, _ in reported = modelID }
    rig.client.gateStart(of: "m-A.gguf",
                         result: .failure(EngineError(code: .modelMissing, message: "gone")))

    try await rig.executor.serve(modelID: "m-A.gguf", profileID: "chat")
    rig.store._applyPollForTesting(next: .stopped, error: nil)
    await waitUntil("A's revived start must be in flight (recorded, gated)") {
      rig.client.startCalls == 1
    }

    rig.client.releaseGate()
    await waitUntil("an unsuperseded revival's failure must reach the sink") {
      reported != nil
    }
    XCTAssertEqual(reported, "m-A.gguf")
  }

  func test_deferred_serve_failure_reports_through_the_sink() async throws {
    let rig = makeRig(initialStatus: .stopping)
    var reported: (modelID: String, error: Error)?
    rig.executor.onDeferredServeFailure = { reported = ($0, $1) }
    rig.client.setStartResult(.failure(EngineError(code: .modelMissing, message: "gone")))

    try await rig.executor.serve(modelID: "m-A.gguf", profileID: "chat")
    rig.store._applyPollForTesting(next: .stopped, error: nil)
    await waitUntil("a deferred re-serve failure must reach the sink — it has no awaiting caller") {
      reported != nil
    }
    XCTAssertEqual(reported?.modelID, "m-A.gguf")
    XCTAssertEqual((reported?.error as? EngineError)?.code, .modelMissing)
  }
}
