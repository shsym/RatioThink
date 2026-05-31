import XCTest
@testable import RatioThinkCore

/// The profile editor's model picker lists discovered models
/// (app-managed + HF cache) but must always include the profile's
/// current model — even if that model is not (or no longer) installed —
/// so the picker never silently drops the value the profile actually
/// carries. Each option also carries its size + whether it exceeds the
/// guardrail ceiling.
final class ProfileModelOptionsTests: XCTestCase {
  private let gib: Int64 = 1024 * 1024 * 1024

  private func appModel(_ slug: String, sizeBytes: Int64 = 100) -> InstalledModel {
    InstalledModel(filename: slug,
                   url: URL(fileURLWithPath: "/models/\(slug)"),
                   sizeBytes: sizeBytes,
                   modifiedAt: Date(timeIntervalSince1970: 0),
                   isPartial: false,
                   source: .appManaged)
  }

  private func hfModel(_ slug: String, sizeBytes: Int64) -> InstalledModel {
    InstalledModel(filename: slug,
                   url: URL(fileURLWithPath: "/hf/\(slug)"),
                   sizeBytes: sizeBytes,
                   modifiedAt: Date(timeIntervalSince1970: 0),
                   isPartial: false,
                   source: .huggingFaceCache)
  }

  func test_current_model_is_included_even_when_not_installed() {
    let options = ProfileModelOptions.build(models: [appModel("b.gguf")],
                                            current: "a.gguf",
                                            limitBytes: nil)
    XCTAssertEqual(options.map(\.slug), ["a.gguf", "b.gguf"])
    let current = options.first { $0.slug == "a.gguf" }
    XCTAssertEqual(current?.isCurrent, true)
    XCTAssertNil(current?.sizeBytes, "synthesized current entry has unknown size")
    XCTAssertNil(current?.source)
  }

  func test_no_duplicate_when_current_is_installed() {
    let options = ProfileModelOptions.build(models: [appModel("a.gguf"), appModel("b.gguf")],
                                            current: "a.gguf",
                                            limitBytes: nil)
    XCTAssertEqual(options.map(\.slug), ["a.gguf", "b.gguf"])
    XCTAssertEqual(options.first { $0.slug == "a.gguf" }?.isCurrent, true)
  }

  func test_sorted_by_slug_and_deduped_app_wins_over_hf() {
    // Same slug from both sources: app-managed entry wins (resolver's
    // app-staged-first precedence). app is 100 B, hf would be 999 GiB.
    let options = ProfileModelOptions.build(
      models: [appModel("dup", sizeBytes: 100), hfModel("dup", sizeBytes: 999 * gib),
               appModel("a.gguf")],
      current: "b.gguf",
      limitBytes: 1 * gib)
    XCTAssertEqual(options.map(\.slug), ["a.gguf", "b.gguf", "dup"])
    let dup = options.first { $0.slug == "dup" }
    XCTAssertEqual(dup?.source, .appManaged)
    XCTAssertEqual(dup?.sizeBytes, 100)
    XCTAssertEqual(dup?.isOverLimit, false, "app entry (100 B) wins, so not over the 1 GiB limit")
  }

  func test_over_limit_flag_uses_size_and_ceiling() {
    let options = ProfileModelOptions.build(
      models: [hfModel("Qwen/Big", sizeBytes: 56 * gib),
               hfModel("Qwen/Small", sizeBytes: 15 * gib)],
      current: "",
      limitBytes: 41 * gib)
    XCTAssertEqual(options.first { $0.slug == "Qwen/Big" }?.isOverLimit, true)
    XCTAssertEqual(options.first { $0.slug == "Qwen/Small" }?.isOverLimit, false)
  }

  func test_nil_limit_never_flags_over_limit() {
    let options = ProfileModelOptions.build(models: [hfModel("Qwen/Big", sizeBytes: 999 * gib)],
                                            current: "",
                                            limitBytes: nil)
    XCTAssertEqual(options.first?.isOverLimit, false)
  }

  func test_empty_current_yields_just_models() {
    let options = ProfileModelOptions.build(models: [appModel("a.gguf")],
                                            current: "",
                                            limitBytes: nil)
    XCTAssertEqual(options.map(\.slug), ["a.gguf"])
  }

  func test_display_name_is_leaf_of_slug() {
    let options = ProfileModelOptions.build(
      models: [hfModel("Qwen/Qwen3-0.6B", sizeBytes: 100)],
      current: "",
      limitBytes: nil)
    XCTAssertEqual(options.first?.displayName, "Qwen3-0.6B")
  }

  // An unlaunchable model (a collapsed split-GGUF row) carries its
  // reason into the option so the picker can disable it.
  func test_unsupported_model_carries_reason_into_option() {
    let sharded = InstalledModel(
      filename: "unsloth/Big-GGUF/Big-Q4_K_M-00001-of-00003.gguf",
      url: URL(fileURLWithPath: "/hf/shard"),
      sizeBytes: 6000,
      modifiedAt: Date(timeIntervalSince1970: 0),
      isPartial: false,
      source: .huggingFaceCache,
      unsupportedReason: "Split GGUF: unsupported")
    let options = ProfileModelOptions.build(models: [sharded, appModel("ok.gguf")],
                                            current: "",
                                            limitBytes: nil)
    XCTAssertEqual(options.first { $0.slug.hasSuffix("-00001-of-00003.gguf") }?.unsupportedReason,
                   "Split GGUF: unsupported",
                   "an unsupported model's reason must flow into the picker option so it renders disabled")
    XCTAssertNil(options.first { $0.slug == "ok.gguf" }?.unsupportedReason,
                 "a launchable model carries no unsupported reason")
  }
}
