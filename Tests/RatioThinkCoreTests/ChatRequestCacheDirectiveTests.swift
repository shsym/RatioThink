import XCTest
@testable import RatioThinkCore

/// Wire-shape tests for the #522 cross-request prefix-cache `cache`
/// directive. Nested under `cache` (like `speculation`, not flattened),
/// absent ⇒ no key on the wire (byte-identical to a pre-#522 request), and
/// round-trips through the App's custom `Codable`.
final class ChatRequestCacheDirectiveTests: XCTestCase {
  private func encodedKeys(_ req: ChatRequest) throws -> [String: Any] {
    let data = try JSONEncoder().encode(req)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  func test_encode_omits_cache_when_nil() throws {
    let req = ChatRequest(model: "m", messages: [ChatMessage(role: .user, content: "hi")])
    XCTAssertNil(try encodedKeys(req)["cache"],
                 "absent cache directive must not add a key (byte-identical legacy request)")
  }

  func test_encode_nests_cache_fields() throws {
    let req = ChatRequest(model: "m", messages: [],
                          cache: ChatCacheDirective(key: "chat-abc", turn: 4))
    let cache = try XCTUnwrap(try encodedKeys(req)["cache"] as? [String: Any])
    XCTAssertEqual(cache["key"] as? String, "chat-abc")
    XCTAssertEqual(cache["turn"] as? Int, 4)
    XCTAssertEqual(cache["compat"] as? String, ChatCacheDirective.compatVersion)
    XCTAssertEqual(cache["policy"] as? String, "auto",
                   "default policy is auto so the inferlet engages reuse")
  }

  func test_bypass_policy_rides_explicitly() throws {
    let req = ChatRequest(model: "m", messages: [],
                          cache: ChatCacheDirective(key: "c", turn: 0, policy: "bypass"))
    let cache = try XCTUnwrap(try encodedKeys(req)["cache"] as? [String: Any])
    XCTAssertEqual(cache["policy"] as? String, "bypass")
  }

  func test_retention_budget_rides_authoritative_kv_usage() throws {
    let req = ChatRequest(
      model: "m",
      messages: [],
      cache: ChatCacheDirective(
        key: "c",
        turn: 0,
        retention: ChatCacheRetentionDirective(
          kvPagesUsed: 90,
          kvPagesTotal: 100,
          softPercent: 70,
          evictPercent: 80,
          hardPercent: 95
        )
      )
    )

    let cache = try XCTUnwrap(try encodedKeys(req)["cache"] as? [String: Any])
    let retention = try XCTUnwrap(cache["retention"] as? [String: Any])
    XCTAssertEqual(retention["kv_pages_used"] as? Int, 90)
    XCTAssertEqual(retention["kv_pages_total"] as? Int, 100)
    XCTAssertEqual(retention["soft_percent"] as? Int, 70)
    XCTAssertEqual(retention["evict_percent"] as? Int, 80)
    XCTAssertEqual(retention["hard_percent"] as? Int, 95)
  }

  func test_round_trips_cache() throws {
    let req = ChatRequest(model: "m", messages: [],
                          cache: ChatCacheDirective(key: "c", turn: 7, compat: "1", policy: "auto"))
    let back = try JSONDecoder().decode(ChatRequest.self, from: try JSONEncoder().encode(req))
    XCTAssertEqual(back.cache, ChatCacheDirective(key: "c", turn: 7, compat: "1", policy: "auto"))
  }

  func test_round_trips_absent_cache_as_nil() throws {
    let req = ChatRequest(model: "m", messages: [ChatMessage(role: .user, content: "hi")])
    let back = try JSONDecoder().decode(ChatRequest.self, from: try JSONEncoder().encode(req))
    XCTAssertNil(back.cache)
  }
}
