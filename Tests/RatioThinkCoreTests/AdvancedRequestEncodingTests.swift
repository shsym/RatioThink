import XCTest

@testable import RatioThinkCore

/// The advanced-profile dispatch bodies must actually put on the wire every
/// property they declare.
///
/// This exists because they did not. `ToTRequestInput` and `BestOfNRequestInput`
/// each declared `let boundary: ChatCacheDirective?` and each populated it at
/// its call site — but their explicit `CodingKeys` enums omitted `boundary`.
/// Declaring `CodingKeys` suppresses synthesis for anything absent, so Swift
/// silently encoded a body with no `boundary` key. It compiled, it type-checked,
/// and the property was read nowhere else, so nothing failed: ToT and Best-of-N
/// dispatches simply carried no conversation identity, and cross-mode KV reuse
/// could never hit.
///
/// A type-level test cannot catch this — the bug IS the type-level agreement
/// being bypassed. Only encoding and reading the JSON back does.
@available(macOS 14, *)
final class AdvancedRequestEncodingTests: XCTestCase {

  private func encodedKeys<T: Encodable>(_ value: T) throws -> [String: Any] {
    let data = try JSONEncoder().encode(value)
    let obj = try JSONSerialization.jsonObject(with: data)
    return try XCTUnwrap(obj as? [String: Any], "body must encode to a JSON object")
  }

  private var directive: ChatCacheDirective {
    ChatCacheDirective(key: "0F1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9", turn: 4)
  }

  func testToTRequestCarriesTheBoundaryDirective() throws {
    let json = try encodedKeys(
      ToTRequestInput(
        model: "qwen",
        boundary: directive,
        messages: [ChatMessage(role: .user, content: "hi")],
        breadth: 2,
        depth: 1,
        beamWidth: 1,
        maxTokensPerNode: 256,
        temperature: 0.7,
        topP: 1.0
      )
    )
    let boundary = try XCTUnwrap(
      json["boundary"] as? [String: Any],
      "ToT dispatch dropped `boundary`; chat -> ToT -> chat cannot reuse KV without it"
    )
    XCTAssertEqual(boundary["key"] as? String, directive.key)
    XCTAssertEqual(boundary["turn"] as? Int, 4)
    XCTAssertEqual(boundary["compat"] as? String, ChatCacheDirective.compatVersion)

    // The snake_case remapping must survive alongside it — adding a case to
    // CodingKeys is exactly the edit that could disturb the others.
    XCTAssertNotNil(json["beam_width"], "beam_width missing")
    XCTAssertNotNil(json["max_tokens_per_node"], "max_tokens_per_node missing")
    XCTAssertNotNil(json["top_p"], "top_p missing")
  }

  func testBestOfNRequestCarriesTheBoundaryDirective() throws {
    let json = try encodedKeys(
      BestOfNRequestInput(
        model: "qwen",
        boundary: directive,
        roundID: "ROUND-1",
        messages: [ChatMessage(role: .user, content: "hi")],
        n: 3,
        maxTokensPerCandidate: 256,
        thinking: false,
        temperature: 0.7,
        topP: 1.0,
        resumeFrom: nil,
        pickedText: nil,
        selectedComment: nil,
        unpicked: nil,
        level: nil
      )
    )
    let boundary = try XCTUnwrap(
      json["boundary"] as? [String: Any],
      "Best-of-N dispatch dropped `boundary`; the milestone-C commit needs it"
    )
    XCTAssertEqual(boundary["key"] as? String, directive.key)
    XCTAssertNotNil(json["max_tokens_per_candidate"], "max_tokens_per_candidate missing")
    XCTAssertNotNil(json["top_p"], "top_p missing")
    // The authorization scope. Without it the guest refuses to mint snapshots,
    // so a round that omits it cannot be resumed, released or committed.
    XCTAssertEqual(json["round_id"] as? String, "ROUND-1")
  }

  /// Round 1 leaves the resume fields nil and the server reads their absence as
  /// "fresh round" — so `boundary` being present must not drag them in.
  func testAbsentResumeFieldsStayAbsent() throws {
    let json = try encodedKeys(
      BestOfNRequestInput(
        model: "qwen",
        boundary: directive,
        roundID: "ROUND-1",
        messages: [],
        n: 3,
        maxTokensPerCandidate: 256,
        thinking: false,
        temperature: 0.7,
        topP: 1.0,
        resumeFrom: nil,
        pickedText: nil,
        selectedComment: nil,
        unpicked: nil,
        level: nil
      )
    )
    for absent in ["resume_from", "picked_text", "selected_comment", "unpicked", "level"] {
      XCTAssertNil(json[absent], "\(absent) must be omitted on a fresh round")
    }
  }

  /// A nil directive must omit the key rather than encode `null`: gen-core's
  /// `BoundaryDirective` defaults to reuse-enabled, and an explicit null would
  /// have to be tolerated by the decoder.
  func testNilBoundaryIsOmittedNotNull() throws {
    let json = try encodedKeys(
      ToTRequestInput(
        model: "qwen",
        boundary: nil,
        messages: [],
        breadth: 2,
        depth: 1,
        beamWidth: 1,
        maxTokensPerNode: 256,
        temperature: 0.7,
        topP: 1.0
      )
    )
    XCTAssertNil(json["boundary"], "a nil directive must be omitted, not encoded as null")
  }
}
