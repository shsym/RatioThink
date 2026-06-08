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
        center: ModelLoadCenter(initialResident: "model-A.gguf"),
        engine: MockEngineClient(),
        profileStore: store
      )

      var committed: String?
      coord.requestSwap(toProfileID: "beta") { committed = $0 }

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
        center: ModelLoadCenter(initialResident: "model-B.gguf"),
        engine: MockEngineClient(),
        profileStore: store
      )
      var committed: String?
      coord.requestSwap(toProfileID: "beta") { committed = $0 }
      XCTAssertEqual(committed, "beta", "swapping into the already-resident model must stay silent")
      XCTAssertNil(coord.pending)
    }
  }

  /// : the engine-stopped re-select case. With the engine NOT running,
  /// nothing is resident (`residentModelID == nil` — the lifecycle clears it
  /// on the leave-`.running` edge), so the same-model check (`to == nil`) can
  /// never catch it and the swap used to prompt a meaningless "swap from — to
  /// X". A profile selection with no resident model to REPLACE must commit
  /// silently and fire no load.
  func test_profileStore_backed_coordinator_stays_silent_when_no_model_is_resident() throws {
    try withTwoProfileStore { store in
      let coord = ProfileSwapCoordinator(
        center: ModelLoadCenter(),   // engine stopped → residentModelID == nil
        engine: MockEngineClient(),
        profileStore: store
      )
      var committed: String?
      coord.requestSwap(toProfileID: "beta") { committed = $0 }
      XCTAssertEqual(committed, "beta",
                     "with nothing resident, selecting a profile must commit silently — there is no resident model to replace")
      XCTAssertNil(coord.pending,
                   "no swap-confirm popover when the engine is stopped and no model is loaded")
    }
  }

  // MARK: - #459 third outcome: Keep Current Model

  /// KEEP CURRENT MODEL: commit the profile switch AND pin the resident model
  /// A as the per-chat override, with NO reload. The profile's stored default
  /// B is left untouched.
  func test_keepCurrentModel_commits_profile_sets_override_A_and_fires_no_load() throws {
    try withTwoProfileStore { store in
      let center = ModelLoadCenter(initialResident: "model-A.gguf")
      let coord = ProfileSwapCoordinator(
        center: center, engine: MockEngineClient(), profileStore: store)

      var committed: String?
      var capturedOverride: String?
      var overrideCalls = 0
      coord.requestSwap(
        toProfileID: "beta",
        commit: { committed = $0 },
        setOverride: { capturedOverride = $0; overrideCalls += 1 })

      let pending = try XCTUnwrap(coord.pending, "model-changing swap must publish a pending")
      XCTAssertTrue(pending.canKeepCurrentModel,
                    "a profile swap with a resident model must offer Keep Current")
      XCTAssertFalse(pending.canSetAsDefault,
                     "the profile-swap path does not offer Set-as-default")

      coord.keepCurrentModel(token: pending.id)

      XCTAssertEqual(committed, "beta", "keep-current must commit the profile switch")
      XCTAssertEqual(overrideCalls, 1, "keep-current must set the per-chat override exactly once")
      XCTAssertEqual(capturedOverride, "model-A.gguf",
                     "keep-current must pin the resident model A as the override")
      XCTAssertNil(coord.pending, "pending must clear after keep-current")
      XCTAssertEqual(center.residentModelID, "model-A.gguf",
                     "keep-current must NOT reload — A stays resident")
      XCTAssertFalse(center.isLoading, "keep-current must NOT start a model load")
    }
  }

  /// A stale token (superseded pending) must be dropped: no profile switch,
  /// no override, pending untouched — mirrors confirm/cancel.
  func test_keepCurrentModel_drops_stale_token() throws {
    try withTwoProfileStore { store in
      let coord = ProfileSwapCoordinator(
        center: ModelLoadCenter(initialResident: "model-A.gguf"),
        engine: MockEngineClient(), profileStore: store)

      var committed: String?
      var overrideCalls = 0
      coord.requestSwap(
        toProfileID: "beta",
        commit: { committed = $0 },
        setOverride: { _ in overrideCalls += 1 })
      XCTAssertNotNil(coord.pending)

      coord.keepCurrentModel(token: UUID())   // wrong token

      XCTAssertNotNil(coord.pending, "stale-token keep-current must not clear the pending")
      XCTAssertNil(committed, "stale-token keep-current must not switch the profile")
      XCTAssertEqual(overrideCalls, 0, "stale-token keep-current must not set the override")
    }
  }

  /// Keep-current is meaningless on the toolbar model-override path (the user
  /// explicitly picked a model to LOAD): the pending must not advertise it and
  /// a defensive call must be dropped.
  func test_keepCurrentModel_is_dropped_on_model_override_path() throws {
    try withTwoProfileStore { store in
      let coord = ProfileSwapCoordinator(
        center: ModelLoadCenter(initialResident: "model-A.gguf"),
        engine: MockEngineClient(), profileStore: store)

      var committed: String?
      coord.requestModelOverride(modelID: "model-B.gguf", activeProfileID: "alpha") { committed = $0 }
      let pending = try XCTUnwrap(coord.pending)
      XCTAssertTrue(pending.canSetAsDefault)
      XCTAssertFalse(pending.canKeepCurrentModel,
                     "keep-current must not be offered on the model-override path")

      coord.keepCurrentModel(token: pending.id)

      XCTAssertNotNil(coord.pending, "keep-current must be a no-op on the model-override path")
      XCTAssertNil(committed)
    }
  }

  /// Esc / click-outside (`dismissCurrentPending`) must be a TRUE abandon —
  /// never silently keep-current: no profile switch, no override.
  func test_dismiss_is_true_abandon_never_keeps_current() throws {
    try withTwoProfileStore { store in
      let coord = ProfileSwapCoordinator(
        center: ModelLoadCenter(initialResident: "model-A.gguf"),
        engine: MockEngineClient(), profileStore: store)

      var committed: String?
      var overrideCalls = 0
      coord.requestSwap(
        toProfileID: "beta",
        commit: { committed = $0 },
        setOverride: { _ in overrideCalls += 1 })
      XCTAssertNotNil(coord.pending)

      coord.dismissCurrentPending()   // Esc / click-outside

      XCTAssertNil(coord.pending)
      XCTAssertNil(committed, "an accidental dismiss must NOT switch the profile")
      XCTAssertEqual(overrideCalls, 0, "an accidental dismiss must NOT set the keep-current override")
    }
  }
}
