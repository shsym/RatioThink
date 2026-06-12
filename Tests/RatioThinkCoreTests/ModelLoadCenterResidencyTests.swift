import XCTest
@testable import RatioThinkCore

/// #469: `ModelLoadCenter` is now a pure RESIDENCY tracker — the in-flight
/// model-LOAD half (progress / Cancel / Retry, driven by the removed
/// `/v1/models/load` endpoint) is gone. These cover what remains: which model
/// the engine serves, reconciled from `GET /v1/models` and invalidated on the
/// leave-`.running` edge.
@MainActor
final class ModelLoadCenterResidencyTests: XCTestCase {

  func test_initialResident_seedsResidentModelID() {
    XCTAssertNil(ModelLoadCenter().residentModelID)
    XCTAssertEqual(ModelLoadCenter(initialResident: "m1").residentModelID, "m1")
  }

  func test_reconcileEngineResident_records_and_isIdempotent() {
    let center = ModelLoadCenter()
    center.reconcileEngineResident("m1")
    XCTAssertEqual(center.residentModelID, "m1")
    center.reconcileEngineResident("m1")  // no-op
    XCTAssertEqual(center.residentModelID, "m1")
    center.reconcileEngineResident("m2")  // switch
    XCTAssertEqual(center.residentModelID, "m2")
  }

  func test_engineLeftRunning_clearsResidency() {
    let center = ModelLoadCenter(initialResident: "m1")
    center.engineLeftRunning()
    XCTAssertNil(center.residentModelID)
    center.engineLeftRunning()  // idempotent
    XCTAssertNil(center.residentModelID)
  }

  func test_engineServesNoModel_clearsResidency() {
    let center = ModelLoadCenter(initialResident: "m1")
    center.engineServesNoModel()
    XCTAssertNil(center.residentModelID)
  }

  func test_markUnloaded_clearsResidency() {
    let center = ModelLoadCenter(initialResident: "m1")
    center.markUnloaded()
    XCTAssertNil(center.residentModelID)
    center.markUnloaded()  // idempotent when already idle
    XCTAssertNil(center.residentModelID)
  }
}
