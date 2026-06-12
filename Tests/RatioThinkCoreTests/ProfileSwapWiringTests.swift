import XCTest
import Foundation
@testable import RatioThinkCore

/// : the production `ProfileSwapCoordinator` is built inline in
/// `RatioThinkApp` with no `modelForProfile` closure, so policy-1 ("unknown
/// target model") always fires and the swap-confirm popover is DEAD in
/// production. These tests bind the production construction to a single
/// `ProfileStore`-backed initializer and prove the popover now fires on
/// a model-changing swap.
@MainActor
final class ProfileSwapWiringTests: XCTestCase {

  private func withTwoProfileStore(_ body: (ProfileStore) throws -> Void) throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("pie-swapwiring-\(UUID().uuidString)", isDirectory: true)
    let dir = root.appendingPathComponent("profiles", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    for (id, model) in [("alpha", "model-A.gguf"), ("beta", "model-B.gguf")] {
      let toml = """
      id = "\(id)"
      name = "\(id)"
      model = "\(model)"
      inferlet = "chat-apc"
      """
      try toml.write(to: dir.appendingPathComponent("\(id).toml"),
                     atomically: true, encoding: .utf8)
    }
    let store = ProfileStore(directory: dir)
    try store.start()
    defer { store.stop() }
    try body(store)
  }

  func test_profileStore_backed_coordinator_fires_popover_on_model_changing_swap() throws {
    try withTwoProfileStore { store in
      let coord = ProfileSwapCoordinator(
        // #460 keys the swap on the passed `fromModel`, not residency (no
        // seeded resident needed); #469 drops `engine:` for `serveModel:`.
        center: ModelLoadCenter(),
        profileStore: store,
        serveModel: { _, _ in }
      )

      var committed: String?
      // #460: the "current model" is the chat's selection passed in, NOT
      // engine residency — here the chat is on model-A.
      coord.requestSwap(toProfileID: "beta", fromModel: "model-A.gguf") { profileID, _ in committed = profileID; return true }

      XCTAssertNil(committed, "a model-changing swap must wait for confirm, not commit silently")
      let pending = try XCTUnwrap(coord.pending,
                                  "popover must fire on a model-changing swap (dead in prod before  wiring)")
      XCTAssertEqual(pending.toProfileID, "beta")
      XCTAssertEqual(pending.fromModelID, "model-A.gguf")
      XCTAssertEqual(pending.toModelID, "model-B.gguf")
    }
  }

  func test_profileStore_backed_coordinator_stays_silent_for_same_model() throws {
    try withTwoProfileStore { store in
      let coord = ProfileSwapCoordinator(
        center: ModelLoadCenter(),
        profileStore: store,
        serveModel: { _, _ in }
      )
      var committed: String?
      var preservedModel = true
      // The chat is already on model-B (beta's default) → silent swap.
      coord.requestSwap(toProfileID: "beta", fromModel: "model-B.gguf") { profileID, pinModel in
        committed = profileID
        preservedModel = (pinModel == nil)
        return true
      }
      XCTAssertEqual(committed, "beta", "swapping into the already-selected model must stay silent")
      XCTAssertTrue(preservedModel, "a same-model swap must not pin a new model")
      XCTAssertNil(coord.pending)
    }
  }

  /// #460: the engine-stopped / unpinned re-select case. With no current
  /// model (`fromModel == nil`) there is nothing to REPLACE, so a swap-confirm
  /// "swap from — to X" is meaningless. The profile selection commits silently
  /// and fires no load.
  func test_profileStore_backed_coordinator_stays_silent_when_no_model_is_selected() throws {
    try withTwoProfileStore { store in
      let coord = ProfileSwapCoordinator(
        center: ModelLoadCenter(),   // engine stopped → residentModelID == nil
        profileStore: store,
        serveModel: { _, _ in }
      )
      var committed: String?
      coord.requestSwap(toProfileID: "beta", fromModel: nil) { profileID, _ in committed = profileID; return true }
      XCTAssertEqual(committed, "beta",
                     "with no current model, selecting a profile must commit silently — there is nothing to replace")
      XCTAssertNil(coord.pending,
                   "no swap-confirm popover when there is no current model")
    }
  }

