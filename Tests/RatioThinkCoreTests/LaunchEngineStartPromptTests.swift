import XCTest
@testable import RatioThinkCore

/// #4: the App always asks before starting the engine/model on launch
/// (no silent auto-start). `LaunchEngineStartPrompt.shouldAsk` is the pure
/// "ask iff idle-with-a-default" decision the launch wiring evaluates once
/// the status settles.
final class LaunchEngineStartPromptTests: XCTestCase {
  func test_asks_when_stopped_with_a_default_model() {
    XCTAssertTrue(LaunchEngineStartPrompt.shouldAsk(status: .stopped, profileDefault: "Qwen/Qwen3-0.6B"))
  }

  func test_does_not_ask_when_stopped_without_a_default() {
    XCTAssertFalse(LaunchEngineStartPrompt.shouldAsk(status: .stopped, profileDefault: nil))
    XCTAssertFalse(LaunchEngineStartPrompt.shouldAsk(status: .stopped, profileDefault: ""))
    XCTAssertFalse(LaunchEngineStartPrompt.shouldAsk(status: .stopped, profileDefault: "   "))
  }

  func test_never_asks_for_non_stopped_states() {
    let withDefault = "Qwen/Qwen3-0.6B"
    XCTAssertFalse(LaunchEngineStartPrompt.shouldAsk(status: .starting, profileDefault: withDefault))
    XCTAssertFalse(LaunchEngineStartPrompt.shouldAsk(status: .running(port: 8080, profileID: "chat"), profileDefault: withDefault))
    XCTAssertFalse(LaunchEngineStartPrompt.shouldAsk(status: .stopping, profileDefault: withDefault))
    XCTAssertFalse(LaunchEngineStartPrompt.shouldAsk(status: .failed(code: .engineGone, message: "x"), profileDefault: withDefault))
  }
}
