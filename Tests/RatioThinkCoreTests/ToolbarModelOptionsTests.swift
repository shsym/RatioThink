import XCTest
@testable import RatioThinkCore

final class ToolbarModelOptionsTests: XCTestCase {
  private func appModel(_ slug: String,
                        sizeBytes: Int64 = 100,
                        isPartial: Bool = false,
                        unsupportedReason: String? = nil) -> InstalledModel {
    InstalledModel(filename: slug,
                   url: URL(fileURLWithPath: "/models/\(slug)"),
                   sizeBytes: sizeBytes,
                   modifiedAt: Date(timeIntervalSince1970: 0),
                   isPartial: isPartial,
                   source: .appManaged,
                   unsupportedReason: unsupportedReason)
  }

  private func hfModel(_ slug: String,
                       sizeBytes: Int64 = 100,
                       isPartial: Bool = false,
                       unsupportedReason: String? = nil) -> InstalledModel {
    InstalledModel(filename: slug,
                   url: URL(fileURLWithPath: "/hf/\(slug)"),
                   sizeBytes: sizeBytes,
                   modifiedAt: Date(timeIntervalSince1970: 0),
                   isPartial: isPartial,
                   source: .huggingFaceCache,
                   unsupportedReason: unsupportedReason)
  }

  func test_build_lists_app_hf_served_profile_default_and_current_without_duplicates() {
    let options = ToolbarModelOptions.build(
      discoveredModels: [
        appModel("App/Alpha.gguf"),
        hfModel("HF/Beta.safetensors"),
        hfModel("served/Resident.gguf"),
      ],
      servedModelIDs: ["served/Resident.gguf", "served/RemoteOnly.gguf"],
      profileDefaultModelID: "defaults/ProfileDefault.gguf",
      modelOverride: nil,
      residentModelID: "served/Resident.gguf")

    XCTAssertEqual(options.map(\.slug), [
      "App/Alpha.gguf",
      "HF/Beta.safetensors",
      "defaults/ProfileDefault.gguf",
      "served/RemoteOnly.gguf",
      "served/Resident.gguf",
    ])
    XCTAssertEqual(options.first { $0.slug == "served/Resident.gguf" }?.isCurrent, true)
    XCTAssertEqual(options.first { $0.slug == "defaults/ProfileDefault.gguf" }?.isProfileDefault, true)
    XCTAssertEqual(options.first { $0.slug == "HF/Beta.safetensors" }?.displayName, "Beta.safetensors")
  }

  // Disambiguation suffix: an HF-cache row is marked so an app-vs-cache pair
  // sharing a quant tag differs in the menu; app-managed + synthesized rows
  // (served/profile-default with no discovered model) stay unmarked.
  func test_source_tag_marks_hf_cache_rows_only() {
    let options = ToolbarModelOptions.build(
      discoveredModels: [appModel("App/Model-Q4_K_M.gguf"),
                         hfModel("HF/Repo-GGUF/Model-Q4_K_M.gguf")],
      servedModelIDs: ["served/RemoteOnly.gguf"],
      profileDefaultModelID: nil,
      modelOverride: nil,
      residentModelID: nil)
    XCTAssertNil(options.first { $0.slug == "App/Model-Q4_K_M.gguf" }?.sourceTag,
                 "app-managed rows are unmarked (the default)")
    XCTAssertEqual(options.first { $0.slug == "HF/Repo-GGUF/Model-Q4_K_M.gguf" }?.sourceTag,
                   "hf cache")
    XCTAssertNil(options.first { $0.slug == "served/RemoteOnly.gguf" }?.sourceTag,
                 "a synthesized served row has no source → no suffix")
  }

  func test_current_label_uses_actual_model_leaf_not_default_when_profile_default_is_selected() {
    let summary = ToolbarModelOptions.currentSummary(
      modelOverride: nil,
      residentModelID: nil,
      profileDefaultModelID: "Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf")

    XCTAssertEqual(summary?.slug, "Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf")
    XCTAssertEqual(summary?.displayName, "Qwen3-0.6B-Q8_0.gguf")
    XCTAssertEqual(summary?.annotation, "Profile default")
  }

