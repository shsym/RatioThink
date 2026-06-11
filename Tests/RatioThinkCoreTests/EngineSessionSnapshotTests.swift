import XCTest
@testable import RatioThinkCore

/// #476 — the standardized App↔Helper engine-session snapshot. Pins the
/// wire round-trip and the byte stability the contract depends on (insight
/// 183: assert byte-equality to the canonical blob, not just decode-to-equal,
/// so a silent wire-format drift is caught).
final class EngineSessionSnapshotTests: XCTestCase {

  private func sample() -> EngineSessionSnapshot {
    EngineSessionSnapshot(
      generation: 7,
      port: 51234,
      profileID: "chat",
      servedModelID: "Qwen/Qwen3-0.6B/Qwen3-0.6B-Q8_0.gguf",
      maxOutputTokens: 8000)
  }

  func test_roundtrip_preserves_every_field() throws {
    let original = sample()
    let data = try XPCPayload.encode(original)
    let decoded = try XPCPayload.decode(EngineSessionSnapshot.self, from: data)
    XCTAssertEqual(decoded, original)
    XCTAssertEqual(decoded.generation, 7)
    XCTAssertEqual(decoded.port, 51234)
    XCTAssertEqual(decoded.profileID, "chat")
    XCTAssertEqual(decoded.servedModelID, "Qwen/Qwen3-0.6B/Qwen3-0.6B-Q8_0.gguf")
    XCTAssertEqual(decoded.maxOutputTokens, 8000)
  }

  func test_wire_bytes_are_stable_sorted_keys() throws {
    // Assert the EXACT canonical bytes, not decode-to-equal: a `nil`/Optional
    // or a reordered key would still decode equal yet silently change the wire
    // format. `.sortedKeys` (XPCPayloadConfig) makes this deterministic.
    let data = try XPCPayload.encode(sample())
    let expected = Data(
      #"{"generation":7,"maxOutputTokens":8000,"port":51234,"profileID":"chat","servedModelID":"Qwen\/Qwen3-0.6B\/Qwen3-0.6B-Q8_0.gguf"}"#.utf8)
    XCTAssertEqual(data, expected, "wire format drifted: \(String(decoding: data, as: UTF8.self))")
  }

  func test_convenience_init_fills_minimal_defaults() {
    // The legacy/pin/test construction sites only know (port, profileID).
    let snap = EngineSessionSnapshot(port: 9, profileID: "p")
    XCTAssertEqual(snap.generation, 0)
    XCTAssertEqual(snap.servedModelID, "")
    XCTAssertEqual(snap.maxOutputTokens, KVCacheBudget.defaultPoolCapacityTokens)
    XCTAssertEqual(snap.port, 9)
    XCTAssertEqual(snap.profileID, "p")
  }

  func test_isSameSession_keys_on_generation_not_port() {
    let a = EngineSessionSnapshot(generation: 5, port: 100, profileID: "chat",
                                  servedModelID: "m", maxOutputTokens: 8000)
    // Same generation, different port (impossible in practice, but proves the
    // session id is the generation, not the port).
    let sameGen = EngineSessionSnapshot(generation: 5, port: 999, profileID: "chat",
                                        servedModelID: "m", maxOutputTokens: 8000)
    let nextGen = EngineSessionSnapshot(generation: 6, port: 100, profileID: "chat",
                                        servedModelID: "m", maxOutputTokens: 8000)
    XCTAssertTrue(a.isSameSession(as: sameGen))
    XCTAssertFalse(a.isSameSession(as: nextGen), "a new generation must read as a different session")
  }
}
