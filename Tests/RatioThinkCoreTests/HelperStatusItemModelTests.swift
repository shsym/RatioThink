import XCTest
@testable import RatioThinkCore

/// Pins the EngineStatus → menu-bar UI mapping. RatioThinkCoreTests can run
/// this without AppKit, so a regression in the dot color / label /
/// Pause-vs-Resume affordance surfaces here instead of waiting on the
/// S4 seated-GUI run.
final class HelperStatusItemModelTests: XCTestCase {

  func test_stopped_isGray_withEnabledResume() {
    let m = HelperStatusItemModel.make(from: .stopped)
    XCTAssertEqual(m.dot, .stopped)
    XCTAssertEqual(m.engineLabel, "Engine: stopped")
    XCTAssertEqual(m.pauseResume.title, "Resume Engine")
    XCTAssertTrue(m.pauseResume.enabled,
                  "Resume must be actionable when stopped — ProfileStore + resolver are wired; a disabled Resume strands the engine and defers every model load ( follow-up)")
    XCTAssertEqual(m.pauseResume.action, .resume)
  }

  func test_starting_isLoading_withEnabledPause() {
    let m = HelperStatusItemModel.make(from: .starting)
    XCTAssertEqual(m.dot, .loading)
    XCTAssertEqual(m.engineLabel, "Engine: starting…")
    XCTAssertEqual(m.pauseResume.title, "Pause Engine")
    XCTAssertTrue(m.pauseResume.enabled)
    XCTAssertEqual(m.pauseResume.action, .pause)
  }

  func test_running_carriesProfileAndPort_andEnablesPause() {
    let m = HelperStatusItemModel.make(from: .running(EngineSessionSnapshot(port: 54321, profileID: "chat")))
    XCTAssertEqual(m.dot, .running)
    XCTAssertEqual(m.engineLabel, "Engine: running — chat @ port 54321")
    XCTAssertEqual(m.pauseResume.title, "Pause Engine")
    XCTAssertTrue(m.pauseResume.enabled)
    XCTAssertEqual(m.pauseResume.action, .pause)
  }

  func test_stopping_isLoading_andPauseDisabled() {
    let m = HelperStatusItemModel.make(from: .stopping)
    XCTAssertEqual(m.dot, .loading)
    XCTAssertEqual(m.engineLabel, "Engine: stopping…")
    XCTAssertEqual(m.pauseResume.title, "Pause Engine")
    XCTAssertFalse(m.pauseResume.enabled,
                   "Cannot pause something that's already stopping")
    XCTAssertEqual(m.pauseResume.action, .none)
  }

  func test_failed_isError_withCodeAndMessage_andRetryableResumeEnabled() {
    let m = HelperStatusItemModel.make(
      from: .failed(code: .spawnFailed, message: "binary missing")
    )
    XCTAssertEqual(m.dot, .error)
    XCTAssertTrue(m.engineLabel.contains("spawnFailed"))
    // #477: the menu renders the curated taxonomy line; the raw status
    // diagnostic never appears.
    XCTAssertTrue(m.engineLabel.contains("The engine failed to start"))
    XCTAssertFalse(m.engineLabel.contains("binary missing"))
    XCTAssertEqual(m.pauseResume.title, "Resume Engine")
    XCTAssertTrue(m.pauseResume.enabled,
                  "recoverable failures must keep a working Resume so the user can retry after fixing the cause")
    XCTAssertEqual(m.pauseResume.action, .resume)
  }

  func test_modelMissingFailure_keepsResumeEnabledForRetry() {
    // The  follow-up: a missing model (fresh install / stale profile)
    // surfaces as a `.failed(.modelMissing)` status instead of a silent
    // `.stopped`, and the menu Resume stays actionable so the user can
    // download the model and retry without relaunching the helper.
    let m = HelperStatusItemModel.make(
      from: .failed(code: .modelMissing, message: "no model at <path>; not in HF cache")
    )
    XCTAssertEqual(m.dot, .error)
    XCTAssertTrue(m.engineLabel.contains("modelMissing"))
    XCTAssertTrue(m.pauseResume.enabled,
                  "modelMissing is user-recoverable (download the model) — Resume must not be disabled")
    XCTAssertEqual(m.pauseResume.action, .resume)
  }

