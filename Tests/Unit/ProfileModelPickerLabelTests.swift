import AppKit
import SwiftUI
import XCTest
@testable import RatioThink

@MainActor
final class ProfileModelPickerLabelTests: XCTestCase {
  private let longModelID =
    "bartowski/Meta-Llama-3.1-8B-Instruct-GGUF/Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf"

  func test_long_model_id_label_has_bounded_ideal_width() {
    let host = NSHostingView(rootView: ProfileModelPickerLabel(modelID: longModelID))

    XCTAssertLessThanOrEqual(
      host.fittingSize.width,
      ProfileModelPickerLabel.maxLayoutWidth + 1,
      "The profile model picker label must not ask its Settings row to grow for long HF ids")
  }

  func test_accessibility_copy_uses_visible_leaf_and_value_preserves_full_model_id() {
    let displayName = ProfileModelPickerLabel.displayText(for: longModelID)

    XCTAssertEqual(
      ProfileModelPickerLabel.accessibilityText(for: displayName),
      "Default model: \(ModelDisplayName.leaf(longModelID))",
      "The selected picker accessibility label should present the same friendly leaf that is visible in the UI")
    XCTAssertEqual(
      ProfileModelPickerLabel.accessibilityHelpText(for: longModelID),
      longModelID,
      "The full resolver slug should remain available through accessibility help/value even when the visible label is shortened")
  }

  func test_closed_picker_control_accessibility_text_includes_advisory_warning() {
    let warning = "Unverified — may not be supported"
    let option = option(
      slug: "community/Unverified-GGUF/Unverified-Q4_K_M.gguf",
      supportWarning: warning
    )
    let model = ProfileModelPickerSelectionLabelModel(
      fallbackModel: option.slug,
      selectedOption: option,
      memoryPolicy: nil
    )

    let accessibilityText = ProfileModelPickerLabel.controlAccessibilityText(
      for: option.slug,
      model: model
    )

    XCTAssertEqual(accessibilityText, "\(warning)\n\(option.slug)")
    XCTAssertTrue(
      accessibilityText.contains(warning),
      "The closed ProfileEditor model picker control help/value must include advisory support warnings")
  }

  func test_visible_selected_label_text_uses_friendly_leaf_not_raw_slug() {
    let visibleText = visibleTextStrings(in: ProfileModelPickerLabel(modelID: longModelID).body)

    XCTAssertEqual(
      visibleText,
      [ModelDisplayName.leaf(longModelID)],
      "The rendered Text in the selected picker label should use the friendly leaf, not the raw resolver slug")
    XCTAssertFalse(
      visibleText.contains(longModelID),
      "A raw repo/file slug must not be the visible selected picker text")
  }

  func test_visible_selected_label_text_handles_missing_default_model() {
    let visibleText = visibleTextStrings(in: ProfileModelPickerLabel(modelID: nil).body)

    XCTAssertEqual(
      visibleText,
      ["No default model"],
      "A profile with no default model should keep the explicit no-default label after the bounded picker-label merge")
  }

  private func option(
    slug: String,
    supportWarning: String? = nil
  ) -> ProfileModelOptions.Option {
    ProfileModelOptions.Option(
      slug: slug,
      displayName: ModelDisplayName.leaf(slug),
      sizeBytes: nil,
      source: nil,
      isOverLimit: false,
      isCurrent: true,
      unsupportedReason: nil,
      supportWarning: supportWarning
    )
  }

  private func visibleTextStrings(in value: Any) -> [String] {
    let mirror = Mirror(reflecting: value)
    if String(describing: type(of: value)) == "Text",
       let text = textString(fromTextMirror: mirror) {
      return [text]
    }
    return mirror.children
      .filter { child in
        // Only follow the rendered content tree. SwiftUI stores help and
        // accessibility metadata in sibling `text`/`modifier` branches; those
        // are intentionally covered by the accessibility test above and must
        // not satisfy this visible-label assertion.
        child.label != "modifier" && child.label != "text"
      }
      .flatMap { visibleTextStrings(in: $0.value) }
  }

  private func textString(fromTextMirror mirror: Mirror) -> String? {
    guard let storage = mirror.children.first(where: { $0.label == "storage" })?.value else {
      return nil
    }
    return firstString(in: storage)
  }

  private func firstString(in value: Any) -> String? {
    if let string = value as? String {
      return string
    }
    let mirror = Mirror(reflecting: value)
    for child in mirror.children {
      if let nested = firstString(in: child.value) {
        return nested
      }
    }
    return nil
  }
}
