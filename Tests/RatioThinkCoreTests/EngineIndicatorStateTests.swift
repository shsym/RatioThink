import XCTest
@testable import RatioThinkCore

/// Exhaustive coverage for the pure `EngineIndicatorState.make` reducer:
/// every (engine × load) combination that matters, the precedence rules,
/// the dot-colour mapping, and the banner routing.
final class EngineIndicatorStateTests: XCTestCase {

  private func make(
    engine: EngineStatus,
    detail: String = "",
    resident: String? = nil
  ) -> EngineIndicatorState {
    EngineIndicatorState.make(engine: engine, engineDetail: detail, residentModelID: resident)
  }

  // MARK: - engine lifecycle (no active load)

  func test_stopped_engine_is_offline() {
    XCTAssertEqual(make(engine: .stopped), .offline)
    XCTAssertEqual(make(engine: .stopped).dot, .offline)
    XCTAssertNil(make(engine: .stopped).bannerError)
  }

  func test_starting_and_stopping_are_starting() {
    XCTAssertEqual(make(engine: .starting, detail: "Engine starting…"), .starting(detail: "Engine starting…"))
    XCTAssertEqual(make(engine: .stopping, detail: "Engine stopping…"), .starting(detail: "Engine stopping…"))
    XCTAssertEqual(make(engine: .starting).dot, .busy)
  }

  func test_running_engine_is_running_with_resident_model() {
    let state = make(engine: .running(port: 51234, profileID: "chat"), resident: "Qwen3-0.6B")
    XCTAssertEqual(state, .running(modelID: "Qwen3-0.6B"))
    XCTAssertEqual(state.dot, .running)
    XCTAssertNil(state.bannerError)
  }

  func test_running_engine_with_no_resident_is_running_nil() {
    XCTAssertEqual(make(engine: .running(port: 1, profileID: "chat")), .running(modelID: nil))
  }

  // MARK: - engine failures route to banner errors

  func test_memoryRisk_failure_invites_model_choice() {
    let state = make(engine: .failed(code: .memoryRisk, message: "resolved size 12 GB exceeds limit"))
    guard case let .error(err) = state else { return XCTFail("expected .error, got \(state)") }
    XCTAssertEqual(err.kind, .memoryRisk)
    XCTAssertTrue(err.invitesModelChoice)
    XCTAssertEqual(state.dot, .error)
    XCTAssertEqual(state.bannerError, err)
  }

  func test_engineGone_failure_is_engineGone_kind() {
    let state = make(engine: .failed(code: .engineGone, message: "process exited 9"))
    guard case let .error(err) = state else { return XCTFail("expected .error") }
    XCTAssertEqual(err.kind, .engineGone)
    XCTAssertFalse(err.invitesModelChoice)
    XCTAssertEqual(err.title, "Engine stopped unexpectedly")
  }

  func test_modelMissing_failure_invites_model_choice() {
    let state = make(engine: .failed(code: .modelMissing, message: "no such model"))
    guard case let .error(err) = state else { return XCTFail("expected .error") }
    XCTAssertEqual(err.kind, .modelMissing)
    XCTAssertTrue(err.invitesModelChoice)
  }

  func test_other_failure_is_generic_engineFailed() {
    let state = make(engine: .failed(code: .spawnFailed, message: "fork ENOENT"))
    guard case let .error(err) = state else { return XCTFail("expected .error") }
    XCTAssertEqual(err.kind, .engineFailed)
    XCTAssertEqual(err.message, "fork ENOENT")
  }

  // MARK: - anti-flap: transient unreachable is amber, never a red error

  func test_helper_unreachable_while_starting_is_amber_not_error() {
    // EngineStatusStore keeps `.starting` and folds the reason into the
    // detail on a transient poll failure — must read as starting, never
    // an error banner.
    let state = make(engine: .starting, detail: "Helper unreachable: connection invalid")
    XCTAssertEqual(state, .starting(detail: "Helper unreachable: connection invalid"))
    XCTAssertEqual(state.dot, .busy)
    XCTAssertNil(state.bannerError)
  }

  // MARK: - SoT-drift matrix: a non-running engine never folds to a resident

  /// The operator's exact case: the engine stopped while a model was still
  /// app-side `.ready`. The fold MUST be `.offline` (engine wins), so no
  /// surface deriving from it can show `Loaded — resident` on a dead engine.
  func test_stopped_engine_with_stale_ready_load_is_offline_not_resident() {
    let state = make(engine: .stopped, resident: "org/m")
    XCTAssertEqual(state, .offline)
    XCTAssertEqual(state.dot, .offline)
    if case .running = state { XCTFail("a stopped engine must never fold to .running/resident") }
  }

  /// Table-driven drift matrix: for every non-running engine, a stale
  /// `.ready` load must NOT yield `.running` (the popover's resident row +
  /// the gate's resident both key off `.running`). The one cell that DOES
  /// surface a resident is a genuinely `.running` engine.
  func test_resident_surfaces_only_when_engine_is_running() {
    let resident = "org/m"
    let nonRunning: [EngineStatus] = [
      .stopped,
      .starting,
      .stopping,
      .failed(code: .engineGone, message: "x"),
      .failed(code: .spawnFailed, message: "x"),
    ]
    for engine in nonRunning {
      let state = make(engine: engine, resident: resident)
      if case .running = state {
        XCTFail("engine \(engine) with a stale resident folded to .running — resident leaked")
      }
    }
    // The single legitimate resident cell.
    XCTAssertEqual(
      make(engine: .running(port: 1, profileID: "chat"), resident: resident),
      .running(modelID: resident)
    )
  }
}
