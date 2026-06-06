import XCTest
@testable import RatioThink

/// Phase 3.5: exercise the indicator's source of truth.
///
/// `ModelLoadCenter` is `@MainActor`-isolated, so every assertion runs
/// on `@MainActor` (XCTest's `await fulfillment(of:)` hops back for
/// us). The tests use canned `AsyncThrowingStream`s so they have no
/// engine, no sleep, and no wall-clock dependency — the state-machine
/// transitions are what matters.
@MainActor
final class ModelLoadCenterTests: XCTestCase {

  // MARK: -  Unload

  func test_markUnloaded_clears_resident_and_returns_to_idle() {
    let center = ModelLoadCenter(initialResident: "m1")
    XCTAssertEqual(center.residentModelID, "m1")
    XCTAssertEqual(center.state, .ready(modelID: "m1"))

    center.markUnloaded()

    XCTAssertNil(center.residentModelID, "Unload must clear the resident model (0 RAM)")
    XCTAssertEqual(center.state, .idle, "Unload returns the indicator to idle")
  }

  func test_markUnloaded_cancels_an_inflight_load() {
    let center = ModelLoadCenter()
    center.load(modelID: "m2") {
      AsyncThrowingStream { _ in /* never yields, never finishes */ }
    }
    center.markUnloaded()
    XCTAssertNil(center.residentModelID)
    XCTAssertEqual(center.state, .idle)
    XCTAssertFalse(center.isLoading)
  }

  // MARK: - helpers

  private func streamFactory(events: [LoadEvent]) -> @Sendable () -> AsyncThrowingStream<LoadEvent, Error> {
    { @Sendable in
      AsyncThrowingStream { continuation in
        for event in events { continuation.yield(event) }
        continuation.finish()
      }
    }
  }

  // MARK: - tests

  func test_initial_state_is_idle() {
    let center = ModelLoadCenter()
    XCTAssertEqual(center.state, .idle)
    XCTAssertNil(center.residentModelID)
    XCTAssertFalse(center.isLoading)
  }

  func test_initial_resident_seeds_ready_state() {
    let center = ModelLoadCenter(initialResident: "qwen3-0.6b")
    XCTAssertEqual(center.state, .ready(modelID: "qwen3-0.6b"))
    XCTAssertEqual(center.residentModelID, "qwen3-0.6b")
  }

  func test_load_drives_loading_then_ready_and_sets_resident() async {
    let center = ModelLoadCenter()
    // Drive the stream by hand so each event has a deterministic
    // checkpoint — an all-yields-then-finish factory raced the
    // consumer's @MainActor hops on this toolchain.
    let (asyncStream, continuation) = AsyncThrowingStream<LoadEvent, Error>.makeStream()
    center.load(modelID: "m1", streamFactory: { asyncStream })

    continuation.yield(.loading(loadedBytes: 100, totalBytes: 1000, etaSeconds: nil))
    await waitUntil(timeout: 1.0) {
      if case let .loading(_, loaded, _, _) = center.state, loaded == 100 { return true }
      return false
    }
    continuation.yield(.loading(loadedBytes: 500, totalBytes: 1000, etaSeconds: 2.0))
    await waitUntil(timeout: 1.0) {
      if case let .loading(_, loaded, _, eta) = center.state, loaded == 500, eta == 2.0 { return true }
      return false
    }
    continuation.yield(.ready)
    continuation.finish()
    await waitUntil(timeout: 1.0) {
      if case .ready = center.state { return true }
      return false
    }

    XCTAssertEqual(center.state, .ready(modelID: "m1"))
    XCTAssertEqual(center.residentModelID, "m1")
    XCTAssertFalse(center.isLoading)
  }

