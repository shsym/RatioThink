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
        center: ModelLoadCenter(),
        engine: MockEngineClient(),
        profileStore: store
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
        engine: MockEngineClient(),
        profileStore: store
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
        center: ModelLoadCenter(),
        engine: MockEngineClient(),
        profileStore: store
      )
      var committed: String?
      coord.requestSwap(toProfileID: "beta", fromModel: nil) { profileID, _ in committed = profileID; return true }
      XCTAssertEqual(committed, "beta",
                     "with no current model, selecting a profile must commit silently — there is nothing to replace")
      XCTAssertNil(coord.pending,
                   "no swap-confirm popover when there is no current model")
    }
  }
}
