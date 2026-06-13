import XCTest
@testable import RatioThinkCore

final class HelperExportedAPIKVUsageTests: XCTestCase {
  final class KVSession: PieEngineHost.EngineSession, @unchecked Sendable {
    let json: String?
    init(json: String?) { self.json = json }
    func shutdown() async -> EngineShutdownResult { .reaped }
    func modelStatusJSON() async throws -> String? { json }
  }

  private func makeSpec() -> PieControlLauncher.LaunchSpec {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    return try! PieControlLauncher.LaunchSpec(
      pieBinary: tmp.appendingPathComponent("ignored-pie"),
      wasmURL: tmp.appendingPathComponent("ignored.wasm"),
      manifestURL: tmp.appendingPathComponent("ignored.toml"),
      subprocessEnvironment: [:],
      pieHome: tmp.appendingPathComponent("home"),
      shmemName: "/pie_test_\(UUID().uuidString.prefix(8))",
      profileID: "chat",
      modelConfig: .dummy
    )
  }

  func test_kvUsage_noHostReturnsEmptySnapshotList() async throws {
    let api = HelperExportedAPI()
    let result = await kvUsage(api)
    XCTAssertEqual(try result.get(), [])
  }

  func test_kvUsage_runningHostReturnsParsedSnapshots() async throws {
    let session = KVSession(json: #"{"default.kv_pages_used":4,"default.kv_pages_total":256}"#)
    let host = PieEngineHost(launcher: { _ in (port: EnginePort(45678), session: session) })
    let running = expectation(description: "running")
    let token = host.observe { status, _ in
      if case .running = status { running.fulfill() }
    }
    _ = host.start(makeSpec())
    await fulfillment(of: [running], timeout: 2)

    let api = HelperExportedAPI(engineHost: host, launchSpecResolver: nil)
    let snapshots = try await kvUsage(api).get()
    XCTAssertEqual(snapshots.first?.modelID, "default")
    XCTAssertEqual(snapshots.first?.pagesUsed, 4)
    XCTAssertEqual(snapshots.first?.pagesTotal, 256)
    token.cancel()
  }

  func test_kvUsage_runningHostMalformedModelStatusReturnsWireContractViolation() async throws {
    let session = KVSession(json: #"{not-json}"#)
    let host = PieEngineHost(launcher: { _ in (port: EnginePort(45678), session: session) })
    let running = expectation(description: "running")
    let token = host.observe { status, _ in
      if case .running = status { running.fulfill() }
    }
    _ = host.start(makeSpec())
    await fulfillment(of: [running], timeout: 2)

    let result = await kvUsage(HelperExportedAPI(engineHost: host, launchSpecResolver: nil))
    guard case .failure(let error) = result else {
      token.cancel()
      return XCTFail("expected failure, got \(result)")
    }

    XCTAssertEqual(error.code, .wireContractViolation)
    XCTAssertNotEqual(error.code, .engineGone)
    XCTAssertTrue(error.message.localizedCaseInsensitiveContains("kv usage"))
    XCTAssertTrue(error.message.localizedCaseInsensitiveContains("model_status"))
    XCTAssertTrue(error.message.localizedCaseInsensitiveContains("decode"))
    token.cancel()
  }

  func test_kvUsage_runningHostInvalidModelStatusCounterReturnsWireContractViolation() async throws {
    let session = KVSession(json: #"{"default.kv_pages_used":-1,"default.kv_pages_total":256}"#)
    let host = PieEngineHost(launcher: { _ in (port: EnginePort(45678), session: session) })
    let running = expectation(description: "running")
    let token = host.observe { status, _ in
      if case .running = status { running.fulfill() }
    }
    _ = host.start(makeSpec())
    await fulfillment(of: [running], timeout: 2)

    let result = await kvUsage(HelperExportedAPI(engineHost: host, launchSpecResolver: nil))
    guard case .failure(let error) = result else {
      token.cancel()
      return XCTFail("expected failure, got \(result)")
    }

    XCTAssertEqual(error.code, .wireContractViolation)
    XCTAssertTrue(error.message.localizedCaseInsensitiveContains("model_status"))
    XCTAssertTrue(error.message.localizedCaseInsensitiveContains("decode"))
    token.cancel()
  }

  func test_kvUsage_runningHostMissingModelStatusReturnsFailureNotEmptySuccess() async throws {
    let session = KVSession(json: nil)
    let host = PieEngineHost(launcher: { _ in (port: EnginePort(45678), session: session) })
    let running = expectation(description: "running")
    let token = host.observe { status, _ in
      if case .running = status { running.fulfill() }
    }
    _ = host.start(makeSpec())
    await fulfillment(of: [running], timeout: 2)

    let result = await kvUsage(HelperExportedAPI(engineHost: host, launchSpecResolver: nil))
    guard case .failure(let error) = result else {
      token.cancel()
      return XCTFail("expected missing running model_status to fail, got \(result)")
    }

    XCTAssertEqual(error.code, .engineGone)
    XCTAssertTrue(error.message.localizedCaseInsensitiveContains("kv usage"))
    XCTAssertTrue(error.message.localizedCaseInsensitiveContains("model_status"))
    token.cancel()
  }

  private func kvUsage(_ api: PieHelperXPC) async -> Result<[KVUsageSnapshot], EngineError> {
    await withCheckedContinuation { cont in
      api.kvUsage { successData, errorData in
        do {
          cont.resume(returning: try PieHelperXPCWire.decodeKVUsageReply(successData: successData, errorData: errorData))
        } catch let err as EngineError {
          cont.resume(returning: .failure(err))
        } catch {
          cont.resume(returning: .failure(EngineError(code: .wireContractViolation, message: "decode failed: \(error)")))
        }
      }
    }
  }
}
