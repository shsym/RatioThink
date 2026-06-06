import XCTest
import Combine
@testable import RatioThink

/// : same-model = silent, cross-model = popover (always confirmed —
/// the per-model skip-set is gone). Model overrides go through
/// `requestModelOverride` and offer "Set as default for this profile".
/// Preserves the review v1/v2/v3 invariants: F3 (re-entrancy), F4
/// (source-of-truth + atomic state + token-checked confirm/cancel), F5
/// (loadDirect short-circuit), F8 (no-pending no-op).
@MainActor
final class ProfileSwapCoordinatorTests: XCTestCase {

  // MARK: - scaffolding

  /// Captures `setDefaultModel(profileID, model)` calls so the
  /// set-as-default path is observable without a real ProfileStore.
  /// `errorToThrow` simulates a failed persist (review F2).
  private final class DefaultWriteSpy {
    var writes: [(profileID: String, model: String)] = []
    var errorToThrow: Error?
  }

  private struct StubWriteError: Error {}

  /// `MockEngineClient` whose `sleep` seam is a no-op (see prior note):
  /// removes the cooperative hops that would race the consumer's
  /// @MainActor for-await against the producer in tests.
  private func makeFastEngine() -> MockEngineClient {
    MockEngineClient(
      config: .init(
        loadStepInterval: .milliseconds(0),
        chatStepInterval: .milliseconds(0),
        loadSteps: 1,
        totalBytes: 100
      ),
      sleep: { _ in }
    )
  }

  private func makeCoordinator(
    map: [String: String?],
    resident: String? = nil,
    setDefaultModelError: Error? = nil
  ) -> (ProfileSwapCoordinator, ModelLoadCenter, DefaultWriteSpy) {
    let center = ModelLoadCenter(initialResident: resident)
    let engine = makeFastEngine()
    let spy = DefaultWriteSpy()
    spy.errorToThrow = setDefaultModelError
    let coord = ProfileSwapCoordinator(
      center: center,
      engine: engine,
      modelForProfile: { map[$0] ?? nil },
      setDefaultModel: { profileID, model in
        spy.writes.append((profileID: profileID, model: model))
        if let error = spy.errorToThrow { throw error }
      }
    )
    return (coord, center, spy)
  }

  private func confirmCurrent(_ coord: ProfileSwapCoordinator, setAsDefault: Bool = false) {
    guard let token = coord.pending?.id else {
      return XCTFail("confirmCurrent called without a pending swap")
    }
    coord.confirm(token: token, setAsDefault: setAsDefault)
  }

  private func cancelCurrent(_ coord: ProfileSwapCoordinator) {
    guard let token = coord.pending?.id else { return }
    coord.cancel(token: token)
  }

  // MARK: - silent paths (no load without confirm)

  func test_unknown_target_model_commits_silently_and_fires_no_load() {
    let (coord, center, _) = makeCoordinator(map: ["next": nil], resident: "m1")
    var committed: String?

    coord.requestSwap(toProfileID: "next") { committed = $0 }
    XCTAssertEqual(committed, "next")
    XCTAssertNil(coord.pending)
    XCTAssertEqual(center.state, .ready(modelID: "m1"),
                   "unknown target model: no load fires, resident stays put (no deferred silent load)")
  }

  func test_same_model_as_resident_commits_silently_and_skips_popover() {
    let (coord, center, _) = makeCoordinator(map: ["next": "m1"], resident: "m1")
    var committed: String?
    coord.requestSwap(toProfileID: "next") { committed = $0 }
    XCTAssertEqual(committed, "next")
    XCTAssertNil(coord.pending)
    XCTAssertEqual(center.state, .ready(modelID: "m1"), "same model: load must not fire")
  }

  ///  inferlet-only invariant: a profile whose model equals the
  /// resident model (only inferlet/sampling/system-prompt differ) must
  /// NOT confirm or load. The coordinator keys on model identity, so a
  /// same-model swap is silent regardless of other profile fields.
  func test_same_model_different_inferlet_does_not_confirm_or_load() {
    let (coord, center, _) = makeCoordinator(map: ["docs": "m1"], resident: "m1")
    coord.requestSwap(toProfileID: "docs") { _ in }
    XCTAssertNil(coord.pending, "an inferlet-only change (same model) must not raise the confirm")
    XCTAssertEqual(center.state, .ready(modelID: "m1"), "an inferlet-only change must not load")
  }

