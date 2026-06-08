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
      ChatTranscriptViewModel.placeholderModels.contains(try XCTUnwrap(seededProfile.model)),
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
}
