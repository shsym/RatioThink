import XCTest
import Combine
@testable import RatioThink

/// #460: the swap policy keys on the chat's CURRENT model SELECTION (passed
/// in as `fromModel` — the single source of truth `Chat.modelID` resolved
/// through the profile default), NOT engine residency. Same-model = silent;
/// no-target-default = silent + PIN the current model (so an unpinned chat
/// keeps its concrete model when the new profile has no default); cross-model
/// = popover (confirm switches + pins the new model, cancel keeps the current
/// one). Model overrides go through `requestModelOverride` and offer "Set as
/// default for this profile". Preserves the review v1/v2/v3 invariants: F3
/// (re-entrancy), F4 (atomic state + token-checked confirm/cancel), F5
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

  /// Captures what a swap/override commit wrote, so the preserve-vs-pin
  /// decision is observable (#460).
  private final class CommitSpy {
    /// Profile committed by a `requestSwap` commit.
    var swappedProfile: String?
    /// Model pinned by a `requestSwap` commit. `nil` ⇒ "leave the model
    /// untouched" (the same-model / no-current-model silent paths); non-nil ⇒
    /// pin it (switch-and-pin the new default, or keep-current on a no-default
    /// swap).
    var pinnedModel: String?
    var swapCommitCount = 0
    /// Model set by a `requestModelOverride` commit.
    var overrodeModel: String?
    /// Injectable result the commit returns — `false` simulates a failed
    /// durable write so `confirm` must skip the load (review F2).
    var commitResult = true
  }

  private struct StubWriteError: Error {}

  private func makeCoordinator(
    map: [String: String?],
    resident: String? = nil,
    setDefaultModelError: Error? = nil
  ) -> (ProfileSwapCoordinator, ModelLoadCenter, DefaultWriteSpy) {
    let center = ModelLoadCenter(initialResident: resident)
    let spy = DefaultWriteSpy()
    spy.errorToThrow = setDefaultModelError
    let coord = ProfileSwapCoordinator(
      center: center,
      modelForProfile: { map[$0] ?? nil },
      setDefaultModel: { profileID, model in
        spy.writes.append((profileID: profileID, model: model))
        if let error = spy.errorToThrow { throw error }
      },
      // #469: a confirmed pick routes through the engine (re)launch executor.
      // Simulate the engine coming up serving the picked model by reconciling
      // residency, so `center.residentModelID` reflects the load the way the
      // production status-aware executor does.
      serveModel: { modelID, _ in center.reconcileEngineResident(modelID) }
    )
    return (coord, center, spy)
  }

  /// A `requestSwap` commit bound to a `CommitSpy`. Returns
  /// `spy.commitResult` so a test can simulate a failed durable write.
  private func swapCommit(_ spy: CommitSpy) -> ProfileSwapCoordinator.SwapCommit {
    { profileID, pinModel in
      spy.swapCommitCount += 1
      spy.swappedProfile = profileID
      spy.pinnedModel = pinModel
      return spy.commitResult
    }
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

  // MARK: - AC1: no-target-default swap PINS (keeps) the current model

  func test_no_target_default_commits_profile_silently_and_pins_current_model() {
    // Profile "next" has no default; the chat is currently on "m1". The swap
    // must commit the profile, fire NO load, and PIN the current model
    // (`pinModel == "m1"`) so an unpinned chat does not lose its concrete
    // model when the new profile has no default to follow (#460-AC1).
    let (coord, center, _) = makeCoordinator(map: ["next": nil], resident: "m1")
    let spy = CommitSpy()
    coord.requestSwap(toProfileID: "next", fromModel: "m1", commit: swapCommit(spy))
    XCTAssertEqual(spy.swappedProfile, "next")
    XCTAssertEqual(spy.pinnedModel, "m1",
                   "no-default swap must PIN the current model so it survives the switch")
    XCTAssertNil(coord.pending)
    // #469: merged ModelLoadCenter is residency-only (no `.state`).
    XCTAssertEqual(center.residentModelID, "m1",
                   "no-default swap: pin only, no load fires — current model stays put")
  }

  func test_no_target_default_pins_a_currently_loading_model() {
    // AC1 "whether already loaded or currently loading": the chat is loading
    // "m1" (fromModel = the loading target, residency still nil). A no-default
    // swap must pin it silently and not disturb the load.
    let (coord, _, _) = makeCoordinator(map: ["next": nil])
    let spy = CommitSpy()
    coord.requestSwap(toProfileID: "next", fromModel: "m1-loading", commit: swapCommit(spy))
    XCTAssertEqual(spy.swappedProfile, "next")
    XCTAssertEqual(spy.pinnedModel, "m1-loading",
                   "a loading model is the current model and must be pinned to survive the switch")
    XCTAssertNil(coord.pending)
  }

  // MARK: - silent paths

  func test_same_model_as_selection_commits_silently_and_skips_popover() {
    let (coord, center, _) = makeCoordinator(map: ["next": "m1"], resident: "m1")
    let spy = CommitSpy()
    coord.requestSwap(toProfileID: "next", fromModel: "m1", commit: swapCommit(spy))
    XCTAssertEqual(spy.swappedProfile, "next")
    XCTAssertNil(spy.pinnedModel)
    XCTAssertNil(coord.pending)
    XCTAssertEqual(center.residentModelID, "m1", "same model: load must not fire")
  }

  ///  inferlet-only invariant: a profile whose default equals the current
  /// model (only inferlet/sampling/system-prompt differ) must NOT confirm or
  /// load. The coordinator keys on model identity.
  func test_same_model_different_inferlet_does_not_confirm_or_load() {
    let (coord, center, _) = makeCoordinator(map: ["docs": "m1"], resident: "m1")
    coord.requestSwap(toProfileID: "docs", fromModel: "m1") { _, _ in true }
    XCTAssertNil(coord.pending, "an inferlet-only change (same model) must not raise the confirm")
    XCTAssertEqual(center.residentModelID, "m1", "an inferlet-only change must not load")
  }

  func test_no_current_model_commits_silently_no_popover() {
    // Policy 1.5: with no current model (`fromModel == nil`) there is nothing
    // to REPLACE, so the selection commits silently and fires NO load.
    let (coord, center, _) = makeCoordinator(map: ["next": "m2"])  // engine stopped, nothing selected
    let spy = CommitSpy()
    coord.requestSwap(toProfileID: "next", fromModel: nil, commit: swapCommit(spy))
    XCTAssertEqual(spy.swappedProfile, "next")
    XCTAssertNil(spy.pinnedModel)
    XCTAssertNil(coord.pending, "no current model → silent swap, no confirm popover")
    // #469: residency-only center (no `.state`/`.idle`); nothing resident.
    XCTAssertNil(center.residentModelID, "no current model: no load fires")
  }

  // MARK: - AC2: different-target-default swap PROMPTS

  func test_cross_model_publishes_pending_without_set_as_default() {
    let (coord, _, _) = makeCoordinator(map: ["next": "m2"], resident: "m1")
    let spy = CommitSpy()
    coord.requestSwap(toProfileID: "next", fromModel: "m1", commit: swapCommit(spy))
    XCTAssertEqual(spy.swapCommitCount, 0, "swap must wait for confirm()")
    guard let pending = coord.pending else { return XCTFail("expected pending swap") }
    XCTAssertEqual(pending.toProfileID, "next")
    XCTAssertEqual(pending.fromModelID, "m1")
    XCTAssertEqual(pending.toModelID, "m2")
    XCTAssertFalse(pending.canSetAsDefault,
                   "a profile swap loads the profile's stored default — 'set as default' would be a no-op")
  }

  /// AC2 loading-aware (scenario 4): switching to a profile whose default
  /// differs from the model the chat is CURRENTLY LOADING must still prompt.
  /// Pre-#460 this read engine residency (nil during a load) and silently
  /// skipped the popover.
  func test_cross_model_prompts_even_while_a_model_is_loading() {
    let (coord, _, _) = makeCoordinator(map: ["next": "m2"])  // nothing resident yet
    coord.requestSwap(toProfileID: "next", fromModel: "m1-loading") { _, _ in true }
    guard let pending = coord.pending else {
      return XCTFail("a differing default must prompt even when the current model is still loading")
    }
    XCTAssertEqual(pending.fromModelID, "m1-loading")
    XCTAssertEqual(pending.toModelID, "m2")
  }

  func test_confirm_commits_swap_pins_new_model_and_kicks_off_load() async throws {
    let (coord, center, _) = makeCoordinator(map: ["next": "m2"], resident: "m1")
    let spy = CommitSpy()
    coord.requestSwap(toProfileID: "next", fromModel: "m1", commit: swapCommit(spy))

    confirmCurrent(coord)
    XCTAssertEqual(spy.swappedProfile, "next")
    XCTAssertEqual(spy.pinnedModel, "m2", "confirm-and-switch must PIN the new model on the chat")
    XCTAssertNil(coord.pending)

    await waitUntil(timeout: 2.0) {
      return center.residentModelID == "m2"
    }
    XCTAssertEqual(center.residentModelID, "m2")
    XCTAssertEqual(center.residentModelID, "m2")
  }

  func test_cancel_keeps_current_model_and_does_not_commit() {
    // AC2 decline: cancelling the "Switch model?" popover keeps the current
    // model — no commit (profile + model both unchanged), no load.
    let (coord, center, _) = makeCoordinator(map: ["next": "m2"], resident: "m1")
    let spy = CommitSpy()
    coord.requestSwap(toProfileID: "next", fromModel: "m1", commit: swapCommit(spy))
    cancelCurrent(coord)
    XCTAssertNil(coord.pending)
    XCTAssertEqual(spy.swapCommitCount, 0, "decline must not commit the swap")
    // #469: merged ModelLoadCenter is residency-only (no `.state`).
    XCTAssertEqual(center.residentModelID, "m1", "decline keeps the current model — no load")
  }

  // MARK: - review F2: a failed commit (pin save) must skip the load

  func test_confirm_with_failed_commit_does_not_load() async throws {
    // The caller's durable model-pin write failed → commit returns false.
    // `confirm` must NOT drive the engine to a model the chat did not adopt;
    // the resident model stays put and no new load fires.
    let (coord, center, _) = makeCoordinator(map: ["next": "m2"], resident: "m1")
    let spy = CommitSpy()
    spy.commitResult = false  // simulate the pin save failing
    coord.requestSwap(toProfileID: "next", fromModel: "m1", commit: swapCommit(spy))
    confirmCurrent(coord)

    XCTAssertEqual(spy.swapCommitCount, 1, "the commit IS invoked on confirm")
    XCTAssertNil(coord.pending)
    // Give any (erroneously) started load a chance to surface, then assert
    // the resident model never changed. #469: a failed commit skips the
    // `serveModel` call, so the residency-only center is the single observable
    // — there is no separate `isLoading`/`.state`. The makeCoordinator's
    // `serveModel` reconciles residency to the picked model, so residency
    // staying at "m1" proves no load fired.
    try? await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertEqual(center.residentModelID, "m1",
                   "a failed commit must not start a load — prior resident untouched")
  }

  func test_confirm_with_succeeding_commit_loads() async throws {
    // Control for the F2 test above: a succeeding commit DOES load.
    let (coord, center, _) = makeCoordinator(map: ["next": "m2"], resident: "m1")
    let spy = CommitSpy()
    spy.commitResult = true
    coord.requestSwap(toProfileID: "next", fromModel: "m1", commit: swapCommit(spy))
    confirmCurrent(coord)
    // #469: the merged `serveModel` reconciles residency to the picked model,
    // so a succeeding commit lands as `residentModelID == "m2"` (no `.state`).
    await waitUntil(timeout: 2.0) {
      center.residentModelID == "m2"
    }
    XCTAssertEqual(center.residentModelID, "m2", "a succeeding commit loads the new model")
  }

  // MARK: - model override + set-as-default

  func test_model_override_different_model_publishes_pending_with_set_as_default() {
    let (coord, _, _) = makeCoordinator(map: [:], resident: "m1")
    var committed: String?
    coord.requestModelOverride(modelID: "m2", activeProfileID: "chat", fromModel: "m1") { committed = $0; return true }
    XCTAssertNil(committed, "override must wait for confirm()")
    guard let pending = coord.pending else { return XCTFail("expected pending override") }
    XCTAssertEqual(pending.toModelID, "m2")
    XCTAssertEqual(pending.fromModelID, "m1")
    XCTAssertTrue(pending.canSetAsDefault, "a model override must offer 'set as default for this profile'")
  }

  func test_model_override_same_as_selection_is_silent_with_no_load() {
    let (coord, center, _) = makeCoordinator(map: [:], resident: "m1")
    var committed: String?
    coord.requestModelOverride(modelID: "m1", activeProfileID: "chat", fromModel: "m1") { committed = $0; return true }
    XCTAssertEqual(committed, "m1", "picking the already-selected model just pins it")
    XCTAssertNil(coord.pending)
    // #469: merged ModelLoadCenter is residency-only (no `.state`).
    XCTAssertEqual(center.residentModelID, "m1", "no reload for the already-selected model")
  }

  func test_model_override_no_current_model_is_silent_with_no_load() {
    // Policy 1.5 parity with `requestSwap` (#486): with NO current model
    // (`fromModel == nil`: engine stopped / unpinned) there is nothing to
    // REPLACE, so the switch-model confirm popover is meaningless. Picking a
    // model from the model menu must commit the override silently and fire NO
    // load — the model loads later through the normal start gate, exactly like
    // a profile swap.
    let (coord, center, _) = makeCoordinator(map: [:])  // engine stopped, nothing selected
    var committed: String?
    coord.requestModelOverride(modelID: "m2", activeProfileID: "chat", fromModel: nil) { committed = $0; return true }
    XCTAssertEqual(committed, "m2", "picking a model with no current model just pins it")
    XCTAssertNil(coord.pending, "no current model → silent override, no confirm popover")
    // #469: merged ModelLoadCenter is residency-only (no `.state`).
    XCTAssertNil(center.residentModelID, "no current model: no load fires")
  }

  func test_confirm_override_with_set_as_default_persists_model_onto_profile() async throws {
    let (coord, center, spy) = makeCoordinator(map: [:], resident: "m1")
    var committed: String?
    coord.requestModelOverride(modelID: "m2", activeProfileID: "chat", fromModel: "m1") { committed = $0; return true }
    confirmCurrent(coord, setAsDefault: true)

    XCTAssertEqual(committed, "m2", "commit pins the per-chat model to the picked model")
    XCTAssertEqual(spy.writes.count, 1)
    XCTAssertEqual(spy.writes.first?.profileID, "chat")
    XCTAssertEqual(spy.writes.first?.model, "m2")
    await waitUntil(timeout: 2.0) {
      return center.residentModelID == "m2"
    }
    XCTAssertEqual(center.residentModelID, "m2", "confirm always loads the chosen model")
  }

  func test_confirm_override_without_set_as_default_does_not_persist() async throws {
    let (coord, center, spy) = makeCoordinator(map: [:], resident: "m1")
    coord.requestModelOverride(modelID: "m2", activeProfileID: "chat", fromModel: "m1") { _ in true }
    confirmCurrent(coord, setAsDefault: false)

    XCTAssertTrue(spy.writes.isEmpty, "unchecked 'set as default' must not persist a profile default")
    await waitUntil(timeout: 2.0) {
      return center.residentModelID == "m2"
    }
    XCTAssertEqual(center.residentModelID, "m2", "the load still happens even without set-as-default")
  }

  func test_confirm_setAsDefault_write_failure_is_surfaced_and_load_still_proceeds() async {
    let (coord, center, _) = makeCoordinator(map: [:], resident: "m1",
                                             setDefaultModelError: StubWriteError())
    coord.requestModelOverride(modelID: "m2", activeProfileID: "chat", fromModel: "m1") { _ in true }
    confirmCurrent(coord, setAsDefault: true)

    XCTAssertNotNil(coord.defaultModelWriteError,
                    "a failed set-as-default write must be surfaced, not swallowed (review F2)")
    await waitUntil(timeout: 2.0) {
      return center.residentModelID == "m2"
    }
    XCTAssertEqual(center.residentModelID, "m2",
                   "the chosen model still loads even when the default-persist failed")
  }

  func test_set_as_default_error_clears_when_user_moves_on() {
    let (coord, _, _) = makeCoordinator(map: [:], resident: "m1",
                                        setDefaultModelError: StubWriteError())
    coord.requestModelOverride(modelID: "m2", activeProfileID: "chat", fromModel: "m1") { _ in true }
    confirmCurrent(coord, setAsDefault: true)
    XCTAssertNotNil(coord.defaultModelWriteError)

    // loadDirect (user picks a model) must clear the stale error even on
    // the already-resident short-circuit (review F2 — no lingering red).
    coord.loadDirect(modelID: "m1", profileID: "chat")
    XCTAssertNil(coord.defaultModelWriteError,
                 "a stale set-as-default error must not persist after the user moves on")
  }

  func test_acknowledge_clears_set_as_default_error() {
    let (coord, _, _) = makeCoordinator(map: [:], resident: "m1",
                                        setDefaultModelError: StubWriteError())
    coord.requestModelOverride(modelID: "m2", activeProfileID: "chat", fromModel: "m1") { _ in true }
    confirmCurrent(coord, setAsDefault: true)
    XCTAssertNotNil(coord.defaultModelWriteError)

    coord.acknowledgeDefaultModelWriteError()
    XCTAssertNil(coord.defaultModelWriteError)
  }

  //  review v3 F2: regression guards for the remaining clear sites
  // (requestSwap, requestModelOverride already-selected, cancel,
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
    coord.requestModelOverride(modelID: "m2", activeProfileID: "chat", fromModel: "m1") { _ in true }
    confirmCurrent(coord, setAsDefault: true)
    return (coord, center)
  }

  func test_requestSwap_clears_stale_set_as_default_error() {
    let (coord, _) = coordinatorWithSurfacedWriteError(map: ["next": "zzz"])
    XCTAssertNotNil(coord.defaultModelWriteError)
    coord.requestSwap(toProfileID: "next", fromModel: "m2") { _, _ in true }
    XCTAssertNil(coord.defaultModelWriteError, "a fresh profile swap must clear the stale error")
  }

  func test_requestModelOverride_already_selected_clears_stale_error() async {
    let (coord, center) = coordinatorWithSurfacedWriteError()
    XCTAssertNotNil(coord.defaultModelWriteError)
    await waitUntil(timeout: 2.0) { center.residentModelID == "m2" }
    // Re-selecting the now-current model hits the already-selected early
    // return, which must still clear the stale error.
    coord.requestModelOverride(modelID: "m2", activeProfileID: "chat", fromModel: "m2") { _ in true }
    XCTAssertNil(coord.pending, "selecting the current model is a silent no-op")
    XCTAssertNil(coord.defaultModelWriteError)
  }

  func test_cancel_leaves_no_stale_set_as_default_error() {
    let (coord, _) = coordinatorWithSurfacedWriteError(map: ["next": "zzz"])
    XCTAssertNotNil(coord.defaultModelWriteError)
    coord.requestSwap(toProfileID: "next", fromModel: "m2") { _, _ in true }
    cancelCurrent(coord)
    XCTAssertNil(coord.defaultModelWriteError, "no stale error must survive a cancel flow")
  }

  func test_dismissCurrentPending_leaves_no_stale_set_as_default_error() {
    let (coord, _) = coordinatorWithSurfacedWriteError(map: ["next": "zzz"])
    XCTAssertNotNil(coord.defaultModelWriteError)
    coord.requestSwap(toProfileID: "next", fromModel: "m2") { _, _ in true }
    coord.dismissCurrentPending()
    XCTAssertNil(coord.defaultModelWriteError, "no stale error must survive a dismiss flow")
  }

  func test_confirm_setAsDefault_success_clears_write_error() {
    let (coord, _, spy) = makeCoordinator(map: [:], resident: "m1")
    coord.requestModelOverride(modelID: "m2", activeProfileID: "chat", fromModel: "m1") { _ in true }
    confirmCurrent(coord, setAsDefault: true)
    XCTAssertNil(coord.defaultModelWriteError)
    XCTAssertEqual(spy.writes.count, 1)
  }

  func test_profile_swap_confirm_with_setAsDefault_is_a_noop_persist() {
    // A profile swap pending has no set-as-default target; even if a
    // caller passes setAsDefault: true, nothing is persisted.
    let (coord, _, spy) = makeCoordinator(map: ["next": "m2"], resident: "m1")
    coord.requestSwap(toProfileID: "next", fromModel: "m1") { _, _ in true }
    confirmCurrent(coord, setAsDefault: true)
    XCTAssertTrue(spy.writes.isEmpty, "profile swap must never persist a default — the model already is the profile's default")
  }

  // MARK: - review v1 F3: re-entrancy

  func test_reentrant_requestSwap_cancels_prior_and_publishes_new_pending() {
    let (coord, _, _) = makeCoordinator(map: ["b": "m_b", "c": "m_c"], resident: "m_a")
    let first = CommitSpy()
    let second = CommitSpy()
    coord.requestSwap(toProfileID: "b", fromModel: "m_a", commit: swapCommit(first))
    coord.requestSwap(toProfileID: "c", fromModel: "m_a", commit: swapCommit(second))

    XCTAssertEqual(first.swapCommitCount, 0, "first commit must NOT fire — superseded")
    XCTAssertEqual(second.swapCommitCount, 0, "second commit waits for confirm()")
    XCTAssertEqual(coord.pending?.toProfileID, "c")
    XCTAssertEqual(coord.pending?.toModelID, "m_c")

    confirmCurrent(coord)
    XCTAssertEqual(first.swapCommitCount, 0, "even after confirm, the older commit must stay dropped")
    XCTAssertEqual(second.swappedProfile, "c")
    XCTAssertEqual(second.pinnedModel, "m_c")
  }

  // MARK: - review v2 F4: token-checked confirm/cancel

  func test_stale_confirm_token_from_superseded_swap_is_dropped() {
    let (coord, _, _) = makeCoordinator(map: ["b": "m_b", "c": "m_c"], resident: "m_a")
    let first = CommitSpy()
    let second = CommitSpy()
    coord.requestSwap(toProfileID: "b", fromModel: "m_a", commit: swapCommit(first))
    let staleToken = coord.pending!.id
    coord.requestSwap(toProfileID: "c", fromModel: "m_a", commit: swapCommit(second))
    coord.confirm(token: staleToken, setAsDefault: false)
    XCTAssertEqual(first.swapCommitCount, 0, "stale token must NOT commit superseded swap")
    XCTAssertEqual(second.swapCommitCount, 0, "stale token must NOT commit current swap either")
    XCTAssertEqual(coord.pending?.toProfileID, "c", "current pending stays put")
  }

  func test_stale_cancel_token_does_not_clobber_current_pending() {
    let (coord, _, _) = makeCoordinator(map: ["b": "m_b", "c": "m_c"], resident: "m_a")
    coord.requestSwap(toProfileID: "b", fromModel: "m_a") { _, _ in true }
    let staleToken = coord.pending!.id
    coord.requestSwap(toProfileID: "c", fromModel: "m_a") { _, _ in true }
    coord.cancel(token: staleToken)
    XCTAssertEqual(coord.pending?.toProfileID, "c", "stale cancel must NOT clear the new pending")
  }

  // MARK: - review v3 F2: re-entry never publishes a transient nil

  func test_reentry_does_not_publish_transient_nil_pending() {
    let (coord, _, _) = makeCoordinator(map: ["b": "m_b", "c": "m_c"], resident: "m_a")
    coord.requestSwap(toProfileID: "b", fromModel: "m_a") { _, _ in true }
    let priorID = coord.pending?.id
    XCTAssertNotNil(priorID)

    var observed: [UUID?] = []
    let cancellable = coord.$pending.sink { observed.append($0?.id) }
    defer { cancellable.cancel() }

    coord.requestSwap(toProfileID: "c", fromModel: "m_a") { _, _ in true }

    let transitions = Array(observed.dropFirst())
    XCTAssertFalse(transitions.contains(nil),
                   "re-entrant requestSwap must NOT publish a transient nil pending — observed: \(transitions.map { $0?.uuidString ?? "nil" })")
    XCTAssertEqual(coord.pending?.toProfileID, "c")
    XCTAssertNotEqual(coord.pending?.id, priorID, "token must rotate on re-entry")
  }

  // MARK: - #460 single source of truth: from-model is the PASSED selection

  func test_from_model_is_the_passed_selection_not_engine_residency() {
    // The coordinator must compare against the SELECTION the caller passes,
    // independent of what the engine has resident.
    let (coord, _, _) = makeCoordinator(
      map: ["next": "m_target"],
      resident: "m_resident_differs"
    )
    coord.requestSwap(toProfileID: "next", fromModel: "m_selected") { _, _ in true }
    XCTAssertEqual(coord.pending?.fromModelID, "m_selected",
                   "policy keys on the passed selection, not engine residency")
    XCTAssertEqual(coord.pending?.toModelID, "m_target")
  }

  // MARK: - review v1 F5: loadDirect short-circuit (used by the no-model prompt's Load)

  func test_loadDirect_short_circuits_when_model_already_resident() {
    let (coord, center, _) = makeCoordinator(map: [:], resident: "m1")
    coord.loadDirect(modelID: "m1", profileID: "chat")
    XCTAssertEqual(center.residentModelID, "m1",
                   "loadDirect on the resident model must be a no-op — resident unchanged")
  }

  func test_loadDirect_fires_load_when_model_differs() async throws {
    let (coord, center, _) = makeCoordinator(map: [:], resident: "m1")
    coord.loadDirect(modelID: "m2", profileID: "chat")
    await waitUntil(timeout: 2.0) {
      return center.residentModelID == "m2"
    }
    XCTAssertEqual(center.residentModelID, "m2")
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
    coord.requestSwap(toProfileID: "next", fromModel: "m1") { _, _ in true }
    confirmCurrent(coord)
    coord.dismissCurrentPending()
    XCTAssertNil(coord.pending)
    await waitUntil(timeout: 2.0) {
      return center.residentModelID == "m2"
    }
    XCTAssertEqual(center.residentModelID, "m2")
  }

  // MARK: - #469: a confirmed pick routes through the engine (re)launch executor

  /// Records `serveModel(modelID, profileID)` calls so the #469 routing is
  /// observable without an `EngineStatusStore`. `errorToThrow` simulates a
  /// resolver-reject the status poll won't reflect (→ `serveModelError`).
  private final class ServeSpy: @unchecked Sendable {
    var calls: [(modelID: String, profileID: String)] = []
    var errorToThrow: Error?
  }

  private func makeServeRoutingCoordinator(
    map: [String: String?],
    resident: String? = nil
  ) -> (ProfileSwapCoordinator, ServeSpy) {
    let center = ModelLoadCenter(initialResident: resident)
    let spy = ServeSpy()
    let coord = ProfileSwapCoordinator(
      center: center,
      modelForProfile: { map[$0] ?? nil },
      serveModel: { modelID, profileID in
        spy.calls.append((modelID: modelID, profileID: profileID))
        if let error = spy.errorToThrow { throw error }
      }
    )
    return (coord, spy)
  }

  func test_confirmedPick_routesThroughServeModel_withProfile() async {
    // A toolbar pick of a different model, once confirmed, must (re)launch the
    // engine on the active profile via the executor — NOT a `/v1/models/load`.
    let (coord, spy) = makeServeRoutingCoordinator(map: [:], resident: "m1")
    // #460: the override keys on the chat's current model (`fromModel`); picking
    // a different one (m2 ≠ m1) raises the confirm. The commit returns Bool.
    coord.requestModelOverride(modelID: "m2", activeProfileID: "fast-think", fromModel: "m1") { _ in true }
    confirmCurrent(coord)
    await waitUntil(timeout: 2.0) { !spy.calls.isEmpty }
    XCTAssertEqual(spy.calls.count, 1)
    XCTAssertEqual(spy.calls.first?.modelID, "m2")
    XCTAssertEqual(spy.calls.first?.profileID, "fast-think",
                   "the pick must (re)launch on the pending's active profile")
  }

  func test_loadDirect_routesThroughServeModel_whenModelDiffers() async {
    let (coord, spy) = makeServeRoutingCoordinator(map: [:], resident: "m1")
    coord.loadDirect(modelID: "m2", profileID: "chat")
    await waitUntil(timeout: 2.0) { !spy.calls.isEmpty }
    XCTAssertEqual(spy.calls.map(\.modelID), ["m2"])
    XCTAssertEqual(spy.calls.first?.profileID, "chat")
  }

  func test_loadDirect_shortCircuit_doesNotInvokeServeModel() async {
    let (coord, spy) = makeServeRoutingCoordinator(map: [:], resident: "m1")
    coord.loadDirect(modelID: "m1", profileID: "chat")   // already resident
    // Give any erroneous async serve a chance to fire before asserting absence.
    try? await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertTrue(spy.calls.isEmpty, "an already-resident pick must not (re)launch the engine")
  }

  func test_serveModelFailure_surfacesServeModelError() async {
    let (coord, spy) = makeServeRoutingCoordinator(map: [:], resident: "m1")
    spy.errorToThrow = StubWriteError()
    coord.loadDirect(modelID: "m2", profileID: "chat")
    await waitUntil(timeout: 2.0) { coord.serveModelError != nil }
    XCTAssertNotNil(coord.serveModelError,
                    "a resolver-reject the status poll won't reflect must be surfaced")
  }

  func test_secondPick_clearsPriorServeModelError_synchronously() async {
    // review v2 F2: the error dismissal must run SYNCHRONOUSLY at the pick,
    // not inside the async serve `Task` — otherwise two rapid picks race over
    // the surfaced error. Surface an error from pick 1, then issue pick 2 and
    // assert the prior error is gone the instant `loadDirect` returns. Pick 2
    // keeps failing, so the ONLY way the error can be nil at this point is the
    // synchronous clear (the async catch would re-set it, never clear it).
    let (coord, spy) = makeServeRoutingCoordinator(map: [:], resident: "m1")
    spy.errorToThrow = StubWriteError()
    coord.loadDirect(modelID: "m2", profileID: "chat")
    await waitUntil(timeout: 2.0) { coord.serveModelError != nil }
    XCTAssertNotNil(coord.serveModelError, "precondition: pick 1 surfaced an error")

    coord.loadDirect(modelID: "m3", profileID: "chat")
    XCTAssertNil(coord.serveModelError,
                 "pick 2 must clear the prior error synchronously, before its Task runs")
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
