import XCTest
@testable import RatioThink

/// Pure gating + dedup coverage for the in-window engine-error banner
///. The banner content + visibility are a pure function of
/// `(EngineIndicatorState, acknowledgedSignature)`, so the "which states
/// banner / Dismiss acks / a different failure re-shows" contract is
/// asserted here without SwiftUI. Store-level ack persistence lives in
/// `EngineStatusStoreTests` (RatioThinkCoreTests).
final class EngineStatusBannerTests: XCTestCase {

  private func error(
    kind: EngineIndicatorError.Kind = .engineFailed,
    title: String = "Engine failed",
    message: String = "spawn ENOENT"
  ) -> EngineIndicatorError {
    EngineIndicatorError(kind: kind, title: title, message: message)
  }

  // MARK: - which states banner

  func test_non_error_states_never_banner() {
    XCTAssertNil(EngineStatusBanner.model(from: .offline, acknowledgedSignature: nil))
    XCTAssertNil(EngineStatusBanner.model(from: .starting(detail: "Engine starting…"), acknowledgedSignature: nil))
    XCTAssertNil(EngineStatusBanner.model(from: .running(modelID: "m"), acknowledgedSignature: nil))
  }

  func test_error_state_banners_with_title_and_message() {
    let model = EngineStatusBanner.model(from: .error(error()), acknowledgedSignature: nil)
    XCTAssertEqual(model?.title, "Engine failed")
    XCTAssertEqual(model?.message, "spawn ENOENT")
  }

  // MARK: - no per-surface hint (#477)

  func test_banner_renders_taxonomy_message_without_appended_hint() {
    // The EngineProblem copy already names the next action; the banner
    // must not append its own hint on top.
    let err = error(
      kind: .memoryRisk,
      title: "Model too large",
      message: "This model exceeds this Mac’s safe memory limit. Pick a smaller model."
    )
    let model = EngineStatusBanner.model(from: .error(err), acknowledgedSignature: nil)
    XCTAssertEqual(
      model?.message,
      "This model exceeds this Mac’s safe memory limit. Pick a smaller model.",
      "the banner must render the taxonomy copy verbatim"
    )
    XCTAssertFalse(model?.message.contains("Model menu") ?? true)
  }

  // MARK: - dedup (Dismiss acks; a DIFFERENT failure re-shows)

  func test_acknowledged_failure_is_suppressed() {
    let err = error()
    let sig = EngineStatusBanner.signature(for: err)
    XCTAssertNil(
      EngineStatusBanner.model(from: .error(err), acknowledgedSignature: sig),
      "the dismissed failure must not re-banner"
    )
  }

  func test_different_failure_reshows_after_ack() {
    let dismissed = error(title: "Engine failed", message: "spawn ENOENT")
    let sig = EngineStatusBanner.signature(for: dismissed)

    // A genuinely different failure (different message) must banner again.
    let newer = error(kind: .engineGone, title: "Engine stopped unexpectedly", message: "exit 9")
    let model = EngineStatusBanner.model(from: .error(newer), acknowledgedSignature: sig)
    XCTAssertNotNil(model, "a distinct failure must re-show even after a prior dismiss")
    XCTAssertEqual(model?.title, "Engine stopped unexpectedly")
  }

  func test_signature_distinguishes_kind_and_message() {
    let a = error(kind: .engineFailed, message: "x")
    let b = error(kind: .engineGone, message: "x")
    let c = error(kind: .engineFailed, message: "y")
    XCTAssertNotEqual(EngineStatusBanner.signature(for: a), EngineStatusBanner.signature(for: b),
                      "different kind ⇒ different signature")
    XCTAssertNotEqual(EngineStatusBanner.signature(for: a), EngineStatusBanner.signature(for: c),
                      "different message ⇒ different signature")
    XCTAssertEqual(EngineStatusBanner.signature(for: a),
                   EngineStatusBanner.signature(for: error(kind: .engineFailed, message: "x")),
                   "same kind + message ⇒ same signature (stable)")
  }
}
