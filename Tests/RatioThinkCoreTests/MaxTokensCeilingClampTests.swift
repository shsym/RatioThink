import XCTest
@testable import RatioThinkCore

/// #474: the App must clamp the profile's `max_tokens` DOWN to the launched
/// engine's effective ceiling before send, so a memory-squeezed launch (where
/// chat-apc reports a low `runtime::max-output-tokens`) never trips the clean
/// 400 (`max_tokens must be in [1, N]`) that fails the whole turn. These cover
/// the pure clamp matrix and the wire decode of the ceiling the engine reports
/// on `GET /v1/models`.
final class MaxTokensCeilingClampTests: XCTestCase {
  // MARK: - clampMaxTokens (pure)

  /// A `nil` ceiling (pre-#474 engine, or not yet reconciled) means "unknown"
  /// — pass the profile value through untouched rather than guess.
  func test_nil_ceiling_passes_profile_value_through() {
    XCTAssertEqual(ChatSendController.clampMaxTokens(2048, toCeiling: nil), 2048)
  }

  /// A non-positive ceiling is "unknown / no model" (the engine reports 0 when
  /// nothing is registered). Clamping to 0 would be a worse failure than the
  /// blind value, so it is treated as no-clamp.
  func test_zero_or_negative_ceiling_does_not_clamp() {
    XCTAssertEqual(ChatSendController.clampMaxTokens(2048, toCeiling: 0), 2048)
    XCTAssertEqual(ChatSendController.clampMaxTokens(2048, toCeiling: -1), 2048)
  }

  /// The reported bug: profile 2048 over a squeezed ceiling of 512 → clamp to
  /// 512 so the turn succeeds (shorter reply) instead of a 400.
  func test_profile_above_ceiling_clamps_down() {
    XCTAssertEqual(ChatSendController.clampMaxTokens(2048, toCeiling: 512), 512)
  }

  /// Down-only: an intentionally-lower profile value is never raised to the
  /// ceiling.
  func test_profile_below_ceiling_is_preserved() {
    XCTAssertEqual(ChatSendController.clampMaxTokens(256, toCeiling: 512), 256)
  }

  /// Exactly at the ceiling stays put (inclusive bound, mirrors chat-apc's
  /// `[1, ceiling]`).
  func test_profile_equal_to_ceiling_is_unchanged() {
    XCTAssertEqual(ChatSendController.clampMaxTokens(512, toCeiling: 512), 512)
  }

  // MARK: - ModelInfo wire decode

  /// chat-apc (#474) attaches `max_output_tokens` to each `/v1/models` entry;
  /// the App decodes it into `ModelInfo.maxOutputTokens`.
  func test_model_info_decodes_max_output_tokens() throws {
    let json = #"{"id":"qwen3","object":"model","owned_by":"pie","max_output_tokens":512}"#
    let info = try JSONDecoder().decode(ModelInfo.self, from: Data(json.utf8))
    XCTAssertEqual(info.id, "qwen3")
    XCTAssertEqual(info.maxOutputTokens, 512)
  }

  /// A pre-#474 engine omits the field — it must decode to `nil` (no clamp),
  /// not fail the whole `/v1/models` decode.
  func test_model_info_without_field_decodes_nil() throws {
    let json = #"{"id":"qwen3","object":"model","owned_by":"pie"}"#
    let info = try JSONDecoder().decode(ModelInfo.self, from: Data(json.utf8))
    XCTAssertNil(info.maxOutputTokens)
  }
}