  // MARK: - #459 third outcome: Keep Current Model (ported onto #460's authority)

  /// KEEP CURRENT MODEL: commit the profile switch AND pin the chat's CURRENT
  /// model A as its selection (`Chat.modelID`), with NO reload. Under the
  /// single authority this is the swap `commit` invoked with the CURRENT model
  /// (`fromModel`) as the pin instead of the new default — no `setOverride`.
  func test_keepCurrentModel_commits_profile_pins_current_model_and_fires_no_load() throws {
    try withTwoProfileStore { store in
      let center = ModelLoadCenter(initialResident: "model-A.gguf")
      let coord = ProfileSwapCoordinator(
        center: center, profileStore: store, serveModel: { _, _ in })

      var committedProfile: String?
      var pinnedModel: String?
      var commitCalls = 0
      // The chat is currently on model-A; beta's default is model-B → a
      // model-changing swap publishes a pending.
      coord.requestSwap(toProfileID: "beta", fromModel: "model-A.gguf") { profileID, pinModel in
        commitCalls += 1
        committedProfile = profileID
        pinnedModel = pinModel
        return true
      }

      let pending = try XCTUnwrap(coord.pending, "model-changing swap must publish a pending")
      XCTAssertTrue(pending.canKeepCurrentModel,
                    "a profile swap with a current model must offer Keep Current")
      XCTAssertFalse(pending.canSetAsDefault,
                     "the profile-swap path does not offer Set-as-default")

      coord.keepCurrentModel(token: pending.id)

      XCTAssertEqual(commitCalls, 1, "keep-current commits exactly once")
      XCTAssertEqual(committedProfile, "beta", "keep-current must commit the profile switch")
      XCTAssertEqual(pinnedModel, "model-A.gguf",
                     "keep-current must pin the CURRENT model A as the chat's selection")
      XCTAssertNil(coord.pending, "pending must clear after keep-current")
      XCTAssertEqual(center.residentModelID, "model-A.gguf",
                     "keep-current must NOT reload — A stays resident")
    }
  }

  /// A stale token (superseded pending) must be dropped: no profile switch,
  /// no pin, pending untouched — mirrors confirm/cancel.
  func test_keepCurrentModel_drops_stale_token() throws {
    try withTwoProfileStore { store in
      let coord = ProfileSwapCoordinator(
        center: ModelLoadCenter(initialResident: "model-A.gguf"),
        profileStore: store, serveModel: { _, _ in })

      var commitCalls = 0
      coord.requestSwap(toProfileID: "beta", fromModel: "model-A.gguf") { _, _ in
        commitCalls += 1; return true
      }
      XCTAssertNotNil(coord.pending)

      coord.keepCurrentModel(token: UUID())   // wrong token

      XCTAssertNotNil(coord.pending, "stale-token keep-current must not clear the pending")
      XCTAssertEqual(commitCalls, 0, "stale-token keep-current must not commit (no switch, no pin)")
    }
  }

  /// Keep-current is meaningless on the toolbar model-override path (the user
  /// explicitly picked a model to LOAD): the pending must not advertise it and
  /// a defensive call must be dropped.
  func test_keepCurrentModel_is_dropped_on_model_override_path() throws {
    try withTwoProfileStore { store in
      let coord = ProfileSwapCoordinator(
        center: ModelLoadCenter(initialResident: "model-A.gguf"),
        profileStore: store, serveModel: { _, _ in })

      var commitCalls = 0
      coord.requestModelOverride(modelID: "model-B.gguf", activeProfileID: "alpha",
                                 fromModel: "model-A.gguf") { _ in commitCalls += 1; return true }
      let pending = try XCTUnwrap(coord.pending)
      XCTAssertTrue(pending.canSetAsDefault)
      XCTAssertFalse(pending.canKeepCurrentModel,
                     "keep-current must not be offered on the model-override path")

      coord.keepCurrentModel(token: pending.id)

      XCTAssertNotNil(coord.pending, "keep-current must be a no-op on the model-override path")
      XCTAssertEqual(commitCalls, 0)
    }
  }