  func test_memoryRiskFailure_surfacesActionableMenuCopy() {
    let m = HelperStatusItemModel.make(
      from: .failed(
        code: .memoryRisk,
        message: "memory risk: model was not launched; choose a smaller model"
      )
    )
    XCTAssertEqual(m.dot, .error)
    XCTAssertTrue(m.engineLabel.contains("memoryRisk"),
                  "GUI menu label must carry the structured memory-risk code; got \(m.engineLabel)")
    XCTAssertTrue(m.engineLabel.contains("Pick a smaller model"),
                  "GUI menu label must include the taxonomy recovery copy; got \(m.engineLabel)")
    XCTAssertEqual(m.pauseResume.title, "Resume Engine")
    XCTAssertFalse(m.pauseResume.enabled,
                   "memory-risk failures should not invite an immediate retry of the same unsafe model")
    XCTAssertEqual(m.pauseResume.action, .resume)
  }

  func test_failed_label_isBounded_andNeverShowsRawMessage() {
    // #477: the label renders the (short) taxonomy copy regardless of the
    // raw diagnostic's size; the raw text never appears.
    let long = String(repeating: "x", count: 500)
    let m = HelperStatusItemModel.make(
      from: .failed(code: .handshakeTimeout, message: long)
    )
    XCTAssertFalse(m.engineLabel.contains("xxx"),
                   "raw status diagnostic must not reach the menu; got \(m.engineLabel)")
    XCTAssertLessThan(m.engineLabel.count, 200,
                      "menu-item labels must be bounded; got \(m.engineLabel.count) chars")
    // The width guard itself stays covered should future copy grow.
    XCTAssertEqual(HelperStatusItemModel.truncate(long, to: 120).count, 121,
                   "120-char prefix + ellipsis")
    XCTAssertTrue(HelperStatusItemModel.truncate(long, to: 120).hasSuffix("…"))
  }

  func test_killRejected_isErrorDot_withResumeDisabled() {
    let m = HelperStatusItemModel.make(
      from: .failed(code: .killRejected, message: "zombie pid=1234")
    )
    XCTAssertEqual(m.dot, .error,
                   "killRejected must surface as red dot — supervisor refuses re-start")
    XCTAssertFalse(m.pauseResume.enabled)
  }

  // MARK: - #396/#424 working-state affordance (motion + not color-only)

  /// The transitional `.loading` mark must be distinguishable from
  /// `.running` by SHAPE, not color alone — a colorblind user otherwise
  /// cannot tell "engine starting" (white) from "engine running" (green).
  /// The brand triangle is an OUTLINE while loading and SOLID while
  /// running, so the FILL — not the tint — carries the distinction (#396).
  func test_loading_shape_is_distinct_from_running_notColorOnly() {
    XCTAssertFalse(HelperStatusItemModel.Dot.loading.isFilled,
                   "loading is an outline triangle")
    XCTAssertTrue(HelperStatusItemModel.Dot.running.isFilled,
                  "running is a filled brand mark; the AppKit renderer knocks out its center")
    XCTAssertNotEqual(
      HelperStatusItemModel.Dot.loading.isFilled,
      HelperStatusItemModel.Dot.running.isFilled,
      "loading and running must differ by fill, not just tint color (#396)"
    )
  }

