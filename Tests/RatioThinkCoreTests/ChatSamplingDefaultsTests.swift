import XCTest
@testable import RatioThinkCore

/// #434: the per-chat default token budget. Raised 2048 → 4096 so a thinking
/// model has room to reason AND answer before hitting the cap. The honest
/// truncation notice (`TurnNotice`) covers the residual, and the composer's
/// "Max tokens" slider (64…8192) lets a user push higher when needed.
final class ChatSamplingDefaultsTests: XCTestCase {
  func test_default_max_tokens_is_4096() {
    XCTAssertEqual(ChatSampling().maxTokens, 4096)
  }

  /// Temperature / top-p defaults are unchanged by #434.
  func test_other_sampling_defaults_unchanged() {
    let s = ChatSampling()
    XCTAssertEqual(s.temperature, 0.7)
    XCTAssertEqual(s.topP, 0.9)
  }
}
