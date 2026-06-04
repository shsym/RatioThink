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
    load: ModelLoadCenter.State = .idle,
    resolved: String? = nil,
    profileDefault: String? = nil,
    profileError: String? = nil
  ) -> ChatStartGate.State {
    ChatStartGate.evaluate(
      engineStatus: engine,
      helperError: helperError,
      load: load,
      resolvedModelID: resolved,
      profileDefault: profileDefault,
      profileError: profileError
    )
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
                   .needsDefaultLoad(modelID: model))
  }

  // MARK: - S1: engine starting (the reported bug)

  func test_S1_engine_starting_is_busy_not_no_model() {
    // App launched, engine auto-resuming, open chat, send → must read as
    // "starting", never "No model loaded / choose another".
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
                   .needsDefaultLoad(modelID: model))
  }

  func test_S2_stopped_after_failed_load_attempt_reoffers_default() {
    // A prior Load while stopped left `.engineNotReady`; re-offer Load.
    XCTAssertEqual(
      eval(engine: .stopped, load: .engineNotReady(modelID: model, detail: "Engine stopped"),
           profileDefault: model),
      .needsDefaultLoad(modelID: model)
    )
  }

  // MARK: - S3 / S5: no default configured

  func test_S5_stopped_without_default_is_noDefault() {
    XCTAssertEqual(eval(engine: .stopped, profileDefault: nil), .noDefault)
  }

  func test_empty_default_is_noDefault() {
    XCTAssertEqual(eval(engine: .stopped, profileDefault: ""), .noDefault)
  }

  func test_running_without_default_is_noDefault() {
    XCTAssertEqual(eval(engine: .running(port: 8080, profileID: "chat"), profileDefault: nil),
                   .noDefault)
  }

  // MARK: - S3c: engine running but nothing resident → load default now

  func test_running_idle_with_default_needs_default_load() {
    XCTAssertEqual(
      eval(engine: .running(port: 8080, profileID: "chat"), load: .idle, profileDefault: model),
      .needsDefaultLoad(modelID: model)
    )
  }

  // MARK: - S10: model load in flight

  func test_running_loading_is_busy_loadingModel() {
    XCTAssertEqual(
      eval(engine: .running(port: 8080, profileID: "chat"),
           load: .loading(modelID: model, loadedBytes: 1, totalBytes: 2, etaSeconds: nil),
           profileDefault: model),
      .busy(.loadingModel(modelID: model))
    )
  }

  func test_loading_while_stopped_is_busy_loadingModel() {
    // The load axis is authoritative for "loading" even if the engine
    // status poll has not caught up.
    XCTAssertEqual(
      eval(engine: .stopped,
           load: .loading(modelID: model, loadedBytes: 0, totalBytes: 0, etaSeconds: nil)),
      .busy(.loadingModel(modelID: model))
    )
  }

  // MARK: - S11: model load failed

  func test_running_loadFailed_surfaces_reason() {
    XCTAssertEqual(
      eval(engine: .running(port: 8080, profileID: "chat"),
           load: .failed(modelID: model, message: "model_not_found")),
      .loadFailed(modelID: model, reason: "model_not_found")
    )
  }

  // MARK: - S6/S7/S8/S9: engine failed → reason + retryable flag

  func test_S6_modelMissing_is_retryable_engineFailed() {
    XCTAssertEqual(
      eval(engine: .failed(code: .modelMissing, message: "not downloaded"), profileDefault: model),
      .engineFailed(code: .modelMissing, reason: "not downloaded", retryable: true)
    )
  }

  func test_S7_memoryRisk_is_not_retryable() {
    XCTAssertEqual(
      eval(engine: .failed(code: .memoryRisk, message: "too large"), profileDefault: model),
      .engineFailed(code: .memoryRisk, reason: "too large", retryable: false)
    )
  }

  func test_killRejected_is_not_retryable() {
    XCTAssertEqual(
      eval(engine: .failed(code: .killRejected, message: "zombie"), profileDefault: model),
      .engineFailed(code: .killRejected, reason: "zombie", retryable: false)
    )
  }

  func test_S8_spawnFailed_is_retryable() {
    XCTAssertEqual(
      eval(engine: .failed(code: .spawnFailed, message: "ENOENT")),
      .engineFailed(code: .spawnFailed, reason: "ENOENT", retryable: true)
    )
  }

  func test_S9_engineGone_is_retryable() {
    XCTAssertEqual(
      eval(engine: .failed(code: .engineGone, message: "exited 9")),
      .engineFailed(code: .engineGone, reason: "exited 9", retryable: true)
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
      eval(engine: .running(port: 8080, profileID: "chat"),
           resolved: "resident", profileDefault: model, profileError: "marker unreadable"),
      .ready(modelID: "resident")
    )
  }
}
