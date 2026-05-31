import XCTest
@testable import RatioThink

/// Deterministic coverage for the status popover's on-demand engine
/// `Memory` row. The row is fed by an async `.task` poll that a
/// pixel snapshot can't pump reliably, so the gating is asserted here as
/// a pure function and the readout string via the wire type's formatter.
///
/// Contract:
///   · The row shows ONLY in the steady/loading branch (never over a
///     `.failed` / `.engineNotReady` block) AND while the engine is
///     running/ready.
///   · The caller additionally requires a non-nil sample — a nil sample
///     (engine answered "unavailable", or hasn't answered yet) hides the
///     row. That nil-gate is the `if let memory` at the call site; here we
///     pin the state-level gate plus the rendered readout.
final class ModelLoadPopoverMemoryRowTests: XCTestCase {

  // MARK: - state gate

  func test_row_shows_when_running_and_steady() {
    XCTAssertTrue(ModelLoadPopover.showsMemoryRow(centerState: .idle, engineRunningOrReady: true))
    XCTAssertTrue(ModelLoadPopover.showsMemoryRow(
      centerState: .ready(modelID: "qwen3-0.6b"), engineRunningOrReady: true))
    XCTAssertTrue(ModelLoadPopover.showsMemoryRow(
      centerState: .loading(modelID: "qwen3-0.6b", loadedBytes: 1, totalBytes: 2, etaSeconds: nil),
      engineRunningOrReady: true))
  }

  func test_row_hidden_when_engine_not_running() {
    XCTAssertFalse(ModelLoadPopover.showsMemoryRow(centerState: .idle, engineRunningOrReady: false))
    XCTAssertFalse(ModelLoadPopover.showsMemoryRow(
      centerState: .ready(modelID: "qwen3-0.6b"), engineRunningOrReady: false))
  }

  func test_row_hidden_over_failure_and_engine_not_ready_blocks() {
    // Even with the engine "running", the failed / engineNotReady popover
    // renders its own block (no bytes/eta/memory rows), so the memory row
    // must stay suppressed there.
    XCTAssertFalse(ModelLoadPopover.showsMemoryRow(
      centerState: .failed(modelID: "qwen3-0.6b", message: "boom"), engineRunningOrReady: true))
    XCTAssertFalse(ModelLoadPopover.showsMemoryRow(
      centerState: .engineNotReady(modelID: "qwen3-0.6b", detail: "Engine stopped"),
      engineRunningOrReady: true))
  }

  // MARK: - rendered readout

  // The row text is the sample's `formattedResident`. Pin the canonical
  // GB rendering the brief calls out so a formatter regression is caught
  // at the App tier too (the wire-type's own formatter test lives in
  // RatioThinkCoreTests).
  func test_sample_formats_as_gb() {
    XCTAssertEqual(EngineMemorySample(residentBytes: 1_932_735_283).formattedResident, "1.80 GB")
  }

  func test_sample_formats_as_mb() {
    XCTAssertEqual(EngineMemorySample(residentBytes: 268_435_456).formattedResident, "256 MB")
  }
}
