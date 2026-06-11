import XCTest
@testable import RatioThinkCore

/// Exhaustive coverage of the `ChatStartGate` reducer — the pure send-gate
/// decision behind #397's no-model prompt. One case per scenario in the
/// ticket's launch→first-send matrix (S0..S13) plus the precedence rules.
final class ChatStartGateTests: XCTestCase {

  private let model = "Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf"

  private func eval(
    engine: EngineStatus = .stopped,
    helperError: String? = nil,
    resolved: String? = nil,
    selected: String? = nil,
    profileDefault: String? = nil,
    profileError: String? = nil
  ) -> ChatStartGate.State {
    ChatStartGate.evaluate(
      engineStatus: engine,
      helperError: helperError,
      resolvedModelID: resolved,
      target: ModelTarget.resolve(selectedModelID: selected,
                                  profileDefault: profileDefault),
      profileError: profileError
    )
  }

  private func defaultTarget(_ id: String) -> ChatStartGate.State {
    .needsLoad(target: ModelTarget(modelID: id, source: .profileDefault))
  }

  private func selectedTarget(_ id: String) -> ChatStartGate.State {
    .needsLoad(target: ModelTarget(modelID: id, source: .selected))
  }

  // MARK: - S0: a model resolves → send proceeds

  func test_S0_resolved_model_is_ready_even_if_engine_failed() {
    // Override/resident wins outright — the gate is not shown.
    XCTAssertEqual(
      eval(engine: .failed(code: .spawnFailed, message: "x"), resolved: "explicit"),
      .ready(modelID: "explicit")
    )
  }

  func test_resolved_empty_string_is_not_ready() {
    // Defensive: an empty resolved id must not count as a model.
    XCTAssertEqual(eval(engine: .stopped, resolved: "", profileDefault: model),
                   defaultTarget(model))
  }

  // MARK: - S1: engine starting (the reported bug)

  func test_S1_engine_starting_is_busy_not_no_model() {
    // App requested an explicit start and the engine is still coming up;
    // send must read as "starting", never "No model loaded / choose another".
    XCTAssertEqual(eval(engine: .starting, profileDefault: model),
                   .busy(.startingEngine))
  }

  func test_engine_stopping_is_busy() {
    XCTAssertEqual(eval(engine: .stopping, profileDefault: model),
                   .busy(.stoppingEngine))
  }

  // MARK: - S2: engine stopped, default exists → load it (Load starts engine)

  func test_S2_stopped_with_default_needs_default_load() {
    XCTAssertEqual(eval(engine: .stopped, profileDefault: model),
                   defaultTarget(model))
  }

  // MARK: - S3 / S5: no default configured

  func test_S5_stopped_without_default_is_noDefault() {
    XCTAssertEqual(eval(engine: .stopped, profileDefault: nil), .noDefault)
  }

  func test_empty_default_is_noDefault() {
    XCTAssertEqual(eval(engine: .stopped, profileDefault: ""), .noDefault)
  }

  func test_running_without_default_is_noDefault() {
    XCTAssertEqual(eval(engine: .running(EngineSessionSnapshot(port: 8080, profileID: "chat")), profileDefault: nil),
                   .noDefault)
  }

  // MARK: - S3c: engine running but nothing resident → load default now

  func test_running_idle_with_default_needs_default_load() {
    XCTAssertEqual(
      eval(engine: .running(EngineSessionSnapshot(port: 8080, profileID: "chat")), profileDefault: model),
      defaultTarget(model)
    )
  }

  // MARK: - S6/S7/S8/S9: engine failed → code + raw reason (affordance derives from EngineProblem, #477)

  func test_S6_modelMissing_is_engineFailed() {
    XCTAssertEqual(
      eval(engine: .failed(code: .modelMissing, message: "not downloaded"), profileDefault: model),
      .engineFailed(code: .modelMissing, reason: "not downloaded")
    )
  }

  func test_S7_memoryRisk_is_engineFailed() {
    XCTAssertEqual(
      eval(engine: .failed(code: .memoryRisk, message: "too large"), profileDefault: model),
      .engineFailed(code: .memoryRisk, reason: "too large")
    )
  }

  func test_killRejected_is_engineFailed() {
    XCTAssertEqual(
      eval(engine: .failed(code: .killRejected, message: "zombie"), profileDefault: model),
      .engineFailed(code: .killRejected, reason: "zombie")
    )
  }

