import XCTest
@testable import RatioThinkCore

/// #4: the App always asks before starting the engine/model on launch
/// (no silent auto-start). `LaunchEngineStartPrompt.shouldAsk` is the pure
/// "ask iff idle-with-a-target" decision the launch wiring evaluates once
/// the status settles.
final class LaunchEngineStartPromptTests: XCTestCase {
  func test_asks_when_stopped_with_a_default_target() {
    XCTAssertTrue(LaunchEngineStartPrompt.shouldAsk(
      status: .stopped,
      target: ModelTarget.resolve(selectedModelID: nil, profileDefault: "Qwen/Qwen3-0.6B")))
  }

  func test_497_asks_when_stopped_with_a_pinned_target_and_no_default() {
    // The launch ask keys on the same target the Load tap will boot — a
    // pinned chat with a no-default profile still gets the ask.
    XCTAssertTrue(LaunchEngineStartPrompt.shouldAsk(
      status: .stopped,
      target: ModelTarget.resolve(selectedModelID: "user/picked.gguf", profileDefault: nil)))
  }

  func test_does_not_ask_when_stopped_without_a_target() {
    XCTAssertFalse(LaunchEngineStartPrompt.shouldAsk(status: .stopped, target: nil))
    XCTAssertFalse(LaunchEngineStartPrompt.shouldAsk(
      status: .stopped, target: ModelTarget.resolve(selectedModelID: nil, profileDefault: "")))
    XCTAssertFalse(LaunchEngineStartPrompt.shouldAsk(
      status: .stopped, target: ModelTarget.resolve(selectedModelID: "   ", profileDefault: nil)))
  }

  func test_never_asks_for_non_stopped_states() {
    let withDefault = ModelTarget(modelID: "Qwen/Qwen3-0.6B", source: .profileDefault)
    XCTAssertFalse(LaunchEngineStartPrompt.shouldAsk(status: .starting, target: withDefault))
    XCTAssertFalse(LaunchEngineStartPrompt.shouldAsk(status: .running(EngineSessionSnapshot(port: 8080, profileID: "chat")), target: withDefault))
    XCTAssertFalse(LaunchEngineStartPrompt.shouldAsk(status: .stopping, target: withDefault))
    XCTAssertFalse(LaunchEngineStartPrompt.shouldAsk(status: .failed(code: .engineGone, message: "x"), target: withDefault))
  }
}
