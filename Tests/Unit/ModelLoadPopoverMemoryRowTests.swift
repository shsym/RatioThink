import XCTest
@testable import RatioThink

/// Coverage for the status popover's on-demand engine `Memory` row readout.
/// #469: the memory row's state gate is now a simple inline `if let memory,
/// isEngineRunning` at the call site (the engine `.running` fold is the only
/// branch that renders it), so there is no longer a pure `showsMemoryRow` seam
/// to test. The readout string is the wire type's formatter, pinned here so a
/// formatter regression is caught at the App tier too.
final class ModelLoadPopoverMemoryRowTests: XCTestCase {

  func test_sample_formats_as_gb() {
    XCTAssertEqual(EngineMemorySample(residentBytes: 1_932_735_283).formattedResident, "1.80 GB")
  }

  func test_sample_formats_as_mb() {
    XCTAssertEqual(EngineMemorySample(residentBytes: 268_435_456).formattedResident, "256 MB")
  }
}
