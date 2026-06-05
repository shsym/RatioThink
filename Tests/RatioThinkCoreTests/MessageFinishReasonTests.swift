import XCTest
import SwiftData
@testable import RatioThinkCore

/// #434: the renderer reads the engine `finish_reason` off `Message.meta`
/// to tell a truncated turn from a normal one. The decode is centralized on
/// `Message` so the renderer and the send pipeline agree on one parse.
@available(macOS 14, *)
final class MessageFinishReasonTests: XCTestCase {
  /// Mirrors `ChatSendController.finishMeta` — snake_case `finish_reason`.
  private func meta(_ reason: String) -> Data {
    try! JSONSerialization.data(withJSONObject: ["finish_reason": reason])
  }

  func test_decodes_finish_reason_from_meta() {
    let m = Message(role: "assistant", content: "", meta: meta("length"))
    XCTAssertEqual(m.finishReason, "length")
  }

  func test_nil_meta_is_nil_finish_reason() {
    XCTAssertNil(Message(role: "assistant", content: "hi").finishReason)
  }

  func test_malformed_meta_is_nil() {
    let m = Message(role: "assistant", content: "", meta: Data([0x00, 0x01]))
    XCTAssertNil(m.finishReason)
  }
}
