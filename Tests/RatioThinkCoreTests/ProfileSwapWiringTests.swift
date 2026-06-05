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
}