  // MARK: - cross-model profile swap

  func test_cross_model_publishes_pending_without_set_as_default() {
    let (coord, _, _) = makeCoordinator(map: ["next": "m2"], resident: "m1")
    var committed: String?
    coord.requestSwap(toProfileID: "next") { committed = $0 }
    XCTAssertNil(committed, "swap must wait for confirm()")
    guard let pending = coord.pending else { return XCTFail("expected pending swap") }
    XCTAssertEqual(pending.toProfileID, "next")
    XCTAssertEqual(pending.fromModelID, "m1")
    XCTAssertEqual(pending.toModelID, "m2")
    XCTAssertFalse(pending.canSetAsDefault,
                   "a profile swap loads the profile's stored default — 'set as default' would be a no-op")
  }

  func test_confirm_commits_swap_and_kicks_off_load() async throws {
    let (coord, center, _) = makeCoordinator(map: ["next": "m2"], resident: "m1")
    var committed: String?
    coord.requestSwap(toProfileID: "next") { committed = $0 }

    confirmCurrent(coord)
    XCTAssertEqual(committed, "next")
    XCTAssertNil(coord.pending)

    await waitUntil(timeout: 2.0) {
      if case .ready = center.state { return true }
      return false
    }
    XCTAssertEqual(center.state, .ready(modelID: "m2"))
    XCTAssertEqual(center.residentModelID, "m2")
  }

  func test_cancel_clears_pending_and_does_not_commit() {
    let (coord, center, _) = makeCoordinator(map: ["next": "m2"], resident: "m1")
    var committed: String?
    coord.requestSwap(toProfileID: "next") { committed = $0 }
    cancelCurrent(coord)
    XCTAssertNil(coord.pending)
    XCTAssertNil(committed)
    XCTAssertEqual(center.state, .ready(modelID: "m1"))
  }

  // MARK: - model override + set-as-default ( step 5)

  func test_model_override_different_model_publishes_pending_with_set_as_default() {
    let (coord, _, _) = makeCoordinator(map: [:], resident: "m1")
    var committed: String?
    coord.requestModelOverride(modelID: "m2", activeProfileID: "chat") { committed = $0 }
    XCTAssertNil(committed, "override must wait for confirm()")
    guard let pending = coord.pending else { return XCTFail("expected pending override") }
    XCTAssertEqual(pending.toModelID, "m2")
    XCTAssertEqual(pending.fromModelID, "m1")
    XCTAssertTrue(pending.canSetAsDefault, "a model override must offer 'set as default for this profile'")
  }

  func test_model_override_same_as_resident_is_silent_with_no_load() {
    let (coord, center, _) = makeCoordinator(map: [:], resident: "m1")
    var committed: String?
    coord.requestModelOverride(modelID: "m1", activeProfileID: "chat") { committed = $0 }
    XCTAssertEqual(committed, "m1", "picking the already-resident model just sets the override")
    XCTAssertNil(coord.pending)
    XCTAssertEqual(center.state, .ready(modelID: "m1"), "no reload for the already-resident model")
  }

  func test_confirm_override_with_set_as_default_persists_model_onto_profile() async throws {
    let (coord, center, spy) = makeCoordinator(map: [:], resident: "m1")
    var committed: String?
    coord.requestModelOverride(modelID: "m2", activeProfileID: "chat") { committed = $0 }
    confirmCurrent(coord, setAsDefault: true)

    XCTAssertEqual(committed, "m2", "commit sets the per-chat override to the picked model")
    XCTAssertEqual(spy.writes.count, 1)
    XCTAssertEqual(spy.writes.first?.profileID, "chat")
    XCTAssertEqual(spy.writes.first?.model, "m2")
    await waitUntil(timeout: 2.0) {
      if case .ready = center.state { return true }
      return false
    }
    XCTAssertEqual(center.residentModelID, "m2", "confirm always loads the chosen model")
  }