  func test_override_takes_current_precedence_over_resident_and_profile_default() {
    let summary = ToolbarModelOptions.currentSummary(
      modelOverride: "override/Chosen.gguf",
      residentModelID: "resident/Loaded.gguf",
      profileDefaultModelID: "default/Profile.gguf")

    XCTAssertEqual(summary?.slug, "override/Chosen.gguf")
    XCTAssertEqual(summary?.displayName, "Chosen.gguf")
    XCTAssertNil(summary?.annotation)
  }

  func test_profile_default_row_different_from_current_requests_swap_and_commits_explicit_pin() {
    let option = ToolbarModelOptions.Option(
      slug: "profile/Default.gguf",
      displayName: "Default.gguf",
      source: nil,
      isCurrent: false,
      isProfileDefault: true,
      unavailableReason: nil)

    let action = ToolbarModelOptions.selectionAction(for: option, residentModelID: "resident/Loaded.gguf")

    XCTAssertEqual(action, .requestModel(modelID: "profile/Default.gguf", overrideAfterConfirmation: "profile/Default.gguf"),
                   "choosing a concrete profile-default row is still an explicit model pick, so the chat must pin that slug after confirmation")
  }

  func test_profile_default_row_matching_effective_override_but_not_resident_keeps_explicit_pin_after_swap() {
    let option = ToolbarModelOptions.Option(
      slug: "profile/Default.gguf",
      displayName: "Default.gguf",
      source: nil,
      isCurrent: true,
      isProfileDefault: true,
      unavailableReason: nil)

    let effectiveSummary = ToolbarModelOptions.currentSummary(
      modelOverride: "profile/Default.gguf",
      residentModelID: "resident/Loaded.gguf",
      profileDefaultModelID: "profile/Default.gguf")

    XCTAssertEqual(effectiveSummary?.slug, "profile/Default.gguf",
                   "the collapsed display can legitimately show the override/default model")
    XCTAssertEqual(ToolbarModelOptions.selectionAction(for: option,
                                                       residentModelID: "resident/Loaded.gguf"),
                   .requestModel(modelID: "profile/Default.gguf", overrideAfterConfirmation: "profile/Default.gguf"),
                   "clear-vs-load must not use the effective display model; resident A still needs a load for profile default B, and the concrete row remains an explicit pin")
  }

  func test_profile_default_row_same_as_current_selection_recommits_explicit_pin() {
    let option = ToolbarModelOptions.Option(
      slug: "profile/Default.gguf",
      displayName: "Default.gguf",
      source: nil,
      isCurrent: true,
      isProfileDefault: true,
      unavailableReason: nil)

    XCTAssertEqual(ToolbarModelOptions.selectionAction(for: option, residentModelID: "profile/Default.gguf"),
                   .requestModel(modelID: "profile/Default.gguf", overrideAfterConfirmation: "profile/Default.gguf"),
                   "choosing the concrete profile-default row must not clear into follow-default mode; it enters explicit model mode even when it is already current")
  }

  func test_partial_and_unsupported_discovered_models_are_disabled_with_reasons() {
    let options = ToolbarModelOptions.build(
      discoveredModels: [
        appModel("partial.gguf", isPartial: true),
        hfModel("split/Shard.gguf", unsupportedReason: "Split GGUF: unsupported"),
        appModel("ok.gguf"),
      ],
      servedModelIDs: [],
      profileDefaultModelID: nil,
      modelOverride: nil,
      residentModelID: nil)

    let partial = options.first { $0.slug == "partial.gguf" }
    XCTAssertEqual(partial?.unavailableReason, "Download in progress")
    XCTAssertFalse(partial?.isSelectable ?? true)

    let unsupported = options.first { $0.slug == "split/Shard.gguf" }
    XCTAssertEqual(unsupported?.unavailableReason, "Split GGUF: unsupported")
    XCTAssertFalse(unsupported?.isSelectable ?? true)

    XCTAssertNil(options.first { $0.slug == "ok.gguf" }?.unavailableReason)
    XCTAssertTrue(options.first { $0.slug == "ok.gguf" }?.isSelectable ?? false)
  }

  func test_unavailable_option_selection_never_requests_normal_model_load() {
    let option = ToolbarModelOptions.Option(
      slug: "partial.gguf",
      displayName: "partial.gguf",
      source: .appManaged,
      isCurrent: false,
      isProfileDefault: false,
      unavailableReason: "Download in progress")

    XCTAssertEqual(ToolbarModelOptions.selectionAction(for: option, residentModelID: "resident.gguf"),
                   .unavailable(reason: "Download in progress"))
  }
}