  /// Stream factory that emits `event` then stays open. Tests that
  /// want to assert mid-load state need this — a stream that emits
  /// and immediately finishes would race the polling test against
  /// the center's terminal `.ready` transition. Caller cleans up via
  /// `center.cancel()`.
  private func openStreamFactory(event: LoadEvent) -> @Sendable () -> AsyncThrowingStream<LoadEvent, Error> {
    { @Sendable in
      AsyncThrowingStream { continuation in
        continuation.yield(event)
        // Hold the continuation alive — Swift's reference rules keep
        // it retained as long as something captures it. The cancel()
        // path tears down via Task cancellation.
        continuation.onTermination = { _ in }
      }
    }
  }

  func test_progress_is_nil_for_zero_total_indeterminate_fallback() async {
    let center = ModelLoadCenter()
    center.load(
      modelID: "m1",
      streamFactory: openStreamFactory(
        event: .loading(loadedBytes: 0, totalBytes: 0, etaSeconds: nil)
      )
    )
    await waitUntil(timeout: 1.0) {
      if case let .loading(_, _, total, _) = center.state, total == 0 { return true }
      return false
    }
    XCTAssertNil(center.progress, "indeterminate path expects nil progress")
    XCTAssertTrue(center.isLoading)
    center.cancel()
  }

  func test_progress_reports_determinate_fraction() async {
    let center = ModelLoadCenter()
    center.load(
      modelID: "m1",
      streamFactory: openStreamFactory(
        event: .loading(loadedBytes: 250, totalBytes: 1000, etaSeconds: nil)
      )
    )
    await waitUntil(timeout: 1.0) {
      if case let .loading(_, loaded, _, _) = center.state, loaded == 250 { return true }
      return false
    }
    XCTAssertEqual(center.progress, 0.25)
    center.cancel()
  }

  func test_cancel_flips_to_cancelled_and_does_not_set_resident() async {
    let center = ModelLoadCenter()
    // Stream that never finishes — the cancel path is what we test.
    let neverFactory: @Sendable () -> AsyncThrowingStream<LoadEvent, Error> = { @Sendable in
      AsyncThrowingStream { continuation in
        continuation.yield(.loading(loadedBytes: 1, totalBytes: 1000, etaSeconds: nil))
        // Hold the continuation open by capturing it indefinitely.
        // Cancellation of the consuming Task drops this closure.
        continuation.onTermination = { _ in }
      }
    }
    center.load(modelID: "m1", streamFactory: neverFactory)

    await waitUntil(timeout: 1.0) {
      if case .loading = center.state { return true }
      return false
    }
    center.cancel()
    await waitUntil(timeout: 1.0) {
      if case .cancelled = center.state { return true }
      return false
    }

    XCTAssertEqual(center.state, .cancelled(modelID: "m1"))
    XCTAssertNil(center.residentModelID, "cancelled load must not mark a resident")
  }

  func test_failed_stream_flips_to_failed_state() async {
    struct Boom: Error {}
    let center = ModelLoadCenter()
    let factory: @Sendable () -> AsyncThrowingStream<LoadEvent, Error> = { @Sendable in
      AsyncThrowingStream { continuation in
        continuation.finish(throwing: Boom())
      }
    }
    center.load(modelID: "m1", streamFactory: factory)

    await waitUntil(timeout: 1.0) {
      if case .failed = center.state { return true }
      return false
    }
    if case let .failed(id, _) = center.state {
      XCTAssertEqual(id, "m1")
    } else {
      XCTFail("expected .failed state, got \(center.state)")
    }
  }

  // MARK: - review v1 F1 / F15: cancel race with already-finished stream

