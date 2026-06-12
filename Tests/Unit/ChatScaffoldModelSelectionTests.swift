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

  func test_profile_sampling_defaults_seed_toolbar_state_without_persisting_overrides() {
    let viewModel = ChatTranscriptViewModel(
      selectedProfileID: "creative",
      sampling: ChatSampling(temperature: 0.7, topP: 0.9, maxTokens: 4096),
      systemPromptOverride: "temporary override"
    )

    ChatScaffoldView.applyProfileDefaults(
      to: viewModel,
      sampling: Sampling(temperature: 1.1, topP: 0.65, maxTokens: 777)
    )

    XCTAssertEqual(viewModel.sampling, ChatSampling(temperature: 1.1, topP: 0.65, maxTokens: 777))
    XCTAssertNil(viewModel.systemPromptOverride,
                 "profile switches should clear the transient toolbar prompt override; send resolves the profile prompt separately")
  }

  func test_resolvedSystemPrompt_uses_transient_override_then_profile_default() {
    XCTAssertEqual(
      ChatScaffoldView.resolvedSystemPrompt(profileDefault: "Profile prompt", transientOverride: "Toolbar prompt"),
      "Toolbar prompt"
    )
    XCTAssertEqual(
      ChatScaffoldView.resolvedSystemPrompt(profileDefault: "Profile prompt", transientOverride: nil),
      "Profile prompt"
    )
    XCTAssertEqual(
      ChatScaffoldView.resolvedSystemPrompt(profileDefault: "Profile prompt", transientOverride: ""),
      "Profile prompt",
      "blank toolbar text means use the selected profile's system prompt"
    )
    XCTAssertNil(ChatScaffoldView.resolvedSystemPrompt(profileDefault: "", transientOverride: nil))
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
