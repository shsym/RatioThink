import XCTest
@testable import RatioThinkCore

final class EngineRequestSyncTests: XCTestCase {
  func test_synchronized_when_resident_model_matches_desired_target() {
    let sync = EngineRequestSync(
      target: ModelTarget(modelID: "selected", source: .selected),
      resident: EngineResidentState(modelID: "selected", maxOutputTokensCeiling: 768)
    )

    XCTAssertEqual(sync.resolvedModelID, "selected")
    XCTAssertEqual(sync.maxOutputTokensCeiling, 768)
  }

  func test_unsynchronized_when_resident_model_differs_from_desired_target() {
    let sync = EngineRequestSync(
      target: ModelTarget(modelID: "selected", source: .selected),
      resident: EngineResidentState(modelID: "profile-default", maxOutputTokensCeiling: 768)
    )

    XCTAssertNil(sync.resolvedModelID)
    XCTAssertNil(sync.maxOutputTokensCeiling,
                 "engine-bound ceilings must not be reused when they belong to a different resident model")
  }
}