  func test_cancel_after_stream_finishes_with_ready_still_lands_in_cancelled() async {
    // The classic race that the never-finishing fixture cannot
    // exercise: the producer yields .ready and finish()s, then the
    // user clicks Cancel before the @MainActor consumer task has
    // posted finishReady. Without the generation guard, the consumer
    // would have fallen through to .ready and the user's Cancel
    // would have silently been ignored.
    let center = ModelLoadCenter()
    let (asyncStream, continuation) = AsyncThrowingStream<LoadEvent, Error>.makeStream()
    // Yield + finish BEFORE load() is called so the events are
    // buffered the moment the consumer's for-await starts iterating.
    continuation.yield(.ready)
    continuation.finish()

    center.load(modelID: "m1", streamFactory: { asyncStream })
    // Cancel synchronously on the SAME tick, before the consumer task
    // gets a chance to drain. This is the post-finish + pre-drain
    // window the generation guard protects.
    center.cancel()

    await waitUntil(timeout: 1.0) {
      if case .cancelled = center.state { return true }
      // Tolerate the "race lost" path too, so the test reports a
      // distinct failure rather than timing out.
      if case .ready = center.state { return true }
      return false
    }

    XCTAssertEqual(center.state, .cancelled(modelID: "m1"),
                   "cancel() called after stream finished but before consumer drained must NOT silently promote to .ready")
    XCTAssertNil(center.residentModelID,
                 "cancelled load must not leave a resident behind")
  }

  // MARK: - review v2 F2: residentModelID is verified-only

  func test_new_load_preserves_prior_resident_until_terminal_ready() {
    // Review v1 F6 was over-corrected: clearing residentModelID at
    // load() entry assumed engine evicts immediately. Most engines
    // do not evict until the new load succeeds. Verified-only
    // contract: residentModelID updates ONLY on terminal `.ready`.
    let center = ModelLoadCenter(initialResident: "m_prev")
    XCTAssertEqual(center.residentModelID, "m_prev")
    center.load(
      modelID: "m_next",
      streamFactory: openStreamFactory(
        event: .loading(loadedBytes: 0, totalBytes: 1, etaSeconds: nil)
      )
    )
    XCTAssertEqual(center.residentModelID, "m_prev",
                   "load() must preserve verified resident through transient loading")
    center.cancel()
    // Cancelled load: prior resident must still be reported — engine
    // most likely still has m_prev (it never finished switching).
    XCTAssertEqual(center.residentModelID, "m_prev",
                   "cancelled load must NOT erase the verified resident")
  }

  func test_failed_load_preserves_prior_resident() async {
    struct Boom: Error {}
    let center = ModelLoadCenter(initialResident: "m_prev")
    let factory: @Sendable () -> AsyncThrowingStream<LoadEvent, Error> = { @Sendable in
      AsyncThrowingStream { c in c.finish(throwing: Boom()) }
    }
    center.load(modelID: "m_next", streamFactory: factory)
    await waitUntil(timeout: 1.0) {
      if case .failed = center.state { return true }
      return false
    }
    XCTAssertEqual(center.residentModelID, "m_prev",
                   "failed load must NOT erase the verified resident")
  }

  // MARK: - review v2 F1: stale CancellationError after supersede

  func test_stale_cancellation_from_superseded_load_does_not_overwrite_current_state() async {
    // Load A is in flight. Load B supersedes it (which calls
    // cancel() and bumps the generation, surfacing CancellationError
    // on A's task). B's loading state must not regress to
    // .cancelled(A) when A's error finally propagates back.
    let center = ModelLoadCenter()
    let (streamA, contA) = AsyncThrowingStream<LoadEvent, Error>.makeStream()
    let (streamB, contB) = AsyncThrowingStream<LoadEvent, Error>.makeStream()
    center.load(modelID: "A", streamFactory: { streamA })
    // Park A on a yielded event to make sure the task is alive.
    contA.yield(.loading(loadedBytes: 1, totalBytes: 100, etaSeconds: nil))
    await waitUntil(timeout: 1.0) {
      if case let .loading(id, _, _, _) = center.state, id == "A" { return true }
      return false
    }
    // Supersede A with B. The load() call bumps generation + cancels
    // A's task — A's stream will surface CancellationError via the
    // detached consumer task.
    center.load(modelID: "B", streamFactory: { streamB })
    contB.yield(.loading(loadedBytes: 10, totalBytes: 100, etaSeconds: nil))
    await waitUntil(timeout: 1.0) {
      if case let .loading(id, _, _, _) = center.state, id == "B" { return true }
      return false
    }
    // Force A's stream to fail with cancellation NOW (after B is
    // already loading). Without the F1 stale-cancel guard, this would
    // overwrite state to .cancelled("A").
    contA.finish(throwing: CancellationError())
    // Give the late propagation a moment to land.
    try? await Task.sleep(nanoseconds: 100_000_000)
    if case let .loading(id, _, _, _) = center.state {
      XCTAssertEqual(id, "B", "stale cancel from A must NOT overwrite B's loading state")
    } else {
      XCTFail("expected state to still be .loading(B), got \(center.state)")
    }
    // Cleanup
    contB.finish()
    center.cancel()
  }

