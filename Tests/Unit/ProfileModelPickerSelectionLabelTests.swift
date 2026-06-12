import XCTest
import SwiftUI
@testable import RatioThink

@MainActor
final class ProfileModelPickerSelectionLabelTests: XCTestCase {
  func test_normal_current_model_has_no_selection_bar_warning() {
    let option = option(slug: "Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf")

    let model = ProfileModelPickerSelectionLabelModel(
      fallbackModel: option.slug,
      selectedOption: option,
      memoryPolicy: nil
    )

    XCTAssertEqual(model.displayName, "Qwen3-0.6B-Q8_0.gguf")
    XCTAssertNil(model.warningText)
    XCTAssertEqual(model.accessibilityLabel, "Default model: Qwen3-0.6B-Q8_0.gguf")
  }

  func test_unsupported_current_model_warning_is_visible_in_selection_bar_model() {
    let option = option(
      slug: "unsloth/DeepSeek-R1-GGUF/DeepSeek-R1-Q8_0-00001-of-00003.gguf",
      unsupportedReason: "Split GGUF: unsupported"
    )

    let model = ProfileModelPickerSelectionLabelModel(
      fallbackModel: option.slug,
      selectedOption: option,
      memoryPolicy: nil
    )

    XCTAssertEqual(model.displayName, "DeepSeek-R1-Q8_0-00001-of-00003.gguf")
    XCTAssertEqual(model.warningText, "Split GGUF: unsupported")
    XCTAssertEqual(
      model.accessibilityLabel,
      "Default model: DeepSeek-R1-Q8_0-00001-of-00003.gguf. Warning: Split GGUF: unsupported"
    )
  }

  func test_overLimit_current_model_warning_uses_guardrail_limit() {
    let policy = ModelMemoryGuardrail.Policy(maxResolvedModelBytes: 2 * 1024 * 1024 * 1024)
    let option = option(
      slug: "huge/Huge-GGUF/Huge-Q8_0.gguf",
      sizeBytes: 4 * 1024 * 1024 * 1024,
      isOverLimit: true
    )

    let model = ProfileModelPickerSelectionLabelModel(
      fallbackModel: option.slug,
      selectedOption: option,
      memoryPolicy: policy
    )

    XCTAssertEqual(model.warningText, "exceeds 2.0 GB limit")
  }

  func test_supportWarning_current_model_exposes_advisory_warning() {
    let option = option(
      slug: "community/Unverified-GGUF/Unverified-Q4_K_M.gguf",
      supportWarning: "Unverified — may not be supported"
    )

    let model = ProfileModelPickerSelectionLabelModel(
      fallbackModel: option.slug,
      selectedOption: option,
      memoryPolicy: nil
    )

    XCTAssertEqual(model.warningText, "Unverified — may not be supported")
    XCTAssertEqual(
      model.accessibilityLabel,
      "Default model: Unverified-Q4_K_M.gguf. Warning: Unverified — may not be supported"
    )
  }

  func test_long_selected_model_label_contract_is_constrained_to_one_truncated_line() {
    XCTAssertEqual(ProfileModelPickerSelectionLabelModel.maxNameWidth, 240)
    XCTAssertEqual(ProfileModelPickerSelectionLabelModel.maxSelectionWidth, 360)
    XCTAssertEqual(ProfileModelPickerSelectionLabelModel.nameLineLimit, 1)
    XCTAssertEqual(ProfileModelPickerSelectionLabelModel.nameTruncationMode, .middle)
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
