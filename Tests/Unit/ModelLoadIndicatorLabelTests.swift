import XCTest
@testable import RatioThink

/// Deterministic coverage for the engine-status pip's inline label copy
///. The snapshot suite can't pixel-test the animated states, so
/// the label *text* and the ellipsis-animation flag are asserted here as
/// pure functions of `EngineIndicatorState` — the single unified state
/// the pip renders. This replaces the prior `(ModelLoadCenter.State,
/// fraction)` contract: the pip now folds engine lifecycle + load through
/// `EngineIndicatorState`, so the label is keyed off that enum directly.
///
/// Contract (design locked with the user):
///   · `.offline` / `.running` / `.starting` → NO inline text (bare dot;
///     the tooltip carries any detail). `pipLabel` returns nil.
///   · `.loading(id, fraction)` → "Loading <leaf>… N%" (determinate) or
///     "Loading <leaf>" + animated ellipsis (indeterminate). Uses the
///     model-id LEAF, not the full `<repo>/<file>` slug.
///   · `.error(err)` → the error `title`, static (no ellipsis).
final class ModelLoadIndicatorLabelTests: XCTestCase {

  // MARK: - bare-dot states have no inline label

  func test_offline_has_no_label() {
    XCTAssertNil(ModelLoadIndicator.pipLabel(for: .offline))
  }

  func test_running_has_no_label() {
    XCTAssertNil(ModelLoadIndicator.pipLabel(for: .running(modelID: "Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf")))
    XCTAssertNil(ModelLoadIndicator.pipLabel(for: .running(modelID: nil)))
  }

  func test_starting_has_no_label() {
    XCTAssertNil(ModelLoadIndicator.pipLabel(for: .starting(detail: "Engine starting…")))
  }

  // MARK: - loading label (determinate / indeterminate)

  func test_determinate_loading_shows_leaf_and_rounded_percent() {
    let state = EngineIndicatorState.loading(
      modelID: "Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf",
      fraction: 0.25
    )
    XCTAssertEqual(
      ModelLoadIndicator.pipLabel(for: state),
      "Loading Qwen3-0.6B-Q8_0.gguf… 25%",
      "determinate load must show the leaf name + a rounded percent"
    )
  }

  func test_indeterminate_loading_shows_leaf_without_percent() {
    let state = EngineIndicatorState.loading(
      modelID: "Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf",
      fraction: nil
    )
    XCTAssertEqual(
      ModelLoadIndicator.pipLabel(for: state),
      "Loading Qwen3-0.6B-Q8_0.gguf",
      "indeterminate load must show the leaf name, no percent (ellipsis is appended separately)"
    )
  }

  func test_bare_model_id_passes_through_as_its_own_leaf() {
    let state = EngineIndicatorState.loading(modelID: "qwen3-0.6b", fraction: 0.5)
    XCTAssertEqual(ModelLoadIndicator.pipLabel(for: state), "Loading qwen3-0.6b… 50%")
  }

  // MARK: - error label = the error title

