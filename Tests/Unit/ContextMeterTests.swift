import XCTest
import SwiftUI
@testable import RatioThink

/// #711: pure-logic coverage for the context-token meter — the
/// `ContextUsage` fraction math and `ContextMeterView`'s colour/label
/// derivation. No rendering; the view's static helpers carry the logic
/// precisely so they can be asserted in isolation.
final class ContextMeterTests: XCTestCase {

  // MARK: - ContextUsage.fraction

  func test_fraction_is_used_over_window() {
    XCTAssertEqual(ContextUsage(usedTokens: 50, windowTokens: 100).fraction, 0.5)
  }

  func test_fraction_clamps_to_one_when_over_window() {
    // A turn that overflowed the window must not push the bar past full.
    XCTAssertEqual(ContextUsage(usedTokens: 250, windowTokens: 100).fraction, 1.0)
  }

  func test_fraction_is_zero_for_empty_context() {
    XCTAssertEqual(ContextUsage(usedTokens: 0, windowTokens: 100).fraction, 0.0)
  }

  func test_fraction_is_nil_when_window_unknown() {
    XCTAssertNil(ContextUsage(usedTokens: 50, windowTokens: nil).fraction)
  }

  func test_fraction_is_nil_for_nonpositive_window() {
    // Never divide by zero — a 0 budget reads as indeterminate, not 100%.
    XCTAssertNil(ContextUsage(usedTokens: 50, windowTokens: 0).fraction)
  }

  // MARK: - ContextMeterView.fillColor (green → amber → red)

  func test_fillColor_green_below_three_quarters() {
    XCTAssertEqual(ContextMeterView.fillColor(0.0), .green)
    XCTAssertEqual(ContextMeterView.fillColor(0.5), .green)
    XCTAssertEqual(ContextMeterView.fillColor(0.749), .green)
  }

  func test_fillColor_amber_between_three_quarters_and_ninety() {
    XCTAssertEqual(ContextMeterView.fillColor(0.75), .orange)
    XCTAssertEqual(ContextMeterView.fillColor(0.89), .orange)
  }

  func test_fillColor_red_at_or_above_ninety() {
    XCTAssertEqual(ContextMeterView.fillColor(0.9), .red)
    XCTAssertEqual(ContextMeterView.fillColor(1.0), .red)
  }

  // MARK: - ContextMeterView.label

  func test_label_with_window_shows_used_window_and_percent() {
    let label = ContextMeterView.label(for: ContextUsage(usedTokens: 50, windowTokens: 100))
    XCTAssertTrue(label.contains("/"), "want used/window form: \(label)")
    XCTAssertTrue(label.contains("tokens"), label)
    XCTAssertTrue(label.contains("50%)"), "want the 50% fill in: \(label)")
  }

  func test_label_without_window_marks_it_unknown() {
    let label = ContextMeterView.label(for: ContextUsage(usedTokens: 12, windowTokens: nil))
    XCTAssertTrue(label.contains("window unknown"), label)
    XCTAssertFalse(label.contains("/"), "no denominator when window is unknown: \(label)")
  }
}
