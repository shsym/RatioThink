import XCTest
@testable import RatioThinkCore

/// Wire-policy tests for `PieControlClient.classifyFrame`. The
/// classifier is the synchronous core of the listener loop — driving
/// it with synthetic msgpack bytes covers F2's fail-fast contract
/// (review ) without standing up a real WebSocket.
///
/// Boundary corner cases for the encoder itself live in
/// `MessagePackTests`.
final class PieControlClientTests: XCTestCase {

  private func encodeResponse(corrID: UInt32?, ok: Bool?, result: String?) -> Data {
    var fields: [(MessagePack.Value, MessagePack.Value)] = [
      (.string("type"), .string("response")),
    ]
    if let corrID { fields.append((.string("corr_id"), .uint(UInt64(corrID)))) }
    if let ok { fields.append((.string("ok"), .bool(ok))) }
    if let result { fields.append((.string("result"), .string(result))) }
    return MessagePack.encode(.map(fields))
  }

  // MARK: - happy path

  func test_classifyFrame_resolvesWellFormedResponse() {
    let bytes = encodeResponse(corrID: 7, ok: true, result: "Program added successfully")
    let out = PieControlClient.classifyFrame(data: bytes)
    XCTAssertEqual(out, .resolved(corrID: 7,
                                  response: .init(ok: true, result: "Program added successfully")))
  }

  func test_classifyFrame_resolvesOkFalseWithError() {
    let bytes = encodeResponse(corrID: 9, ok: false, result: "Invalid manifest")
    let out = PieControlClient.classifyFrame(data: bytes)
    XCTAssertEqual(out, .resolved(corrID: 9, response: .init(ok: false, result: "Invalid manifest")))
  }

  // MARK: - non-response frames pass through (listener stays alive)

  func test_classifyFrame_dropsProcessEventSilently() {
    let bytes = MessagePack.encode(.map([
      (.string("type"), .string("process_event")),
      (.string("process_id"), .string("uuid")),
      (.string("event"), .string("stdout")),
      (.string("value"), .string("hello")),
    ]))
    XCTAssertEqual(PieControlClient.classifyFrame(data: bytes), .nonResponse)
  }

  // MARK: - fatal violations (no parseable corr_id)

  func test_classifyFrame_failsAllOnDecodeError() {
    // Truncated str16 header — msgpack decoder throws.
    let bytes = Data([0xda, 0x00, 0x10, 0x61])
    guard case let .fatalProtocolViolation(detail) = PieControlClient.classifyFrame(data: bytes) else {
      XCTFail("expected fatalProtocolViolation"); return
    }
    XCTAssertTrue(detail.contains("decode failed"), "detail should name decode failure: \(detail)")
  }

  func test_classifyFrame_failsAllOnMissingType() {
    let bytes = MessagePack.encode(.map([
      (.string("corr_id"), .uint(1)),
      (.string("ok"), .bool(true)),
      (.string("result"), .string("x")),
    ]))
    guard case let .fatalProtocolViolation(detail) = PieControlClient.classifyFrame(data: bytes) else {
      XCTFail("expected fatalProtocolViolation"); return
    }
    XCTAssertTrue(detail.contains("missing 'type'"), detail)
  }

  func test_classifyFrame_failsAllOnResponseMissingCorrID() {
    let bytes = encodeResponse(corrID: nil, ok: true, result: "x")
    guard case let .fatalProtocolViolation(detail) = PieControlClient.classifyFrame(data: bytes) else {
      XCTFail("expected fatalProtocolViolation"); return
    }
    XCTAssertTrue(detail.contains("missing corr_id"), detail)
  }

  // MARK: - scoped violations (one waiter, listener survives)

  func test_classifyFrame_scopedFailWhenOkMissing() {
    let bytes = encodeResponse(corrID: 11, ok: nil, result: "x")
    XCTAssertEqual(PieControlClient.classifyFrame(data: bytes),
                   .scopedProtocolViolation(corrID: 11, detail: "response missing 'ok' field"))
  }

  // MARK: - result default

  func test_classifyFrame_treatsMissingResultAsEmptyString() {
    // pie ServerResponse.result is `String`, not `Option<String>`,
    // so this case is defensive — but the classifier shouldn't drop
    // an otherwise valid response just because `result` is absent.
    let bytes = encodeResponse(corrID: 13, ok: true, result: nil)
    XCTAssertEqual(PieControlClient.classifyFrame(data: bytes),
                   .resolved(corrID: 13, response: .init(ok: true, result: "")))
  }

  // MARK: - request framing

  func test_queryRequestFrame_matchesPieModelStatusWireShape() throws {
    let bytes = PieControlClient.encodeRequestFrame(
      type: "query",
      corrID: 42,
      extra: [
        ("subject", .string("model_status")),
        ("record", .string("")),
      ]
    )

    let decoded = try MessagePack.decode(bytes)
    XCTAssertEqual(decoded.field("type")?.asString, "query")
    XCTAssertEqual(decoded.field("corr_id")?.asUInt, 42)
    XCTAssertEqual(decoded.field("subject")?.asString, "model_status")
    XCTAssertEqual(decoded.field("record")?.asString, "")
  }
}
