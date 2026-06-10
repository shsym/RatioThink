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
      ChatTranscriptViewModel.placeholderModels.contains(try XCTUnwrap(seededProfile.model)),
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

  // MARK: - review F1: residency seed adopts the served model ONLY when it is
  // this chat's profile default — never the engine's global resident model.

  func test_seed_adopts_served_model_when_it_is_the_profile_default() {
    XCTAssertEqual(
      ChatScaffoldView.seededModelID(
        currentPin: nil, servedID: "org/A/Default.gguf",
        profileDefault: "org/A/Default.gguf", isLoading: false),
      "org/A/Default.gguf",
      "unpinned + served == profile default → seed it"
    )
  }

  func test_seed_does_not_adopt_a_served_model_that_differs_from_profile_default() {
    // The engine serves a global model that is NOT this chat's default
    // (e.g. another chat loaded it). Seeding it would durably pin the wrong
    // model and freeze it there — the exact defect F1 flags.
    XCTAssertNil(
      ChatScaffoldView.seededModelID(
        currentPin: nil, servedID: "org/Other/Resident.gguf",
        profileDefault: "org/A/Default.gguf", isLoading: false),
      "unpinned + served != profile default → do NOT seed (follow the profile default)"
    )
  }

  func test_seed_never_overwrites_an_explicit_pin() {
    XCTAssertNil(
      ChatScaffoldView.seededModelID(
        currentPin: "org/Pinned/Pick.gguf", servedID: "org/Pinned/Pick.gguf",
        profileDefault: "org/Pinned/Pick.gguf", isLoading: false),
      "already pinned → never overwrite, even when everything agrees"
    )
  }

  func test_seed_is_a_noop_while_a_load_is_in_flight() {
    XCTAssertNil(
      ChatScaffoldView.seededModelID(
        currentPin: nil, servedID: "org/A/Default.gguf",
        profileDefault: "org/A/Default.gguf", isLoading: true),
      "loading → no-op (the load's target is the user's choice, not yet served)"
    )
  }

  func test_seed_is_a_noop_when_nothing_is_served() {
    XCTAssertNil(
      ChatScaffoldView.seededModelID(
        currentPin: nil, servedID: nil,
        profileDefault: "org/A/Default.gguf", isLoading: false))
  }

  // MARK: - #501 centralization: the pin-over-default sites delegate to the
  // single resolver (`ModelTarget.resolve`) with identical results. The
  // precedence itself is owned and exhaustively tested by `ModelTargetTests`
  // (SPM); these guard that each folded call site stays a thin pass-through.

  /// The pin/default matrix the resolver covers — pin beats default; blank/nil
  /// counts as absent; nothing resolvable is `nil`.
  private static let pinDefaultMatrix: [(pin: String?, def: String?)] = [
    ("pinned-model", "profile-default"),  // pin wins
    (nil, "profile-default"),             // unpinned → default
    ("pinned-model", nil),                // pinned, no default
    (nil, nil),                           // nothing → nil
  ]

  func test_requestModelID_non_override_path_equals_ModelTarget_resolve() {
    // With no GUI test override, `requestModelID` IS the resolver's pick →
    // default → nil. (The `testModelID` seam is a harness override, proven
    // separately above; it is not a pin/default source.)
    for c in Self.pinDefaultMatrix {
      XCTAssertEqual(
        ChatScaffoldView.requestModelID(
          selectedModelID: c.pin, profileDefaultModel: c.def, testModelID: nil),
        ModelTarget.resolve(selectedModelID: c.pin, profileDefault: c.def)?.modelID,
        "requestModelID (no override) must equal ModelTarget.resolve for pin=\(String(describing: c.pin)) default=\(String(describing: c.def))"
      )
    }
  }

  func test_effectiveModelID_equals_ModelTarget_resolve() {
    // The swap policy's "current model" is the same pin-over-default pick.
    for c in Self.pinDefaultMatrix {
      XCTAssertEqual(
        ContentToolbar.effectiveModelID(
          selectedModelID: c.pin, profileDefaultModel: c.def),
        ModelTarget.resolve(selectedModelID: c.pin, profileDefault: c.def)?.modelID,
        "effectiveModelID must equal ModelTarget.resolve for pin=\(String(describing: c.pin)) default=\(String(describing: c.def))"
      )
    }
  }

  func test_effectiveModelID_pins_over_default_and_nils_when_empty() {
    XCTAssertEqual(
      ContentToolbar.effectiveModelID(selectedModelID: "pinned-model",
                                      profileDefaultModel: "profile-default"),
      "pinned-model")
    XCTAssertEqual(
      ContentToolbar.effectiveModelID(selectedModelID: nil,
                                      profileDefaultModel: "profile-default"),
      "profile-default")
    XCTAssertNil(
      ContentToolbar.effectiveModelID(selectedModelID: nil, profileDefaultModel: nil))
  }
}
