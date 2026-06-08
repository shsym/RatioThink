import XCTest
@testable import RatioThink

@MainActor
final class ChatScaffoldModelSelectionTests: XCTestCase {
  func test_nothing_resolvable_returns_nil_so_send_is_blocked() {
    // : no hidden fallback. With no test override, no pinned model, and no
    // profile default, resolution yields nil — the caller blocks the send
    // and shows the no-model confirm rather than silently loading something.
    let selected = ChatScaffoldView.requestModelID(
      selectedModelID: nil,
      profileDefaultModel: nil,
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

  // MARK: - #460 single-source selection resolution

  func test_pinned_model_takes_precedence_over_profile_default() {
    XCTAssertEqual(
      ChatScaffoldView.requestModelID(
        selectedModelID: "pinned-model",
        profileDefaultModel: "profile-default",
        testModelID: nil
      ),
      "pinned-model"
    )
  }

  func test_unpinned_chat_falls_back_to_profile_default() {
    // The single source of truth resolves an UNPINNED chat to the active
    // profile's default — never engine residency.
    XCTAssertEqual(
      ChatScaffoldView.requestModelID(
        selectedModelID: nil,
        profileDefaultModel: "profile-default",
        testModelID: nil
      ),
      "profile-default"
    )
  }

  func test_chat_gui_override_still_points_at_small_model_harness() {
    XCTAssertEqual(
      ChatScaffoldView.requestModelID(
        selectedModelID: nil,
        profileDefaultModel: nil,
        testModelID: "Qwen/Qwen3-0.6B"
      ),
      "Qwen/Qwen3-0.6B"
    )
  }

  // MARK: - AC4: model label is stable / derives from the selection authority

  func test_label_shows_pinned_model_leaf() {
    XCTAssertEqual(
      ContentToolbar.modelLabel(selectedModelID: "org/Repo/Big-Model-Q8.gguf",
                                profileDefaultModel: "org/Other/Other.gguf"),
      ModelDisplayName.leaf("org/Repo/Big-Model-Q8.gguf"),
      "a pinned model must render its own leaf, independent of the profile default"
    )
  }

  func test_label_falls_back_to_profile_default_leaf_when_unpinned() {
    XCTAssertEqual(
      ContentToolbar.modelLabel(selectedModelID: nil,
                                profileDefaultModel: "org/Other/Other.gguf"),
      ModelDisplayName.leaf("org/Other/Other.gguf")
    )
  }

  func test_label_is_profile_default_text_only_when_no_model_at_all() {
    XCTAssertEqual(
      ContentToolbar.modelLabel(selectedModelID: nil, profileDefaultModel: nil),
      "Profile default"
    )
  }

  /// AC4 stability: a no-default profile switch PRESERVES the pinned model
  /// (the coordinator's silent path leaves `Chat.modelID` untouched — proven
  /// in ProfileSwapCoordinatorTests), so the label is identical before and
  /// after the switch even though the new profile has no default of its own.
  func test_label_is_stable_across_a_no_default_profile_switch() {
    let pinned = "org/Repo/Pinned.gguf"
    let before = ContentToolbar.modelLabel(selectedModelID: pinned,
                                           profileDefaultModel: "org/A/Default-A.gguf")
    // After switching to a profile with no default, the pinned model is
    // preserved and the profile default is now nil.
    let after = ContentToolbar.modelLabel(selectedModelID: pinned,
                                          profileDefaultModel: nil)
    XCTAssertEqual(before, after, "the model label must not reset on a no-default profile switch")
  }
}
