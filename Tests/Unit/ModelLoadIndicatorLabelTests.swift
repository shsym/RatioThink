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

  // MARK: - dot colour intent per state

  // The bare-dot states map to concrete colours via the reducer's `Dot`
  // intent: grey (offline) / amber (starting) / neutral adaptive ink
  // `.primary` (running) / red (error). These pin the view's mapping so a
  // colour regression is a unit failure, not just a pixel diff. Running is
  // `.primary` (not `.green`): a healthy engine is a QUIET neutral dot
  //, appearance-adaptive so it shows in both light and dark.
  func test_dot_colours_per_state() {
    XCTAssertEqual(ModelLoadIndicator.dotColor(for: .offline), .secondary)
    XCTAssertEqual(ModelLoadIndicator.dotColor(for: .starting(detail: "x")), .orange)
    XCTAssertEqual(ModelLoadIndicator.dotColor(for: .running(modelID: "m")), .primary)
    let err = EngineIndicatorError(kind: .engineFailed, title: "Engine failed", message: "x", invitesModelChoice: false)
    XCTAssertEqual(ModelLoadIndicator.dotColor(for: .error(err)), .red)
  }
}
