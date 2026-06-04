import XCTest
@testable import RatioThink

/// Deterministic coverage for the toolbar label copy. The
/// snapshot suite can't pixel-test the animated states, so the label
/// *text* is asserted here as a pure function of
/// `(ModelLoadCenter.State, fraction)`. `fraction` is sourced from
/// `ModelLoadCenter.progress` — the single determinacy source the
/// label, ring, and ellipsis-animation flag all share (review v1 F2),
/// so these tests exercise the real wiring rather than a parallel copy.
@MainActor
final class ModelLoadIndicatorLabelTests: XCTestCase {

  private func center(_ state: ModelLoadCenter.State) -> ModelLoadCenter {
    let c = ModelLoadCenter()
    c._testOverrideState(state)
    return c
  }

  // MARK: - prefix text

  func test_indeterminate_load_shows_model_id_without_percent() {
    let c = center(.loading(modelID: "qwen3-0.6b", loadedBytes: 0, totalBytes: 0, etaSeconds: nil))
    XCTAssertEqual(ModelLoadIndicator.labelPrefix(for: c.state, fraction: c.progress), "Loading qwen3-0.6b")
  }

  func test_determinate_load_shows_model_id_and_rounded_percent() {
    let c = center(.loading(modelID: "qwen3-0.6b", loadedBytes: 250, totalBytes: 1000, etaSeconds: 6.0))
    XCTAssertEqual(ModelLoadIndicator.labelPrefix(for: c.state, fraction: c.progress), "Loading qwen3-0.6b… 25%")
  }

  func test_failed_shows_static_load_failed() {
    let c = center(.failed(modelID: "qwen3-0.6b", message: "engine returned 502"))
    XCTAssertEqual(ModelLoadIndicator.labelPrefix(for: c.state, fraction: c.progress), "Load failed")
  }

  func test_engine_not_ready_shows_engine_starting() {
    let c = center(.engineNotReady(modelID: "qwen3-0.6b", detail: "Engine stopped"))
    XCTAssertEqual(ModelLoadIndicator.labelPrefix(for: c.state, fraction: c.progress), "Engine starting")
  }

  func test_ready_and_idle_and_cancelled_have_no_label() {
    XCTAssertNil(ModelLoadIndicator.labelPrefix(for: .ready(modelID: "qwen3-0.6b"), fraction: nil))
    XCTAssertNil(ModelLoadIndicator.labelPrefix(for: .idle, fraction: nil))
    XCTAssertNil(ModelLoadIndicator.labelPrefix(for: .cancelled(modelID: "qwen3-0.6b"), fraction: nil))
  }

  // MARK: - ellipsis animation gating

  // Only the indeterminate waiting states animate the trailing dots;
  // the determinate copy carries a percent that the cycling dots would
  // jitter, so it stays static.
  func test_indeterminate_load_animates_ellipsis() {
    let c = center(.loading(modelID: "m", loadedBytes: 0, totalBytes: 0, etaSeconds: nil))
    XCTAssertTrue(ModelLoadIndicator.labelAnimatesEllipsis(for: c.state, fraction: c.progress))
  }

  func test_engine_not_ready_animates_ellipsis() {
    let c = center(.engineNotReady(modelID: "m", detail: "Engine stopped"))
    XCTAssertTrue(ModelLoadIndicator.labelAnimatesEllipsis(for: c.state, fraction: c.progress))
  }

  func test_determinate_load_does_not_animate_ellipsis() {
    let c = center(.loading(modelID: "m", loadedBytes: 250, totalBytes: 1000, etaSeconds: nil))
    XCTAssertFalse(ModelLoadIndicator.labelAnimatesEllipsis(for: c.state, fraction: c.progress))
  }

  func test_terminal_states_do_not_animate_ellipsis() {
    XCTAssertFalse(ModelLoadIndicator.labelAnimatesEllipsis(for: .failed(modelID: "m", message: "x"), fraction: nil))
    XCTAssertFalse(ModelLoadIndicator.labelAnimatesEllipsis(for: .ready(modelID: "m"), fraction: nil))
    XCTAssertFalse(ModelLoadIndicator.labelAnimatesEllipsis(for: .idle, fraction: nil))
  }

  // MARK: - overflow frame (review v1 F2)

  // A `loaded > total` protocol bug must read consistently across the
  // label and the ring: `center.progress` returns nil (fall back to
  // indeterminate), so the copy drops the percent AND the ellipsis
  // animates — matching the spinning indeterminate ring instead of a
  // static label beside a moving wheel.
  func test_load_with_loaded_exceeding_total_falls_back_to_indeterminate_copy() {
    let c = center(.loading(modelID: "qwen3-0.6b", loadedBytes: 2000, totalBytes: 1000, etaSeconds: nil))
    XCTAssertNil(c.progress, "overflow frame must yield nil fraction")
    XCTAssertEqual(ModelLoadIndicator.labelPrefix(for: c.state, fraction: c.progress), "Loading qwen3-0.6b")
    XCTAssertTrue(
      ModelLoadIndicator.labelAnimatesEllipsis(for: c.state, fraction: c.progress),
      "overflow frame is indeterminate, so the ellipsis must animate in step with the ring"
    )
  }

  // MARK: - popover primary action (#218)

  // The popover surfaces exactly one control per state. #218: the
  // "Engine starting…" (`.engineNotReady`) state must offer "Stop Engine"
  // (terminate the booting engine + clean slate via onUnload), NOT the
  // old "Dismiss" that left the engine running. The rest of the mapping
  // is pinned so a future state addition can't silently fall through.
  func test_engineNotReady_primary_action_is_stopEngine() {
    XCTAssertEqual(
      ModelLoadPopover.primaryAction(for: .engineNotReady(modelID: "m", detail: "Engine stopped")),
      .stopEngine)
  }

  func test_loading_primary_action_is_cancel() {
    XCTAssertEqual(
      ModelLoadPopover.primaryAction(for: .loading(modelID: "m", loadedBytes: 0, totalBytes: 0, etaSeconds: nil)),
      .cancel)
  }

  func test_ready_primary_action_is_unload() {
    XCTAssertEqual(ModelLoadPopover.primaryAction(for: .ready(modelID: "m")), .unload)
  }

  func test_failed_primary_action_is_dismiss() {
    XCTAssertEqual(
      ModelLoadPopover.primaryAction(for: .failed(modelID: "m", message: "boom")),
      .dismiss)
  }

  func test_idle_and_cancelled_have_no_primary_action() {
    XCTAssertEqual(ModelLoadPopover.primaryAction(for: .idle),
                   ModelLoadPopover.PrimaryAction.none)
    XCTAssertEqual(ModelLoadPopover.primaryAction(for: .cancelled(modelID: "m")),
                   ModelLoadPopover.PrimaryAction.none)
  }
}
