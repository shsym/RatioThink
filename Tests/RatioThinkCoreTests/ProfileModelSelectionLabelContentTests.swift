import XCTest
@testable import RatioThinkCore

final class ProfileModelSelectionLabelContentTests: XCTestCase {
  func test_normal_current_model_has_no_warning() {
    let option = option(slug: "Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf")

    let content = ProfileModelSelectionLabelContent(
      fallbackModel: option.slug,
      selectedOption: option,
      memoryPolicy: nil
    )

    XCTAssertEqual(content.displayName, "Qwen3-0.6B-Q8_0.gguf")
    XCTAssertNil(content.warningText)
    XCTAssertEqual(content.accessibilityLabel, "Default model: Qwen3-0.6B-Q8_0.gguf")
  }

  func test_unsupported_current_model_exposes_warning_for_selection_bar() {
    let option = option(
      slug: "unsloth/DeepSeek-R1-GGUF/DeepSeek-R1-Q8_0-00001-of-00003.gguf",
      unsupportedReason: "Split GGUF: unsupported"
    )

    let content = ProfileModelSelectionLabelContent(
      fallbackModel: option.slug,
      selectedOption: option,
      memoryPolicy: nil
    )

    XCTAssertEqual(content.displayName, "DeepSeek-R1-Q8_0-00001-of-00003.gguf")
    XCTAssertEqual(content.warningText, "Split GGUF: unsupported")
    XCTAssertEqual(
      content.accessibilityLabel,
      "Default model: DeepSeek-R1-Q8_0-00001-of-00003.gguf. Warning: Split GGUF: unsupported"
    )
  }

  func test_overLimit_current_model_exposes_guardrail_warning() {
    let policy = ModelMemoryGuardrail.Policy(maxResolvedModelBytes: 2 * 1024 * 1024 * 1024)
    let option = option(
      slug: "huge/Huge-GGUF/Huge-Q8_0.gguf",
      sizeBytes: 4 * 1024 * 1024 * 1024,
      isOverLimit: true
    )

    let content = ProfileModelSelectionLabelContent(
      fallbackModel: option.slug,
      selectedOption: option,
      memoryPolicy: policy
    )

    XCTAssertEqual(content.warningText, "exceeds 2.0 GB limit")
  }

  func test_supportWarning_current_model_exposes_advisory_warning() {
    let option = option(
      slug: "community/Unverified-GGUF/Unverified-Q4_K_M.gguf",
      supportWarning: "Unverified — may not be supported"
    )

    let content = ProfileModelSelectionLabelContent(
      fallbackModel: option.slug,
      selectedOption: option,
      memoryPolicy: nil
    )

    XCTAssertEqual(content.warningText, "Unverified — may not be supported")
    XCTAssertEqual(
      content.accessibilityLabel,
      "Default model: Unverified-Q4_K_M.gguf. Warning: Unverified — may not be supported"
    )
  }

  func test_long_model_label_contract_is_widthConstrainedToOneMiddleTruncatedLine() {
    XCTAssertEqual(ProfileModelSelectionLabelContent.maxNameWidth, 240)
    XCTAssertEqual(ProfileModelSelectionLabelContent.maxSelectionWidth, 360)
    XCTAssertEqual(ProfileModelSelectionLabelContent.nameLineLimit, 1)
    XCTAssertEqual(ProfileModelSelectionLabelContent.nameTruncationMode, .middle)
  }

  private func option(
    slug: String,
    sizeBytes: Int64? = nil,
    isOverLimit: Bool = false,
    unsupportedReason: String? = nil,
    supportWarning: String? = nil
  ) -> ProfileModelOptions.Option {
    ProfileModelOptions.Option(
      slug: slug,
      displayName: ModelDisplayName.leaf(slug),
      sizeBytes: sizeBytes,
      source: nil,
      isOverLimit: isOverLimit,
      isCurrent: true,
      unsupportedReason: unsupportedReason,
      supportWarning: supportWarning
    )
  }
}
