import XCTest
@testable import RatioThinkCore

/// Wire-contract coverage for `DegradedHelperAPI` (review v2 F5). Each
/// selector's reply payload must decode to the type the protocol
/// declares; the prior `listProfiles` catch path emitted EngineError
/// bytes into a `[String]` slot, which the GUI would have seen as
/// `DecodingError` indistinguishable from wire corruption.
final class DegradedHelperAPITests: XCTestCase {

  private func makeAPI() -> DegradedHelperAPI {
    DegradedHelperAPI(reasonMessage: "test: state dir unavailable")
  }

  // MARK: - listProfiles decodes as [String] (review v2 F5)

  func test_degraded_listProfiles_decodes_as_string_array() {
    let api = makeAPI()
    let expectation = XCTestExpectation(description: "listProfiles reply")
    var captured: Data?
    api.listProfiles { data in
      captured = data
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 1.0)
    let data = try? XCTUnwrap(captured)
    XCTAssertNotNil(data)
    guard let data else { return }
    XCTAssertNoThrow(try XPCPayload.decode([String].self, from: data),
                     "listProfiles reply must decode as [String], not EngineError-shaped fallback bytes")
    if let decoded = try? XPCPayload.decode([String].self, from: data) {
      XCTAssertEqual(decoded, [], "degraded helper has no profiles to enumerate")
    }
  }

  // MARK: - engineStatus carries .failed(.degraded, reason)

  func test_degraded_engineStatus_carries_degraded_failure() {
    let api = makeAPI()
    let expectation = XCTestExpectation(description: "engineStatus reply")
    api.engineStatus { data in
      do {
        let status = try XPCPayload.decode(EngineStatus.self, from: data)
        switch status {
        case let .failed(code, message):
          XCTAssertEqual(code, .degraded)
          XCTAssertTrue(message.contains("state dir unavailable"))
        default:
          XCTFail("expected .failed(.degraded, …), got \(status)")
        }
      } catch {
        XCTFail("engineStatus decode failed: \(error)")
      }
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 1.0)
  }

  // MARK: - error-carrying selectors carry EngineError(.degraded)

  func test_degraded_startEngine_returns_degraded_error() {
    let api = makeAPI()
    let expectation = XCTestExpectation(description: "startEngine reply")
    api.startEngine(profileID: "p", modelOverride: nil) { successData, errorData in
      XCTAssertNil(successData)
      let result = try? PieHelperXPCWire.decodeStartEngineReply(
        successData: successData, errorData: errorData
      )
      switch result {
      case .failure(let err)?:
        XCTAssertEqual(err.code, .degraded)
      default:
        XCTFail("expected .failure(.degraded), got \(String(describing: result))")
      }
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 1.0)
  }

  func test_degraded_stopEngine_returns_degraded_error() {
    let api = makeAPI()
    let expectation = XCTestExpectation(description: "stopEngine reply")
    api.stopEngine { errorData in
      let err = try? PieHelperXPCWire.decodeOptionalError(errorData)
      XCTAssertEqual(err?.code, .degraded)
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 1.0)
  }

  func test_degraded_downloadModel_returns_degraded_error() {
    let api = makeAPI()
    let expectation = XCTestExpectation(description: "downloadModel reply")
    api.downloadModel(repo: "r", file: "f") { successData, errorData in
      XCTAssertNil(successData)
      let result = try? PieHelperXPCWire.decodeDownloadModelReply(
        successData: successData, errorData: errorData
      )
      if case .failure(let err)? = result {
        XCTAssertEqual(err.code, .degraded)
      } else {
        XCTFail("expected .failure(.degraded), got \(String(describing: result))")
      }
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 1.0)
  }


  func test_degraded_cancelDownload_returns_degraded_error() {
    let api = makeAPI()
    let expectation = XCTestExpectation(description: "cancelDownload reply")
    let handleData = (try? XPCPayload.encode(DownloadHandle(repo: "r", file: "f"))) ?? Data()
    api.cancelDownload(handle: handleData) { errorData in
      let err = try? PieHelperXPCWire.decodeOptionalError(errorData)
      XCTAssertEqual(err?.code, .degraded)
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 1.0)
  }

  func test_degraded_reloadProfiles_returns_degraded_error() {
    let api = makeAPI()
    let expectation = XCTestExpectation(description: "reloadProfiles reply")
    api.reloadProfiles { errorData in
      let err = try? PieHelperXPCWire.decodeOptionalError(errorData)
      XCTAssertEqual(err?.code, .degraded)
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 1.0)
  }

  func test_degraded_tailLog_returns_degraded_error() {
    let api = makeAPI()
    let expectation = XCTestExpectation(description: "tailLog reply")
    api.tailLog(stream: "helper") { handle, errorData in
      XCTAssertNil(handle)
      let result = try? PieHelperXPCWire.decodeTailLogReply(
        handle: handle, errorData: errorData
      )
      if case .failure(let err)? = result {
        XCTAssertEqual(err.code, .degraded)
      } else {
        XCTFail("expected .failure(.degraded), got \(String(describing: result))")
      }
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 1.0)
  }

  // MARK: - engineMemory replies the shared pre-encoded nil blob (#348)

  /// The degraded path must reply bytes byte-equal to the shared
  /// `PieHelperXPCWire.emptyMemoryData` blob — not a hand-written "null"
  /// literal coupled to the JSON wire format. A decode-to-nil assertion can't
  /// catch a wire-format desync (a real encode and the literal both decode to
  /// nil today); byte-equality can, and ties the degraded reply to the single
  /// precondition-guarded source of truth.
  func test_degraded_engineMemory_is_shared_empty_blob() {
    let api = makeAPI()
    let expectation = XCTestExpectation(description: "engineMemory reply")
    var captured: Data?
    api.engineMemory { data in
      captured = data
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 1.0)
    XCTAssertEqual(captured, PieHelperXPCWire.emptyMemoryData,
                   "degraded engineMemory must reply the shared pre-encoded nil blob, byte-for-byte")
  }
}