  func test_confirm_override_without_set_as_default_does_not_persist() async throws {
    let (coord, center, spy) = makeCoordinator(map: [:], resident: "m1")
    coord.requestModelOverride(modelID: "m2", activeProfileID: "chat") { _ in }
    confirmCurrent(coord, setAsDefault: false)

    XCTAssertTrue(spy.writes.isEmpty, "unchecked 'set as default' must not persist a profile default")
    await waitUntil(timeout: 2.0) {
      if case .ready = center.state { return true }
      return false
    }
    XCTAssertEqual(center.residentModelID, "m2", "the load still happens even without set-as-default")
  }

  func test_confirm_setAsDefault_write_failure_is_surfaced_and_load_still_proceeds() async {
    let (coord, center, _) = makeCoordinator(map: [:], resident: "m1",
                                             setDefaultModelError: StubWriteError())
    coord.requestModelOverride(modelID: "m2", activeProfileID: "chat") { _ in }
    confirmCurrent(coord, setAsDefault: true)

    XCTAssertNotNil(coord.defaultModelWriteError,
                    "a failed set-as-default write must be surfaced, not swallowed (review F2)")
    await waitUntil(timeout: 2.0) {
      if case .ready = center.state { return true }
      return false
    }
    XCTAssertEqual(center.residentModelID, "m2",
                   "the chosen model still loads even when the default-persist failed")
  }

  func test_set_as_default_error_clears_when_user_moves_on() {
    let (coord, _, _) = makeCoordinator(map: [:], resident: "m1",
                                        setDefaultModelError: StubWriteError())
    coord.requestModelOverride(modelID: "m2", activeProfileID: "chat") { _ in }
    confirmCurrent(coord, setAsDefault: true)
    XCTAssertNotNil(coord.defaultModelWriteError)

    // loadDirect (user picks a model) must clear the stale error even on
    // the already-resident short-circuit (review F2 — no lingering red).
    coord.loadDirect(modelID: "m1")
    XCTAssertNil(coord.defaultModelWriteError,
                 "a stale set-as-default error must not persist after the user moves on")
  }

  func test_acknowledge_clears_set_as_default_error() {
    let (coord, _, _) = makeCoordinator(map: [:], resident: "m1",
                                        setDefaultModelError: StubWriteError())
    coord.requestModelOverride(modelID: "m2", activeProfileID: "chat") { _ in }
    confirmCurrent(coord, setAsDefault: true)
    XCTAssertNotNil(coord.defaultModelWriteError)

    coord.acknowledgeDefaultModelWriteError()
    XCTAssertNil(coord.defaultModelWriteError)
  }

  //  review v3 F2: regression guards for the remaining clear sites
  // (requestSwap, requestModelOverride already-resident, cancel,
  // dismissCurrentPending) so a future edit can't reintroduce a stale
  // toolbar error.

  /// Drive a coordinator into the surfaced "set-as-default write failed"
  /// state (error shown, model loading).
  private func coordinatorWithSurfacedWriteError(
    map: [String: String?] = [:],
    resident: String? = "m1"
  ) -> (ProfileSwapCoordinator, ModelLoadCenter) {
    let (coord, center, _) = makeCoordinator(map: map, resident: resident,
                                             setDefaultModelError: StubWriteError())
    coord.requestModelOverride(modelID: "m2", activeProfileID: "chat") { _ in }
    confirmCurrent(coord, setAsDefault: true)
    return (coord, center)
  }

  func test_requestSwap_clears_stale_set_as_default_error() {
    let (coord, _) = coordinatorWithSurfacedWriteError(map: ["next": "zzz"])
    XCTAssertNotNil(coord.defaultModelWriteError)
    coord.requestSwap(toProfileID: "next") { _ in }
    XCTAssertNil(coord.defaultModelWriteError, "a fresh profile swap must clear the stale error")
  }

  func test_requestModelOverride_already_resident_clears_stale_error() async {
    let (coord, center) = coordinatorWithSurfacedWriteError()
    XCTAssertNotNil(coord.defaultModelWriteError)
    await waitUntil(timeout: 2.0) { center.residentModelID == "m2" }
    // Re-selecting the now-resident model hits the already-resident
    // early return, which must still clear the stale error.
    coord.requestModelOverride(modelID: "m2", activeProfileID: "chat") { _ in }
    XCTAssertNil(coord.pending, "selecting the resident model is a silent no-op")
    XCTAssertNil(coord.defaultModelWriteError)
  }

