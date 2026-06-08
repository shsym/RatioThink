import XCTest
@testable import RatioThink

/// Deterministic coverage for the engine-status pip's inline label copy + the
/// LED tint mapping. The pip folds engine lifecycle + resident model through
/// `EngineIndicatorState` (#469: there is no separate model-load axis), so the
/// label is keyed off that enum directly.
///
/// Contract (design locked with the user):
///   · `.offline` → "Model not loaded" (the one idle state with inline copy).
///   · `.running` / `.starting` → NO inline text from `pipLabel` (bare dot;
///     `.starting` renders its own live "Starting… (Ns)" counter).
///   · `.error(err)` → the error `title`, static.
final class ModelLoadIndicatorLabelTests: XCTestCase {

  // MARK: - idle / bare-dot states

  func test_offline_shows_model_not_loaded_label() {
    XCTAssertEqual(ModelLoadIndicator.pipLabel(for: .offline), "Model not loaded")
  }

  func test_running_has_no_label() {
    XCTAssertNil(ModelLoadIndicator.pipLabel(for: .running(modelID: "Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf")))
    XCTAssertNil(ModelLoadIndicator.pipLabel(for: .running(modelID: nil)))
  }

  func test_starting_has_no_label() {
    XCTAssertNil(ModelLoadIndicator.pipLabel(for: .starting(detail: "Engine starting…")))
  }

  // MARK: - error label = the error title

  func test_error_shows_error_title() {
    let err = EngineIndicatorError(
      kind: .engineFailed,
      title: "Engine failed",
      message: "engine returned 502",
      invitesModelChoice: false
    )
    XCTAssertEqual(ModelLoadIndicator.pipLabel(for: .error(err)), "Engine failed")
  }

  func test_memory_risk_error_shows_its_title() {
    let err = EngineIndicatorError(
      kind: .memoryRisk,
      title: "Model too large",
      message: "exceeds this Mac's safe memory limit",
      invitesModelChoice: true
    )
    XCTAssertEqual(ModelLoadIndicator.pipLabel(for: .error(err)), "Model too large")
  }

  // MARK: - LED tint → colour mapping (#412)

  func test_led_tint_colours() {
    XCTAssertEqual(ModelLoadIndicator.color(for: .off), .secondary)
    XCTAssertEqual(ModelLoadIndicator.color(for: .white), .primary)
    XCTAssertEqual(ModelLoadIndicator.color(for: .greenWhite), .green)
    XCTAssertEqual(ModelLoadIndicator.color(for: .amber), .orange)
    XCTAssertEqual(ModelLoadIndicator.color(for: .red), .red)
  }

  // The engine state → dot LED mapping. #469: a model switch is an engine
  // restart, so there is no `.loading` state — it folds to the amber starting
  // LED.
  func test_engine_dot_led_per_state() {
    XCTAssertEqual(StatusLED.engineDot(for: .offline), StatusLED(tint: .off, blink: false))
    XCTAssertEqual(StatusLED.engineDot(for: .starting(detail: "x")), StatusLED(tint: .white, blink: true))
    XCTAssertEqual(StatusLED.engineDot(for: .running(modelID: "m")), StatusLED(tint: .greenWhite, blink: false))
    let err = EngineIndicatorError(kind: .engineFailed, title: "Engine failed", message: "x", invitesModelChoice: false)
    XCTAssertEqual(StatusLED.engineDot(for: .error(err)), StatusLED(tint: .amber, blink: true))
  }
}