  /// `.error` must be distinguishable from `.running` by SHAPE, not the
  /// amber-vs-green tint alone — both are SOLID triangles, so the
  /// exclamation knockout badge is the non-color cue (#396).
  func test_error_badge_is_distinct_from_running_notColorOnly() {
    XCTAssertTrue(HelperStatusItemModel.Dot.error.isFilled)
    XCTAssertTrue(HelperStatusItemModel.Dot.running.isFilled)
    XCTAssertTrue(HelperStatusItemModel.Dot.error.showsErrorBadge,
                  "error carries the '!' knockout")
    XCTAssertFalse(HelperStatusItemModel.Dot.running.showsErrorBadge,
                   "running must not — so error/running differ by shape, not just tint (#396)")
  }

  /// The view no longer owns the brand-mark shape decision — it reads
  /// `isFilled` / `showsErrorBadge` off the pure model so the mapping is
  /// testable without AppKit (#424). Outline = idle/working; filled =
  /// engine present; badge = error only.
  func test_brand_mark_shape_mapping_is_stable() {
    XCTAssertEqual(HelperStatusItemModel.Dot.stopped.isFilled, false)
    XCTAssertEqual(HelperStatusItemModel.Dot.loading.isFilled, false)
    XCTAssertEqual(HelperStatusItemModel.Dot.running.isFilled, true)
    XCTAssertEqual(HelperStatusItemModel.Dot.error.isFilled, true)

    XCTAssertEqual(HelperStatusItemModel.Dot.stopped.showsErrorBadge, false)
    XCTAssertEqual(HelperStatusItemModel.Dot.loading.showsErrorBadge, false)
    XCTAssertEqual(HelperStatusItemModel.Dot.running.showsErrorBadge, false)
    XCTAssertEqual(HelperStatusItemModel.Dot.error.showsErrorBadge, true)
  }

  /// A running async operation (engine starting/stopping) must carry an
  /// active affordance — the view animates while `isAnimated`, so the
  /// menu-bar mark is never a *static* colored dot for in-progress work
  /// (#396 invariant 1). Steady states do not animate.
  func test_only_loading_dot_animates() {
    XCTAssertTrue(HelperStatusItemModel.Dot.loading.isAnimated,
                  "transitional starting/stopping must show motion, not a static dot")
    XCTAssertFalse(HelperStatusItemModel.Dot.stopped.isAnimated)
    XCTAssertFalse(HelperStatusItemModel.Dot.running.isAnimated)
    XCTAssertFalse(HelperStatusItemModel.Dot.error.isAnimated)
  }

  /// The menu-bar button's accessibility label must describe the app AND
  /// the current engine status (#424 acceptance). The model supplies the
  /// state word; the view composes "Rational engine <word>".
  func test_accessibilityWord_describes_each_engine_state() {
    XCTAssertEqual(HelperStatusItemModel.Dot.stopped.accessibilityWord, "stopped")
    XCTAssertEqual(HelperStatusItemModel.Dot.running.accessibilityWord, "running")
    XCTAssertEqual(HelperStatusItemModel.Dot.error.accessibilityWord, "failed")

    // `.loading` collapses .starting AND .stopping into one visual state,
    // so its AX word must be SUB-STATE-NEUTRAL — never claim a direction
    // (announcing "starting" during a stop would be wrong; F1).
    XCTAssertEqual(HelperStatusItemModel.Dot.loading.accessibilityWord, "changing state")
    XCTAssertNotEqual(HelperStatusItemModel.Dot.loading.accessibilityWord, "starting")
  }

  /// A STOPPING engine maps to `.loading`, so the status-button AX word
  /// must not announce "starting" — the precise sub-state rides the menu
  /// label (`engineLabel`) instead (F1: the AX word is the button's sole
  /// disambiguator, so it stays neutral rather than wrong).
  func test_stopping_accessibilityWord_does_not_say_starting() {
    let stopping = HelperStatusItemModel.make(from: .stopping)
    XCTAssertEqual(stopping.dot, .loading)
    XCTAssertFalse(stopping.dot.accessibilityWord.contains("starting"),
                   "stopping must not announce 'starting' on the status button")
    // The precise sub-state still rides the menu label.
    XCTAssertEqual(stopping.engineLabel, "Engine: stopping…")
  }
}