  // MARK: - review v3 F1: ABA on modelID

  func test_aba_on_modelID_drops_stale_terminal_from_first_load() async {
    // Sequence: load(A) → cancel() → load(A) again. Task1's late
    // terminal must NOT clobber task2's state — the modelIDs coincide
    // so ownership-only gating would let it through. Two-epoch model
    // catches it: task1's loadEpoch < current loadEpoch.
    let center = ModelLoadCenter()
    let (stream1, cont1) = AsyncThrowingStream<LoadEvent, Error>.makeStream()
    let (stream2, cont2) = AsyncThrowingStream<LoadEvent, Error>.makeStream()

    center.load(modelID: "A", streamFactory: { stream1 })
    cont1.yield(.loading(loadedBytes: 1, totalBytes: 100, etaSeconds: nil))
    await waitUntil(timeout: 1.0) {
      if case let .loading(_, loaded, _, _) = center.state, loaded == 1 { return true }
      return false
    }
    center.cancel()
    // After cancel(), state synchronously becomes .cancelled(A)
    // (review v3 F3). Now start a NEW load for the same modelID —
    // this is the ABA case.
    center.load(modelID: "A", streamFactory: { stream2 })
    cont2.yield(.loading(loadedBytes: 50, totalBytes: 100, etaSeconds: nil))
    await waitUntil(timeout: 1.0) {
      if case let .loading(_, loaded, _, _) = center.state, loaded == 50 { return true }
      return false
    }

    // Force task1's stream to fail with cancellation NOW. Without
    // the F1-v3 fix, this would set state to .cancelled(A) — task2's
    // .loading(A, 50, 100, nil) gets clobbered.
    cont1.finish(throwing: CancellationError())
    try? await Task.sleep(nanoseconds: 100_000_000)
    if case let .loading(id, loaded, _, _) = center.state {
      XCTAssertEqual(id, "A")
      XCTAssertEqual(loaded, 50, "task1's stale cancel must NOT overwrite task2's loading state")
    } else {
      XCTFail("expected state to still be .loading(A, 50, ...), got \(center.state)")
    }

    // Task2 must still be cancellable — i.e. the orphan-task bug
    // doesn't strand a running consumer.
    center.cancel()
    if case let .cancelled(id) = center.state {
      XCTAssertEqual(id, "A", "task2's cancel must transition state, not be a no-op")
    } else {
      XCTFail("expected .cancelled(A) after cancelling task2, got \(center.state)")
    }
    cont2.finish()
  }

  // MARK: - review v3 F3: cancel() synchronously transitions state

  func test_cancel_synchronously_transitions_loading_to_cancelled() async {
    let center = ModelLoadCenter()
    let (asyncStream, continuation) = AsyncThrowingStream<LoadEvent, Error>.makeStream()
    center.load(modelID: "m1", streamFactory: { asyncStream })
    continuation.yield(.loading(loadedBytes: 1, totalBytes: 100, etaSeconds: nil))
    await waitUntil(timeout: 1.0) {
      if case .loading = center.state { return true }
      return false
    }
    // The transition must happen on the same tick as cancel() — no
    // polling. Callers of cancel() (e.g. the popover Cancel button's
    // .onChange of showPopover) rely on this.
    center.cancel()
    if case let .cancelled(id) = center.state {
      XCTAssertEqual(id, "m1")
    } else {
      XCTFail("cancel() must synchronously transition to .cancelled, got \(center.state)")
    }
    continuation.finish()
  }

  // MARK: - review v4 F1: late producer failure must not rewrite .cancelled