  func test_cancel_leaves_no_stale_set_as_default_error() {
    let (coord, _) = coordinatorWithSurfacedWriteError(map: ["next": "zzz"])
    XCTAssertNotNil(coord.defaultModelWriteError)
    coord.requestSwap(toProfileID: "next") { _ in }
    cancelCurrent(coord)
    XCTAssertNil(coord.defaultModelWriteError, "no stale error must survive a cancel flow")
  }

  func test_dismissCurrentPending_leaves_no_stale_set_as_default_error() {
    let (coord, _) = coordinatorWithSurfacedWriteError(map: ["next": "zzz"])
    XCTAssertNotNil(coord.defaultModelWriteError)
    coord.requestSwap(toProfileID: "next") { _ in }
    coord.dismissCurrentPending()
    XCTAssertNil(coord.defaultModelWriteError, "no stale error must survive a dismiss flow")
  }

  func test_confirm_setAsDefault_success_clears_write_error() {
    let (coord, _, spy) = makeCoordinator(map: [:], resident: "m1")
    coord.requestModelOverride(modelID: "m2", activeProfileID: "chat") { _ in }
    confirmCurrent(coord, setAsDefault: true)
    XCTAssertNil(coord.defaultModelWriteError)
    XCTAssertEqual(spy.writes.count, 1)
  }

  func test_profile_swap_confirm_with_setAsDefault_is_a_noop_persist() {
    // A profile swap pending has no set-as-default target; even if a
    // caller passes setAsDefault: true, nothing is persisted.
    let (coord, _, spy) = makeCoordinator(map: ["next": "m2"], resident: "m1")
    coord.requestSwap(toProfileID: "next") { _ in }
    confirmCurrent(coord, setAsDefault: true)
    XCTAssertTrue(spy.writes.isEmpty, "profile swap must never persist a default — the model already is the profile's default")
  }

  // MARK: - review v1 F3: re-entrancy

  func test_reentrant_requestSwap_cancels_prior_and_publishes_new_pending() {
    let (coord, _, _) = makeCoordinator(map: ["b": "m_b", "c": "m_c"], resident: "m_a")
    var firstCommitted: String?
    var secondCommitted: String?
    coord.requestSwap(toProfileID: "b") { firstCommitted = $0 }
    coord.requestSwap(toProfileID: "c") { secondCommitted = $0 }

    XCTAssertNil(firstCommitted, "first commit must NOT fire — superseded")
    XCTAssertNil(secondCommitted, "second commit waits for confirm()")
    XCTAssertEqual(coord.pending?.toProfileID, "c")
    XCTAssertEqual(coord.pending?.toModelID, "m_c")

    confirmCurrent(coord)
    XCTAssertNil(firstCommitted, "even after confirm, the older commit must stay dropped")
    XCTAssertEqual(secondCommitted, "c")
  }

  // MARK: - review v2 F4: token-checked confirm/cancel

  func test_stale_confirm_token_from_superseded_swap_is_dropped() {
    let (coord, _, _) = makeCoordinator(map: ["b": "m_b", "c": "m_c"], resident: "m_a")
    var firstCommitted: String?
    var secondCommitted: String?
    coord.requestSwap(toProfileID: "b") { firstCommitted = $0 }
    let staleToken = coord.pending!.id
    coord.requestSwap(toProfileID: "c") { secondCommitted = $0 }
    coord.confirm(token: staleToken, setAsDefault: false)
    XCTAssertNil(firstCommitted, "stale token must NOT commit superseded swap")
    XCTAssertNil(secondCommitted, "stale token must NOT commit current swap either")
    XCTAssertEqual(coord.pending?.toProfileID, "c", "current pending stays put")
  }

  func test_stale_cancel_token_does_not_clobber_current_pending() {
    let (coord, _, _) = makeCoordinator(map: ["b": "m_b", "c": "m_c"], resident: "m_a")
    coord.requestSwap(toProfileID: "b") { _ in }
    let staleToken = coord.pending!.id
    coord.requestSwap(toProfileID: "c") { _ in }
    coord.cancel(token: staleToken)
    XCTAssertEqual(coord.pending?.toProfileID, "c", "stale cancel must NOT clear the new pending")
  }

