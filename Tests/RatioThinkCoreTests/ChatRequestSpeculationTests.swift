import XCTest
@testable import RatioThinkCore

/// Wire-shape tests for the chat-apc `speculation` extension (#418
/// transport, #426 app injection). The field is nested under
/// `speculation` (NOT flattened like sampling), `nil` knobs are omitted,
/// and the whole object is absent unless the request carries one — so a
/// normal "Chat" request stays byte-identical to pre-speculation.
final class ChatRequestSpeculationTests: XCTestCase {
  private func encodedKeys(_ req: ChatRequest) throws -> [String: Any] {
    let data = try JSONEncoder().encode(req)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  func test_encode_omits_speculation_when_nil() throws {
    let req = ChatRequest(model: "m", messages: [ChatMessage(role: .user, content: "hi")])
    XCTAssertNil(try encodedKeys(req)["speculation"],
                 "absent speculation must not add a key (byte-identical normal chat)")
  }

  func test_encode_nests_speculation_enabled_only() throws {
    let req = ChatRequest(model: "m", messages: [],
                          speculation: ChatSpeculation(enabled: true))
    let spec = try XCTUnwrap(try encodedKeys(req)["speculation"] as? [String: Any])
    XCTAssertEqual(spec["enabled"] as? Bool, true)
    XCTAssertNil(spec["leader_len"], "nil knob must be omitted")
    XCTAssertNil(spec["draft_len"], "nil knob must be omitted")
  }

  func test_encode_includes_knobs_when_set() throws {
    let req = ChatRequest(model: "m", messages: [],
                          speculation: ChatSpeculation(enabled: true, leaderLen: 2, draftLen: 5))
    let spec = try XCTUnwrap(try encodedKeys(req)["speculation"] as? [String: Any])
    XCTAssertEqual(spec["leader_len"] as? Int, 2)
    XCTAssertEqual(spec["draft_len"] as? Int, 5)
  }

  func test_encode_includes_sidecar_identity_when_set() throws {
    let req = ChatRequest(
      model: "m",
      messages: [],
      speculation: ChatSpeculation(
        enabled: true,
        leaderLen: 2,
        draftLen: 5,
        threadID: "chat-123",
        profileID: "fast-think"))
    let spec = try XCTUnwrap(try encodedKeys(req)["speculation"] as? [String: Any])
    XCTAssertEqual(spec["thread_id"] as? String, "chat-123")
    XCTAssertEqual(spec["profile_id"] as? String, "fast-think")
  }

  func test_round_trips_speculation() throws {
    let req = ChatRequest(model: "m", messages: [],
                          speculation: ChatSpeculation(
                            enabled: true,
                            leaderLen: 1,
                            draftLen: 3,
                            threadID: "chat-123",
                            profileID: "fast-think"))
    let back = try JSONDecoder().decode(ChatRequest.self, from: try JSONEncoder().encode(req))
    XCTAssertEqual(back.speculation, ChatSpeculation(
      enabled: true,
      leaderLen: 1,
      draftLen: 3,
      threadID: "chat-123",
      profileID: "fast-think"))
  }

  func test_round_trips_absent_speculation_as_nil() throws {
    let req = ChatRequest(model: "m", messages: [ChatMessage(role: .user, content: "hi")])
    let back = try JSONDecoder().decode(ChatRequest.self, from: try JSONEncoder().encode(req))
    XCTAssertNil(back.speculation)
  }
}
