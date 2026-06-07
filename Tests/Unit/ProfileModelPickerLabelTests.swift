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

  func test_accessibility_label_uses_visible_leaf_and_value_preserves_full_model_id() {
    let host = NSHostingView(rootView: ProfileModelPickerLabel(modelID: longModelID))
    host.frame = NSRect(x: 0, y: 0,
                        width: ProfileModelPickerLabel.maxLayoutWidth,
                        height: 32)
    host.layoutSubtreeIfNeeded()
    let accessibilityDump = accessibilityDescriptions(in: host)

    XCTAssertTrue(
      accessibilityDump.contains("label=Default model: \(ModelDisplayName.leaf(longModelID))"),
      "The selected picker label should present the same friendly leaf that is visible in the UI; dump=\(accessibilityDump)")
    XCTAssertTrue(
      accessibilityDump.contains("help=\(longModelID)"),
      "The full resolver slug should remain available through accessibility help even when the visible label is shortened; dump=\(accessibilityDump)")
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

  private func accessibilityDescriptions(in element: Any) -> [String] {
    guard let object = element as? NSObject else { return [] }
    let label = accessibilityString(object, "accessibilityLabel").map { "label=\($0)" }
    let value = accessibilityString(object, "accessibilityValue").map { "value=\($0)" }
    let help = accessibilityString(object, "accessibilityHelp").map { "help=\($0)" }
    let current = [label, value, help].compactMap(\.self)
    let children = accessibilityChildren(object)
      .flatMap { accessibilityDescriptions(in: $0) }
    return current + children
  }

  private func accessibilityString(_ object: NSObject, _ selector: String) -> String? {
    let selector = NSSelectorFromString(selector)
    guard object.responds(to: selector) else { return nil }
    return object.perform(selector)?.takeUnretainedValue() as? String
  }

  private func accessibilityChildren(_ object: NSObject) -> [Any] {
    let selector = NSSelectorFromString("accessibilityChildren")
    guard object.responds(to: selector) else { return [] }
    return object.perform(selector)?.takeUnretainedValue() as? [Any] ?? []
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
