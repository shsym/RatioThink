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

  func test_profile_switch_clears_transient_toolbar_overrides_without_caching_profile_sampling() {
    let viewModel = ChatTranscriptViewModel(
      selectedProfileID: "creative",
      samplingOverride: ChatSampling(temperature: 0.7, topP: 0.9, maxTokens: 4096),
      systemPromptOverride: "temporary override"
    )

    ChatScaffoldView.clearTransientOverridesForProfileSwitch(to: viewModel)

    XCTAssertNil(viewModel.samplingOverride,
                 "profile switches should clear the transient toolbar sampling override")
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

  func test_resolvedSampling_uses_latest_profile_defaults_for_open_chat_without_toolbar_override() throws {
    try withTempProfilesDir { dir in
      try writeProfile(
        into: dir,
        id: "chat",
        temperature: 0.4,
        topP: 0.75,
        maxTokens: 1536)
      let store = ProfileStore(directory: dir)
      try store.start()
      defer { store.stop() }
      let viewModel = ChatTranscriptViewModel(selectedProfileID: "chat")

      try store.setEditableDefaults(
        systemPrompt: "prompt",
        temperature: 0.2,
        topP: 0.95,
        forProfileID: "chat")

      XCTAssertEqual(
        ChatScaffoldView.resolvedSampling(
          profileDefault: store.sampling(forProfileID: viewModel.selectedProfileID),
          transientOverride: viewModel.samplingOverride),
        ChatSampling(temperature: 0.2, topP: 0.95, maxTokens: 1536),
        "an already-open chat with no toolbar override must pick up Settings-saved sampling defaults on its next send")
    }
  }

  func test_resolvedSampling_keeps_toolbar_override_over_later_profile_default_edits() throws {
    try withTempProfilesDir { dir in
      try writeProfile(
        into: dir,
        id: "chat",
        temperature: 0.4,
        topP: 0.75,
        maxTokens: 1536)
      let store = ProfileStore(directory: dir)
      try store.start()
      defer { store.stop() }
      let viewModel = ChatTranscriptViewModel(selectedProfileID: "chat")
      viewModel.samplingOverride = ChatSampling(temperature: 1.3, topP: 0.55, maxTokens: 1536)

      try store.setEditableDefaults(
        systemPrompt: "prompt",
        temperature: 0.2,
        topP: 0.95,
        forProfileID: "chat")

      XCTAssertEqual(
        ChatScaffoldView.resolvedSampling(
          profileDefault: store.sampling(forProfileID: viewModel.selectedProfileID),
          transientOverride: viewModel.samplingOverride),
        ChatSampling(temperature: 1.3, topP: 0.55, maxTokens: 1536),
        "a real toolbar override must remain transiently authoritative until cleared")
    }
  }

  func test_noop_params_popover_close_preserves_profile_sampling_source_for_open_chat() throws {
    try withTempProfilesDir { dir in
      try writeProfile(
        into: dir,
        id: "chat",
        temperature: 0.4,
        topP: 0.75,
        maxTokens: 1536)
      let store = ProfileStore(directory: dir)
      try store.start()
      defer { store.stop() }
      let viewModel = ChatTranscriptViewModel(selectedProfileID: "chat")
      let displayedSampling = ChatScaffoldView.resolvedSampling(
        profileDefault: store.sampling(forProfileID: viewModel.selectedProfileID),
        transientOverride: viewModel.samplingOverride)

      viewModel.samplingOverride = ContentToolbar.samplingOverrideAfterParamsCommit(
        currentOverride: viewModel.samplingOverride,
        sourceSampling: displayedSampling,
        committed: displayedSampling)

      XCTAssertNil(
        viewModel.samplingOverride,
        "opening and closing the params popover without slider edits must not create a stale explicit override")

      try store.setEditableDefaults(
        systemPrompt: "prompt",
        temperature: 0.2,
        topP: 0.95,
        forProfileID: "chat")

      XCTAssertEqual(
        ChatScaffoldView.resolvedSampling(
          profileDefault: store.sampling(forProfileID: viewModel.selectedProfileID),
          transientOverride: viewModel.samplingOverride),
        ChatSampling(temperature: 0.2, topP: 0.95, maxTokens: 1536),
        "after a no-op params inspection, the next send should still use the latest Settings-saved profile defaults")
    }
  }

  func test_netZero_params_edits_preserve_profile_sampling_source_for_open_chat() throws {
    try withTempProfilesDir { dir in
      try writeProfile(
        into: dir,
        id: "chat",
        temperature: 0.4,
        topP: 0.75,
        maxTokens: 1536)
      let store = ProfileStore(directory: dir)
      try store.start()
      defer { store.stop() }
      let viewModel = ChatTranscriptViewModel(selectedProfileID: "chat")
      let displayedSampling = ChatScaffoldView.resolvedSampling(
        profileDefault: store.sampling(forProfileID: viewModel.selectedProfileID),
        transientOverride: viewModel.samplingOverride)

      viewModel.samplingOverride = ContentToolbar.samplingOverrideAfterParamsCommit(
        currentOverride: viewModel.samplingOverride,
        sourceSampling: displayedSampling,
        committed: displayedSampling)

      XCTAssertNil(
        viewModel.samplingOverride,
        "dragging params sliders away and back to the displayed profile defaults must not create a stale explicit override")

      try store.setEditableDefaults(
        systemPrompt: "prompt",
        temperature: 0.2,
        topP: 0.95,
        forProfileID: "chat")

      XCTAssertEqual(
        ChatScaffoldView.resolvedSampling(
          profileDefault: store.sampling(forProfileID: viewModel.selectedProfileID),
          transientOverride: viewModel.samplingOverride),
        ChatSampling(temperature: 0.2, topP: 0.95, maxTokens: 1536),
        "after a net-zero params edit, the next send should still use the latest Settings-saved profile defaults")
    }
  }

  func test_dirty_params_popover_commit_creates_override_that_wins_over_later_profile_edits() throws {
    try withTempProfilesDir { dir in
      try writeProfile(
        into: dir,
        id: "chat",
        temperature: 0.4,
        topP: 0.75,
        maxTokens: 1536)
      let store = ProfileStore(directory: dir)
      try store.start()
      defer { store.stop() }
      let viewModel = ChatTranscriptViewModel(selectedProfileID: "chat")
      let sourceSampling = ChatScaffoldView.resolvedSampling(
        profileDefault: store.sampling(forProfileID: viewModel.selectedProfileID),
        transientOverride: nil)
      let editedSampling = ChatSampling(temperature: 1.3, topP: 0.55, maxTokens: 1536)

      viewModel.samplingOverride = ContentToolbar.samplingOverrideAfterParamsCommit(
        currentOverride: viewModel.samplingOverride,
        sourceSampling: sourceSampling,
        committed: editedSampling)

      try store.setEditableDefaults(
        systemPrompt: "prompt",
        temperature: 0.2,
        topP: 0.95,
        forProfileID: "chat")

      XCTAssertEqual(
        ChatScaffoldView.resolvedSampling(
          profileDefault: store.sampling(forProfileID: viewModel.selectedProfileID),
          transientOverride: viewModel.samplingOverride),
        editedSampling,
        "a dirty params popover commit is an explicit toolbar override until cleared")
    }
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

  private func withTempProfilesDir(_ body: (URL) throws -> Void) throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("rt-chat-scaffold-profile-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try body(dir)
  }

  private func writeProfile(into dir: URL,
                            id: String,
                            temperature: Double,
                            topP: Double,
                            maxTokens: Int) throws {
    let body = """
    id = "\(id)"
    name = "Chat"
    model = "model.gguf"
    inferlet = "chat-apc"
    system_prompt = "Old prompt"

    [sampling]
    temperature = \(temperature)
    top_p = \(topP)
    max_tokens = \(maxTokens)
    """
    try body.write(to: dir.appendingPathComponent("\(id).toml"),
                   atomically: true,
                   encoding: .utf8)
  }

}