  // MARK: - review v3 F2: re-entry never publishes a transient nil

  func test_reentry_does_not_publish_transient_nil_pending() {
    let (coord, _, _) = makeCoordinator(map: ["b": "m_b", "c": "m_c"], resident: "m_a")
    coord.requestSwap(toProfileID: "b") { _ in }
    let priorID = coord.pending?.id
    XCTAssertNotNil(priorID)

    var observed: [UUID?] = []
    let cancellable = coord.$pending.sink { observed.append($0?.id) }
    defer { cancellable.cancel() }

    coord.requestSwap(toProfileID: "c") { _ in }

    let transitions = Array(observed.dropFirst())
    XCTAssertFalse(transitions.contains(nil),
                   "re-entrant requestSwap must NOT publish a transient nil pending — observed: \(transitions.map { $0?.uuidString ?? "nil" })")
    XCTAssertEqual(coord.pending?.toProfileID, "c")
    XCTAssertNotEqual(coord.pending?.id, priorID, "token must rotate on re-entry")
  }

  // MARK: - review v1 F4: from-source-of-truth

  func test_from_model_comes_from_resident_only_not_profile_map() {
    let (coord, _, _) = makeCoordinator(
      map: ["current": "m_claimed", "next": "m_target"],
      resident: "m_real"
    )
    coord.requestSwap(toProfileID: "next") { _ in }
    XCTAssertEqual(coord.pending?.fromModelID, "m_real")
    XCTAssertEqual(coord.pending?.toModelID, "m_target")
  }

  func test_no_resident_yet_commits_silently_no_popover() {
    // Policy 1.5 (`ProfileSwapCoordinator.requestSwap`): with nothing
    // resident there is no model to REPLACE, so a swap-confirm popover is
    // meaningless. The selection commits silently and fires NO load — the
    // model loads later through the normal start gate. Mirrors the sibling
    // silent-swap tests above.
    let (coord, center, _) = makeCoordinator(map: ["next": "m2"])  // no resident
    var committed: String?
    coord.requestSwap(toProfileID: "next") { committed = $0 }
    XCTAssertEqual(committed, "next")
    XCTAssertNil(coord.pending, "no resident → silent swap, no confirm popover")
    XCTAssertEqual(center.state, .idle, "no resident: no load fires")
  }

  // MARK: - review v1 F5: loadDirect short-circuit (used by the no-model prompt's Load)

  func test_loadDirect_short_circuits_when_model_already_resident() {
    let (coord, center, _) = makeCoordinator(map: [:], resident: "m1")
    let stateBefore = center.state
    coord.loadDirect(modelID: "m1")
    XCTAssertEqual(center.state, stateBefore, "loadDirect on resident model must be a no-op — no flash")
  }

  func test_loadDirect_fires_load_when_model_differs() async throws {
    let (coord, center, _) = makeCoordinator(map: [:], resident: "m1")
    coord.loadDirect(modelID: "m2")
    await waitUntil(timeout: 2.0) {
      if case .ready = center.state { return true }
      return false
    }
    XCTAssertEqual(center.state, .ready(modelID: "m2"))
  }

  // MARK: - review v1 F8: confirm/cancel without pending no-ops

  func test_confirm_without_pending_no_ops() {
    let (coord, _, spy) = makeCoordinator(map: [:], resident: "m1")
    coord.confirm(token: UUID(), setAsDefault: true)
    XCTAssertTrue(spy.writes.isEmpty)
    XCTAssertNil(coord.pending)
  }

  func test_dismissal_after_confirm_is_idempotent() async throws {
    let (coord, center, _) = makeCoordinator(map: ["next": "m2"], resident: "m1")
    coord.requestSwap(toProfileID: "next") { _ in }
    confirmCurrent(coord)
    coord.dismissCurrentPending()
    XCTAssertNil(coord.pending)
    await waitUntil(timeout: 2.0) {
      if case .ready = center.state { return true }
      return false
    }
    XCTAssertEqual(center.state, .ready(modelID: "m2"))
  }

  // MARK: - helpers

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