  func test_error_shows_error_title() {
    let err = EngineIndicatorError(
      kind: .loadFailed,
      title: "Load failed",
      message: "engine returned 502",
      invitesModelChoice: false
    )
    XCTAssertEqual(ModelLoadIndicator.pipLabel(for: .error(err)), "Load failed")
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

  // MARK: - ellipsis animation gating

  // Only the INDETERMINATE load animates the trailing dots; the
  // determinate copy carries a percent that cycling dots would jitter,
  // and every other state is either a static label (error) or a bare dot.
  func test_indeterminate_loading_animates_ellipsis() {
    let state = EngineIndicatorState.loading(modelID: "m", fraction: nil)
    XCTAssertTrue(ModelLoadIndicator.pipLabelAnimatesEllipsis(for: state))
  }

  func test_determinate_loading_does_not_animate_ellipsis() {
    let state = EngineIndicatorState.loading(modelID: "m", fraction: 0.25)
    XCTAssertFalse(ModelLoadIndicator.pipLabelAnimatesEllipsis(for: state))
  }

  func test_non_loading_states_do_not_animate_ellipsis() {
    XCTAssertFalse(ModelLoadIndicator.pipLabelAnimatesEllipsis(for: .offline))
    XCTAssertFalse(ModelLoadIndicator.pipLabelAnimatesEllipsis(for: .starting(detail: "x")))
    XCTAssertFalse(ModelLoadIndicator.pipLabelAnimatesEllipsis(for: .running(modelID: "m")))
    let err = EngineIndicatorError(kind: .engineFailed, title: "Engine failed", message: "x", invitesModelChoice: false)
    XCTAssertFalse(ModelLoadIndicator.pipLabelAnimatesEllipsis(for: .error(err)))
  }

  // MARK: - LED tint → colour mapping (#412)

  // The pip dot/ring now render the pure `StatusLED.Tint` (ring = helper,
  // dot = engine) via the view's `color(for:)`. These pin the view's
  // tint→Color mapping so a colour regression is a unit failure, not just a
  // pixel diff. `.white` is `.primary` (appearance-adaptive ink) so the
  // "blink white" waiting LED is visible in BOTH light and dark toolbars;
  // `.greenWhite` is the quiet healthy tint; amber/red are trouble/given-up.
  func test_led_tint_colours() {
    XCTAssertEqual(ModelLoadIndicator.color(for: .off), .secondary)
    XCTAssertEqual(ModelLoadIndicator.color(for: .white), .primary)
    XCTAssertEqual(ModelLoadIndicator.color(for: .greenWhite), .green)
    XCTAssertEqual(ModelLoadIndicator.color(for: .amber), .orange)
    XCTAssertEqual(ModelLoadIndicator.color(for: .red), .red)
  }

  // The engine state → dot LED mapping (the pure RatioThinkCore reducer is
  // covered in HelperEngineIndicatorTests; this pins it survives through the
  // App module too, since the view depends on it).
  func test_engine_dot_led_per_state() {
    XCTAssertEqual(StatusLED.engineDot(for: .offline), StatusLED(tint: .off, blink: false))
    XCTAssertEqual(StatusLED.engineDot(for: .starting(detail: "x")), StatusLED(tint: .white, blink: true))
    XCTAssertEqual(StatusLED.engineDot(for: .running(modelID: "m")), StatusLED(tint: .greenWhite, blink: false))
    let err = EngineIndicatorError(kind: .engineFailed, title: "Engine failed", message: "x", invitesModelChoice: false)
    XCTAssertEqual(StatusLED.engineDot(for: .error(err)), StatusLED(tint: .amber, blink: true))
  }

  // MARK: - #396 popover detail (honest indeterminate — never "—" for a live load)

  private let mb: UInt64 = 1024 * 1024

  /// A load that has reported no byte total and no bytes yet is honestly
  /// indeterminate — the popover shows "Preparing…", never a "—" ETA.
  func test_loadingDetail_indeterminate_noBytes_isPreparing() {
    let state = ModelLoadCenter.State.loading(modelID: "m", loadedBytes: 0, totalBytes: 0, etaSeconds: nil)
    XCTAssertEqual(ModelLoadPopover.loadingDetail(for: state, fraction: nil), .preparing)
  }

  /// Bytes are flowing but the engine has no transfer-rate sample yet:
  /// show the loaded amount and an honest "Estimating…" ETA, not "—".
  func test_loadingDetail_indeterminate_withBytes_showsLoaded_andEstimating() {
    let state = ModelLoadCenter.State.loading(modelID: "m", loadedBytes: 128 * mb, totalBytes: 0, etaSeconds: nil)
    XCTAssertEqual(
      ModelLoadPopover.loadingDetail(for: state, fraction: nil),
      .indeterminate(loaded: "128 MB")
    )
  }

  /// Determinate load with a real ETA shows both concrete values.
  func test_loadingDetail_determinate_withEta_showsBytesAndEta() {
    let state = ModelLoadCenter.State.loading(modelID: "m", loadedBytes: 256 * mb, totalBytes: 1024 * mb, etaSeconds: 6.0)
    XCTAssertEqual(
      ModelLoadPopover.loadingDetail(for: state, fraction: 0.25),
      .determinate(loaded: "256 MB / 1.00 GB", eta: "6 s")
    )
  }

  /// Determinate progress but still no rate sample: the ETA is honestly
  /// "Estimating…" — the bug this ticket fixes was rendering "—" here.
  func test_loadingDetail_determinate_withoutEta_showsEstimating_notDash() {
    let state = ModelLoadCenter.State.loading(modelID: "m", loadedBytes: 256 * mb, totalBytes: 1024 * mb, etaSeconds: nil)
    let detail = ModelLoadPopover.loadingDetail(for: state, fraction: 0.25)
    XCTAssertEqual(detail, .determinate(loaded: "256 MB / 1.00 GB", eta: "Estimating…"))
    if case let .determinate(_, eta) = detail {
      XCTAssertNotEqual(eta, "—", "unknown ETA must never render as a meaningless dash (#396)")
    } else {
      XCTFail("expected determinate detail")
    }
  }

  /// Non-loading states have no load detail — the popover renders their
  /// own block (resident / failed / cancelled), never the "—/—" rows.
  func test_loadingDetail_isNil_for_nonLoading_states() {
    XCTAssertNil(ModelLoadPopover.loadingDetail(for: .ready(modelID: "m"), fraction: nil))
    XCTAssertNil(ModelLoadPopover.loadingDetail(for: .idle, fraction: nil))
    XCTAssertNil(ModelLoadPopover.loadingDetail(for: .cancelled(modelID: "m"), fraction: nil))
    XCTAssertNil(ModelLoadPopover.loadingDetail(for: .failed(modelID: "m", message: "x"), fraction: nil))
  }
}
