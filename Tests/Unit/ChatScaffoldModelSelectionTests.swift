import XCTest
@testable import RatioThink

@MainActor
final class ChatScaffoldModelSelectionTests: XCTestCase {
  func test_nothing_resolvable_returns_nil_so_send_is_blocked() {
    // : no hidden "default" sentinel. With no test override, no
    // per-chat override, and nothing resident, resolution yields nil —
    // the caller must block the send and show the no-model confirm
    // rather than silently asking the engine to load something.
    let selected = ChatScaffoldView.requestModelID(
      modelOverride: nil,
      residentModelID: nil,
      testModelID: nil
    )
    XCTAssertNil(selected)
  }

  func test_placeholder_models_include_seeded_default_profile_model() throws {
    let seededProfile = try Profile.parse(toml: ProfileStore.defaultChatTOML)

    XCTAssertTrue(
      ChatTranscriptViewModel.placeholderModels.contains(seededProfile.model),
      "placeholderModels must include the seeded default profile model so the first-launch model picker matches chat.toml"
    )
  }

  func test_explicit_model_override_and_resident_model_take_precedence_over_profile_default() {
    XCTAssertEqual(
      ChatScaffoldView.requestModelID(
        modelOverride: "explicit-model",
        residentModelID: "resident-model",
        testModelID: nil
      ),
      "explicit-model"
    )
    XCTAssertEqual(
      ChatScaffoldView.requestModelID(
        modelOverride: nil,
        residentModelID: "resident-model",
        testModelID: nil
      ),
      "resident-model"
    )
  }

  func test_chat_gui_override_still_points_at_small_model_harness() {
    XCTAssertEqual(
      ChatScaffoldView.requestModelID(
        modelOverride: nil,
        residentModelID: nil,
        testModelID: "Qwen/Qwen3-0.6B"
      ),
      "Qwen/Qwen3-0.6B"
    )
  }

  func test_engine_error_message_uses_localized_rollback_warning() {
    struct StartError: Error {}
    struct RollbackError: Error {}
    let error = LocalAPIBindModeRollbackError(
      startError: StartError(),
      rollbackError: RollbackError()
    )

    let message = ChatScaffoldView.engineErrorMessage(error, verb: "switch")

    XCTAssertTrue(message.contains("Couldn't switch the engine:"))
    XCTAssertTrue(message.contains("external-access preference could not be restored"))
    XCTAssertTrue(message.contains("helper-visible preference may still allow external binding"))
    XCTAssertFalse(message.contains("LocalAPIBindModeRollbackError("),
                   "user-facing action errors must show the localized rollback warning, not a Swift struct dump")
  }
}