  /// Esc / click-outside (`dismissCurrentPending`) must be a TRUE abandon —
  /// never silently keep-current: no profile switch, no pin.
  func test_dismiss_is_true_abandon_never_keeps_current() throws {
    try withTwoProfileStore { store in
      let coord = ProfileSwapCoordinator(
        center: ModelLoadCenter(initialResident: "model-A.gguf"),
        profileStore: store, serveModel: { _, _ in })

      var commitCalls = 0
      coord.requestSwap(toProfileID: "beta", fromModel: "model-A.gguf") { _, _ in
        commitCalls += 1; return true
      }
      XCTAssertNotNil(coord.pending)

      coord.dismissCurrentPending()   // Esc / click-outside

      XCTAssertNil(coord.pending)
      XCTAssertEqual(commitCalls, 0, "an accidental dismiss must NOT switch the profile or pin a model")
    }
  }

  // MARK: - #488: deferred pick wiring (executor → coordinator error surface)

  /// #488 end-to-end across the production wiring shape (`RatioThinkApp`):
  /// a pick against a transitional engine is QUEUED by
  /// `ActiveModelServeExecutor` (not dropped), re-served on the settle, and a
  /// re-serve failure lands in the coordinator's existing `serveModelError`
  /// toolbar surface via `reportServeFailure` — never invisible.
  func test_deferred_pick_failure_surfaces_through_serveModelError() async throws {
    final class FailingStartClient: AppXPCClient, @unchecked Sendable {
      func helperProtocolVersion() async throws -> Int { HelperProtocolCompatibility.currentVersion }
      func engineStatus() async throws -> EngineStatus { .stopped }
      func stopEngine() async throws {}
      func startEngine(profileID: String, modelOverride: String?) async throws {
        throw EngineError(code: .modelMissing, message: "evicted")
      }
      func restartEngine(profileID: String, modelOverride: String?) async throws {}
    }

    let store = EngineStatusStore(client: FailingStartClient(), initialStatus: .stopping)
    let center = ModelLoadCenter()
    let executor = ActiveModelServeExecutor(engineStatus: store, modelLoad: center)
    let coord = ProfileSwapCoordinator(
      center: center,
      serveModel: { try await executor.serve(modelID: $0, profileID: $1) }
    )
    executor.onDeferredServeFailure = { [weak coord] modelID, error in
      coord?.reportServeFailure(modelID: modelID, error: error)
    }

    // Pick mid-transition → queued, not dropped.
    coord.loadDirect(modelID: "m-A.gguf", profileID: "chat")
    let deadline = Date().addingTimeInterval(2)
    while executor.deferredPick == nil && Date() < deadline {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertEqual(executor.deferredPick?.modelID, "m-A.gguf",
                   "a pick against a stopping engine must queue")
    XCTAssertNil(coord.serveModelError)

    // Engine settles stopped → re-serve fires, start rejects → surfaced.
    store._applyPollForTesting(next: .stopped, error: nil)
    while coord.serveModelError == nil && Date() < deadline {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    let surfaced = try XCTUnwrap(coord.serveModelError,
                                 "a deferred pick's launch failure must surface like a direct pick's")
    XCTAssertTrue(surfaced.contains("m-A.gguf"), "error copy must name the model: \(surfaced)")
  }

  /// #486: the model-menu analog of the no-current-model re-select. Picking a
  /// model from the toolbar model menu with NO current model (`fromModel ==
  /// nil`: engine stopped / unpinned) must NOT raise a switch-model confirm —
  /// there is nothing to REPLACE, so the popover would be the same meaningless
  /// "switch from — to X". `requestModelOverride` must commit the override
  /// silently and fire no load, exactly like `requestSwap`'s policy 1.5.
  func test_model_override_stays_silent_when_no_current_model() throws {
    try withTwoProfileStore { store in
      let coord = ProfileSwapCoordinator(
        center: ModelLoadCenter(),   // engine stopped → nothing resident
        profileStore: store, serveModel: { _, _ in })

      var committed: String?
      coord.requestModelOverride(modelID: "model-B.gguf", activeProfileID: "beta",
                                 fromModel: nil) { committed = $0; return true }
      XCTAssertEqual(committed, "model-B.gguf",
                     "with no current model, a model-menu pick must commit the override silently")
      XCTAssertNil(coord.pending,
                   "no switch-model confirm popover when there is no current model")
    }
  }
}
