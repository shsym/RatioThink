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
    message: String = "spawn ENOENT",
    invitesModelChoice: Bool = false
  ) -> EngineIndicatorError {
    EngineIndicatorError(kind: kind, title: title, message: message, invitesModelChoice: invitesModelChoice)
  }

  // MARK: - which states banner

  func test_non_error_states_never_banner() {
    XCTAssertNil(EngineStatusBanner.model(from: .offline, acknowledgedSignature: nil))
    XCTAssertNil(EngineStatusBanner.model(from: .starting(detail: "Engine starting…"), acknowledgedSignature: nil))
    XCTAssertNil(EngineStatusBanner.model(from: .running(modelID: "m"), acknowledgedSignature: nil))
    XCTAssertNil(EngineStatusBanner.model(from: .loading(modelID: "m", fraction: 0.5), acknowledgedSignature: nil))
    XCTAssertNil(EngineStatusBanner.model(from: .loading(modelID: "m", fraction: nil), acknowledgedSignature: nil))
  }

  func test_error_state_banners_with_title_and_message() {
    let model = EngineStatusBanner.model(from: .error(error()), acknowledgedSignature: nil)
    XCTAssertEqual(model?.title, "Engine failed")
    XCTAssertEqual(model?.message, "spawn ENOENT")
  }

  // MARK: - invitesModelChoice hint

  func test_model_choice_failure_appends_model_menu_hint() {
    let err = error(
      kind: .memoryRisk,
      title: "Model too large",
      message: "The model exceeds this Mac's safe memory limit.",
      invitesModelChoice: true
    )
    let model = EngineStatusBanner.model(from: .error(err), acknowledgedSignature: nil)
    XCTAssertEqual(
      model?.message,
      "The model exceeds this Mac's safe memory limit. Pick a smaller model from the Model menu.",
      "a model-choice failure must invite the user to the Model menu"
    )
  }

  func test_non_model_choice_failure_has_no_hint() {
    let model = EngineStatusBanner.model(from: .error(error(invitesModelChoice: false)), acknowledgedSignature: nil)
    XCTAssertEqual(model?.message, "spawn ENOENT")
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
