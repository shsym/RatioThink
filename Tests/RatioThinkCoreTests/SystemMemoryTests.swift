import XCTest
@testable import RatioThinkCore

/// Unit tests for `SystemMemory.physicalBytes`. The reader is
/// injectable so the unknown-RAM fallback is covered without depending
/// on the test host's actual memory.
final class SystemMemoryTests: XCTestCase {

  func test_default_reader_returns_positive_on_real_host() {
    let bytes = SystemMemory.physicalBytes()
    XCTAssertNotNil(bytes, "a real macOS host always reports hw.memsize")
    XCTAssertGreaterThan(bytes ?? 0, 0)
  }

  func test_injected_value_is_returned_as_int64() {
    let sixtyFour: Int64 = 64 * 1024 * 1024 * 1024
    let bytes = SystemMemory.physicalBytes(reader: { UInt64(sixtyFour) })
    XCTAssertEqual(bytes, sixtyFour)
  }

  func test_zero_is_treated_as_unknown() {
    XCTAssertNil(SystemMemory.physicalBytes(reader: { 0 }))
  }

  func test_nil_reader_is_unknown() {
    XCTAssertNil(SystemMemory.physicalBytes(reader: { nil }))
  }

  func test_value_exceeding_int64_is_unknown() {
    XCTAssertNil(SystemMemory.physicalBytes(reader: { UInt64.max }))
  }
}
