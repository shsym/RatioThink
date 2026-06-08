import XCTest
@testable import RatioThinkCore

/// Unit tests for `ActiveModelLaunchPolicy.decide` (#469) — the pure routing
/// that maps a model pick to the engine lifecycle action that actually serves
/// it. v1 pie binds the served model at boot, so a served-model change is a
/// start/restart, never a `/v1/models/load`.
final class ActiveModelLaunchPolicyTests: XCTestCase {
  private let pick = "org/repo/model-b.gguf"

  func test_stoppedEngine_picksStart() {
    XCTAssertEqual(
      ActiveModelLaunchPolicy.decide(modelID: pick, status: .stopped, residentModelID: nil),
      .startEngine(modelOverride: pick))
  }

  func test_runningDifferentModel_picksRestart() {
    XCTAssertEqual(
      ActiveModelLaunchPolicy.decide(
        modelID: pick,
        status: .running(port: 8080, profileID: "chat"),
        residentModelID: "org/repo/model-a.gguf"),
      .restartEngine(modelOverride: pick))
  }

  func test_runningResidentIsThePick_isNoOp() {
    XCTAssertEqual(
      ActiveModelLaunchPolicy.decide(
        modelID: pick,
        status: .running(port: 8080, profileID: "chat"),
        residentModelID: pick),
      .alreadyResident)
  }

  func test_runningWithNothingResident_picksRestart() {
    // Engine `.running` but no model reconciled yet — a pick still needs the
    // engine rebuilt to bind the chosen model (it is not the boot model).
    XCTAssertEqual(
      ActiveModelLaunchPolicy.decide(
        modelID: pick,
        status: .running(port: 8080, profileID: "chat"),
        residentModelID: nil),
      .restartEngine(modelOverride: pick))
  }

  func test_starting_defersBusy() {
    XCTAssertEqual(
      ActiveModelLaunchPolicy.decide(modelID: pick, status: .starting, residentModelID: nil),
      .deferBusy)
  }

  func test_stopping_defersBusy() {
    XCTAssertEqual(
      ActiveModelLaunchPolicy.decide(modelID: pick, status: .stopping, residentModelID: "x"),
      .deferBusy)
  }

  func test_retryableFailure_picksStart() {
    for code: EngineErrorCode in [.engineGone, .spawnFailed, .modelMissing] {
      XCTAssertEqual(
        ActiveModelLaunchPolicy.decide(
          modelID: pick,
          status: .failed(code: code, message: "x"),
          residentModelID: nil),
        .startEngine(modelOverride: pick),
        "retryable failure \(code) should invite a fresh start on a pick")
    }
  }

  func test_terminalFailure_isBlocked() {
    for code: EngineErrorCode in [.memoryRisk, .killRejected] {
      XCTAssertEqual(
        ActiveModelLaunchPolicy.decide(
          modelID: pick,
          status: .failed(code: code, message: "x"),
          residentModelID: nil),
        .blockedTerminal,
        "terminal failure \(code) must not re-fire a guaranteed-to-fail start")
    }
  }
}
