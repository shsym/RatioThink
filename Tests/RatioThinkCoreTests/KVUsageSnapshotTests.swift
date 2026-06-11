import XCTest
@testable import RatioThinkCore

final class KVUsageSnapshotTests: XCTestCase {
  func test_parseModelStatus_decodesKVRowsAndIgnoresInferenceCounters() throws {
    let json = #"{"default.kv_pages_used":3,"default.kv_pages_total":256,"default.total_batches":9}"#
    let snapshots = try KVUsageModelStatusParser.parse(
      json,
      observedAt: Date(timeIntervalSince1970: 10),
      generation: 7
    )
    XCTAssertEqual(snapshots, [
      KVUsageSnapshot(
        modelID: "default",
        pagesUsed: 3,
        pagesTotal: 256,
        observedAt: Date(timeIntervalSince1970: 10),
        generation: 7,
        source: .pieModelStatus
      )
    ])
  }

  func test_parseModelStatus_handlesModelIDsContainingDotsBySuffixMatching() throws {
    let json = #"{"org.model.v1.kv_pages_used":11,"org.model.v1.kv_pages_total":1024}"#
    let snapshots = try KVUsageModelStatusParser.parse(
      json,
      observedAt: Date(timeIntervalSince1970: 20),
      generation: 2
    )
    XCTAssertEqual(snapshots.map(\.modelID), ["org.model.v1"])
    XCTAssertEqual(snapshots.first?.pagesUsed, 11)
    XCTAssertEqual(snapshots.first?.pagesTotal, 1024)
  }

  func test_parseModelStatus_sortsSnapshotsByModelID() throws {
    let json = #"{"zeta.kv_pages_used":9,"zeta.kv_pages_total":90,"alpha.kv_pages_used":1,"alpha.kv_pages_total":10}"#
    let snapshots = try KVUsageModelStatusParser.parse(
      json,
      observedAt: Date(timeIntervalSince1970: 25),
      generation: 3
    )
    XCTAssertEqual(snapshots.map(\.modelID), ["alpha", "zeta"])
  }

  func test_parseModelStatus_missingTotalDoesNotFabricateZero() throws {
    let json = #"{"default.kv_pages_used":5}"#
    let snapshots = try KVUsageModelStatusParser.parse(
      json,
      observedAt: Date(timeIntervalSince1970: 30),
      generation: 1
    )
    XCTAssertTrue(snapshots.isEmpty, "incomplete rows must be omitted, not decoded as total=0")
  }

  func test_parseModelStatus_missingUsedDoesNotFabricateZero() throws {
    let json = #"{"default.kv_pages_total":256}"#
    let snapshots = try KVUsageModelStatusParser.parse(
      json,
      observedAt: Date(timeIntervalSince1970: 31),
      generation: 1
    )
    XCTAssertTrue(snapshots.isEmpty, "incomplete rows must be omitted, not decoded as used=0")
  }

  func test_parseModelStatus_rejectsNegativeAndWrongTypeValues() {
    XCTAssertThrowsError(try KVUsageModelStatusParser.parse(
      #"{"default.kv_pages_used":-1,"default.kv_pages_total":256}"#,
      observedAt: Date(),
      generation: 1
    ))
    XCTAssertThrowsError(try KVUsageModelStatusParser.parse(
      #"{"default.kv_pages_used":"1","default.kv_pages_total":256}"#,
      observedAt: Date(),
      generation: 1
    ))
    XCTAssertThrowsError(try KVUsageModelStatusParser.parse(
      #"{"default.kv_pages_used":1.0,"default.kv_pages_total":256}"#,
      observedAt: Date(),
      generation: 1
    ))
    XCTAssertThrowsError(try KVUsageModelStatusParser.parse(
      #"{"default.kv_pages_used":1e0,"default.kv_pages_total":256}"#,
      observedAt: Date(),
      generation: 1
    ))
  }

  func test_parseModelStatus_rejectsNonJSONObject() {
    XCTAssertThrowsError(try KVUsageModelStatusParser.parse(
      #"["not", "an", "object"]"#,
      observedAt: Date(),
      generation: 1
    ))
  }
}