  func test_late_producer_failure_after_cancel_does_not_overwrite_cancelled() async {
    struct DiskBroke: Error {}
    let center = ModelLoadCenter()
    let (asyncStream, continuation) = AsyncThrowingStream<LoadEvent, Error>.makeStream()
    center.load(modelID: "A", streamFactory: { asyncStream })
    continuation.yield(.loading(loadedBytes: 1, totalBytes: 100, etaSeconds: nil))
    await waitUntil(timeout: 1.0) {
      if case .loading = center.state { return true }
      return false
    }
    // User cancels. State flips synchronously to .cancelled(A).
    center.cancel()
    XCTAssertEqual(center.state, .cancelled(modelID: "A"))
    // Producer doesn't honor Task.isCancelled — finishes with a
    // non-CancellationError. Without the v4 F1 guard this would
    // rewrite .cancelled → .failed and the user would see a red ring
    // for a load they explicitly cancelled.
    continuation.finish(throwing: DiskBroke())
    try? await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertEqual(center.state, .cancelled(modelID: "A"),
                   "late producer failure must NOT overwrite the synchronous cancel")
  }

  // MARK: - review v4 F2: late post-loop must not demote .ready → .cancelled

  func test_cancel_after_ready_event_does_not_demote_ready_to_cancelled() async {
    // The race: stream emits .ready, finishReady runs synchronously
    // setting state=.ready(A). User clicks Cancel before the post-loop
    // MainActor.run hop fires. Without the v4 F2 guard, the post-loop
    // saw eventEpoch mismatch + state.id == A and demoted .ready to
    // .cancelled — a verified load reported as cancelled.
    let center = ModelLoadCenter()
    let (asyncStream, continuation) = AsyncThrowingStream<LoadEvent, Error>.makeStream()
    center.load(modelID: "A", streamFactory: { asyncStream })
    // Drive .ready through the stream and wait for finishReady to
    // commit state = .ready(A) on the main actor.
    continuation.yield(.ready)
    continuation.finish()
    await waitUntil(timeout: 1.0) {
      if case .ready = center.state { return true }
      return false
    }
    // Now cancel. Synchronous transition skips because state is not
    // .loading, but eventEpoch still bumps. Post-loop (already queued
    // on @MainActor by the consumer task) may run after this point.
    center.cancel()
    try? await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertEqual(center.state, .ready(modelID: "A"),
                   "post-loop must NOT demote a verified .ready to .cancelled")
    XCTAssertEqual(center.residentModelID, "A",
                   "verified resident must survive the race")
  }

  // MARK: - review v6 F1: post-success producer crash preserves state

  func test_late_failure_after_ready_does_not_overwrite_ready() async {
    // Path (b) from the v6 review: for-await commits .ready in-band
    // via apply(.ready) → finishReady, then the stream throws a
    // non-CancellationError before iter returns nil. State must
    // stay .ready(A) — the producer's late error is diagnostic only.
    // Test captures the user-facing state; the producer error is
    // intentionally surfaced only at .debug (with error= field) so
    // it remains recoverable via log streaming.
    struct DiskBroke: Error {}
    let center = ModelLoadCenter()
    let (asyncStream, continuation) = AsyncThrowingStream<LoadEvent, Error>.makeStream()
    center.load(modelID: "A", streamFactory: { asyncStream })
    continuation.yield(.ready)
    await waitUntil(timeout: 1.0) {
      if case .ready = center.state { return true }
      return false
    }
    // Producer crashes AFTER .ready already committed. The error
    // must not surface as the user-facing terminal.
    continuation.finish(throwing: DiskBroke())
    try? await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertEqual(center.state, .ready(modelID: "A"),
                   "late producer failure after .ready must NOT demote state to .failed")
    XCTAssertEqual(center.residentModelID, "A",
                   "verified resident must survive a post-success producer crash")
  }

  // MARK: - review v1 F14: progress overflow falls through to indeterminate

