import XCTest
@testable import RatioThink

/// Pure geometry for the sampling sliders' coarse tick scale (#421). The
/// view layout can't be pixel-tested here, but the value→position math and
/// the tick/label generation are pure functions, so a regression in the
/// scale (wrong count, overrun, bad clamp) is a unit failure.
final class SliderTickScaleTests: XCTestCase {

  // MARK: - fraction

  func test_fraction_maps_range_ends_and_mid() {
    XCTAssertEqual(SliderTickScale.fraction(0, in: 0...2), 0, accuracy: 1e-9)
    XCTAssertEqual(SliderTickScale.fraction(1, in: 0...2), 0.5, accuracy: 1e-9)
    XCTAssertEqual(SliderTickScale.fraction(2, in: 0...2), 1, accuracy: 1e-9)
  }

  func test_fraction_clamps_out_of_range() {
    XCTAssertEqual(SliderTickScale.fraction(-1, in: 0...1), 0, accuracy: 1e-9)
    XCTAssertEqual(SliderTickScale.fraction(5, in: 0...1), 1, accuracy: 1e-9)
  }

  func test_fraction_degenerate_range_is_zero() {
    XCTAssertEqual(SliderTickScale.fraction(1, in: 1...1), 0)
  }

  // MARK: - evenTicks

  func test_evenTicks_temperature_quarter_step() {
    let ticks = SliderTickScale.evenTicks(0...2, step: 0.25)
    XCTAssertEqual(ticks.count, 9)                 // 0, 0.25, …, 2.0
    XCTAssertEqual(ticks.first!, 0, accuracy: 1e-9)
    XCTAssertEqual(ticks.last!, 2, accuracy: 1e-9)
  }

  func test_evenTicks_topP_quarter_step() {
    let ticks = SliderTickScale.evenTicks(0...1, step: 0.25)
    XCTAssertEqual(ticks.count, 5)                 // 0, 0.25, 0.5, 0.75, 1
    XCTAssertEqual(ticks.last!, 1, accuracy: 1e-9)
  }

  func test_evenTicks_never_overruns_upper_bound() {
    for t in SliderTickScale.evenTicks(0...2, step: 0.25) {
      XCTAssertLessThanOrEqual(t, 2)
    }
  }

  func test_evenTicks_degenerate_inputs_return_single_lower() {
    XCTAssertEqual(SliderTickScale.evenTicks(0...0, step: 0.25), [0])
    XCTAssertEqual(SliderTickScale.evenTicks(0...1, step: 0), [0])
  }

  // MARK: - labels

  func test_labels_drop_trailing_zeros_with_percent_g() {
    let labels = SliderTickScale.labels([0, 0.5, 1, 1.5, 2], format: "%g")
    XCTAssertEqual(labels.map { $0.text }, ["0", "0.5", "1", "1.5", "2"])
    XCTAssertEqual(labels.map { $0.value }, [0, 0.5, 1, 1.5, 2])
  }

  func test_label_id_is_its_value() {
    let label = SliderTickScale.Label(value: 0.75, text: "0.75")
    XCTAssertEqual(label.id, 0.75)
  }
}