  func test_modelUnsupported_is_engineFailed() {
    XCTAssertEqual(
      eval(engine: .failed(code: .modelUnsupported, message: "unsupported format"), profileDefault: model),
      .engineFailed(code: .modelUnsupported, reason: "unsupported format")
    )
  }

  func test_S8_spawnFailed_is_engineFailed() {
    XCTAssertEqual(
      eval(engine: .failed(code: .spawnFailed, message: "ENOENT")),
      .engineFailed(code: .spawnFailed, reason: "ENOENT")
    )
  }

  func test_S9_engineGone_is_engineFailed() {
    XCTAssertEqual(
      eval(engine: .failed(code: .engineGone, message: "exited 9")),
      .engineFailed(code: .engineGone, reason: "exited 9")
    )
  }

  // MARK: - S12: helper unreachable beats engine status

  func test_S12_helper_unreachable_takes_priority() {
    XCTAssertEqual(
      eval(engine: .failed(code: .spawnFailed, message: "stale"),
           helperError: "connection invalid", profileDefault: model),
      .helperUnreachable(reason: "connection invalid")
    )
  }

  func test_empty_helper_error_is_ignored() {
    XCTAssertEqual(eval(engine: .starting, helperError: "", profileDefault: model),
                   .busy(.startingEngine))
  }

  // MARK: - S13: broken profile config beats present default

  func test_S13_profile_error_is_configBroken() {
    XCTAssertEqual(
      eval(engine: .stopped, profileDefault: model, profileError: "marker unreadable"),
      .configBroken(reason: "marker unreadable")
    )
  }

  func test_profile_error_does_not_mask_a_resolved_model() {
    // If a model still resolves, a stale profile-marker error must not
    // block the send.
    XCTAssertEqual(
      eval(engine: .running(EngineSessionSnapshot(port: 8080, profileID: "chat")),
           resolved: "resident", profileDefault: model, profileError: "marker unreadable"),
      .ready(modelID: "resident")
    )
  }

  // MARK: - #497: the pinned selection rides the target (cross-product)

  func test_497_stopped_with_pin_offers_selected_not_default() {
    // THE ticket symptom: a pinned selection must never fall back to the
    // profile default in the stopped-engine prompt.
    XCTAssertEqual(eval(engine: .stopped, selected: "user/picked.gguf", profileDefault: model),
                   selectedTarget("user/picked.gguf"))
  }

  func test_497_stopped_with_pin_and_no_default_offers_selected() {
    XCTAssertEqual(eval(engine: .stopped, selected: "user/picked.gguf", profileDefault: nil),
                   selectedTarget("user/picked.gguf"))
  }

  func test_497_running_with_pin_unresolved_offers_selected() {
    XCTAssertEqual(
      eval(engine: .running(EngineSessionSnapshot(port: 8080, profileID: "chat")),
           selected: "user/picked.gguf", profileDefault: model),
      selectedTarget("user/picked.gguf")
    )
  }

  func test_497_blank_pin_falls_back_to_default() {
    XCTAssertEqual(eval(engine: .stopped, selected: "  ", profileDefault: model),
                   defaultTarget(model))
  }

  func test_497_no_pin_no_default_is_noDefault() {
    XCTAssertEqual(eval(engine: .stopped, selected: nil, profileDefault: nil), .noDefault)
  }

  func test_497_pin_does_not_mask_engine_failure() {
    XCTAssertEqual(
      eval(engine: .failed(code: .spawnFailed, message: "ENOENT"),
           selected: "user/picked.gguf", profileDefault: model),
      .engineFailed(code: .spawnFailed, reason: "ENOENT")
    )
  }

  func test_497_pin_does_not_mask_helper_unreachable() {
    XCTAssertEqual(
      eval(engine: .stopped, helperError: "connection invalid",
           selected: "user/picked.gguf", profileDefault: model),
      .helperUnreachable(reason: "connection invalid")
    )
  }

  func test_497_profile_error_beats_pin() {
    // Broken config is a structural fault; offering a Load that boots
    // against an unreadable profile would diverge from the helper.
    XCTAssertEqual(
      eval(engine: .stopped, selected: "user/picked.gguf",
           profileDefault: model, profileError: "marker unreadable"),
      .configBroken(reason: "marker unreadable")
    )
  }

  func test_497_resolved_send_model_still_wins_over_pin_target() {
    XCTAssertEqual(
      eval(engine: .running(EngineSessionSnapshot(port: 8080, profileID: "chat")),
           resolved: "served", selected: "user/picked.gguf", profileDefault: model),
      .ready(modelID: "served")
    )
  }
}