  func test_progress_returns_nil_when_loaded_exceeds_total() async {
    let center = ModelLoadCenter()
    center.load(
      modelID: "m1",
      streamFactory: openStreamFactory(
        event: .loading(loadedBytes: 1500, totalBytes: 1000, etaSeconds: nil)
      )
    )
    await waitUntil(timeout: 1.0) {
      if case let .loading(_, loaded, _, _) = center.state, loaded == 1500 { return true }
      return false
    }
    XCTAssertNil(center.progress, "loaded > total is a protocol bug — fall through to indeterminate, not pin at 100%")
    center.cancel()
  }

  // MARK: - : engineNotReady is its own terminal

  func test_engineNotReady_error_routes_to_engineNotReady_state() async {
    let center = ModelLoadCenter()
    let factory: @Sendable () -> AsyncThrowingStream<LoadEvent, Error> = { @Sendable in
      AsyncThrowingStream { continuation in
        continuation.finish(throwing: HTTPEngineError.engineNotReady(
          detail: "Engine starting…"
        ))
      }
    }
    center.load(modelID: "m1", streamFactory: factory)

    await waitUntil(timeout: 1.0) {
      if case .engineNotReady = center.state { return true }
      return false
    }
    guard case let .engineNotReady(id, detail) = center.state else {
      XCTFail("expected .engineNotReady, got \(center.state)")
      return
    }
    XCTAssertEqual(id, "m1")
    XCTAssertEqual(detail, "Engine starting…")
    XCTAssertTrue(center.isEngineNotReady)
    XCTAssertNil(center.residentModelID,
                 "engineNotReady must not mark a resident — no engine to host the model")
  }

  func test_engineNotReady_state_is_cleared_by_dismissTerminalState() {
    let center = ModelLoadCenter()
    center._testOverrideState(.engineNotReady(modelID: "m1", detail: "x"))
    XCTAssertTrue(center.isEngineNotReady)
    center.dismissTerminalState()
    XCTAssertEqual(center.state, .idle)
  }

  func test_engineNotReady_does_not_collide_with_generic_failed_path() async {
    struct OtherError: Error {}
    let center = ModelLoadCenter()
    let factory: @Sendable () -> AsyncThrowingStream<LoadEvent, Error> = { @Sendable in
      AsyncThrowingStream { continuation in
        continuation.finish(throwing: OtherError())
      }
    }
    center.load(modelID: "m1", streamFactory: factory)

    await waitUntil(timeout: 1.0) {
      if case .failed = center.state { return true }
      return false
    }
    if case let .failed(id, _) = center.state {
      XCTAssertEqual(id, "m1")
      XCTAssertFalse(center.isEngineNotReady,
                     "generic failures must NOT route through engineNotReady")
    } else {
      XCTFail("expected .failed, got \(center.state)")
    }
  }

  // MARK: -  follow-up: reflect an engine-resident model

  func test_reconcileEngineResident_sets_resident_when_idle() {
    let center = ModelLoadCenter()
    XCTAssertNil(center.residentModelID)

    center.reconcileEngineResident("default")

    XCTAssertEqual(center.residentModelID, "default",
                   "a model the engine already has resident after explicit start or crash recovery must surface so sends aren't blocked")
  }

  func test_reconcileEngineResident_is_noop_during_inflight_load() {
    let center = ModelLoadCenter()
    center.load(modelID: "user-pick") {
      AsyncThrowingStream { _ in /* never finishes — stays in-flight */ }
    }
    XCTAssertTrue(center.isLoading)

    center.reconcileEngineResident("default")

    XCTAssertNotEqual(center.residentModelID, "default",
                      "reconcile must never clobber an explicit user load in flight")
    center.cancel()
  }

  // MARK: - polling helper

  /// Tiny polling helper. The center publishes from an internal Task;
  /// the consuming side observes via `@Published`. Using an
  /// `XCTKVOExpectation` would require KVO conformance the type
  /// doesn't have, so a bounded poll keeps the test rig dependency-free.
  private func waitUntil(
    timeout: TimeInterval,
    condition: () -> Bool
  ) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
  }
}
