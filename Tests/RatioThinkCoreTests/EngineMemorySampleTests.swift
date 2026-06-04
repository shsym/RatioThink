import XCTest
@testable import RatioThinkCore

/// Wire + formatting coverage for `EngineMemorySample` — the optional
/// engine-RSS readout carried by the `engineMemory` XPC selector.
final class EngineMemorySampleTests: XCTestCase {
  func test_roundtrips_through_xpc_payload() throws {
    let sample = EngineMemorySample(
      residentBytes: 1_932_735_283,
      sampledAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let data = try XPCPayload.encode(sample)
    XCTAssertEqual(try XPCPayload.decode(EngineMemorySample.self, from: data), sample)
  }

  func test_optional_none_encodes_and_decodes_as_unavailable() throws {
    let none: EngineMemorySample? = nil
    let data = try XPCPayload.encode(none)
    XCTAssertNil(try XPCPayload.decode(EngineMemorySample?.self, from: data))
  }

  func test_formatted_gb_and_mb() {
    XCTAssertEqual(
      EngineMemorySample(residentBytes: 1_932_735_283).formattedResident,
      "1.80 GB"
    )
    XCTAssertEqual(
      EngineMemorySample(residentBytes: 268_435_456).formattedResident,
      "256 MB"
    )
  }

  /// `from` is the construction chokepoint that keeps the wire-type's
  /// "sample failure ⇒ nil" contract. 0 is never a renderable sample (a
  /// live engine is never 0-resident — 0 only appears on the dead/reaped
  /// path), so it must collapse to nil rather than build a "0 MB" sample;
  /// any positive reading builds normally.
  func test_from_rejects_zero_as_unavailable() {
    XCTAssertNil(EngineMemorySample.from(residentBytes: 0),
                 "0 bytes must collapse to nil, never EngineMemorySample(residentBytes: 0)")
    XCTAssertEqual(EngineMemorySample.from(residentBytes: 1)?.residentBytes, 1,
                   "any positive reading builds a sample")
    XCTAssertEqual(EngineMemorySample.from(residentBytes: 268_435_456)?.formattedResident, "256 MB")
  }
}
