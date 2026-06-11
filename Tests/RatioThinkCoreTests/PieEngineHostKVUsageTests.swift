import XCTest
@testable import RatioThinkCore

final class PieEngineHostKVUsageTests: XCTestCase {
  final class KVSession: PieEngineHost.EngineSession, @unchecked Sendable {
    let json: String?
    init(json: String?) { self.json = json }
    func shutdown() async -> EngineShutdownResult { .reaped }
    func modelStatusJSON() async throws -> String? { json }
  }

  private func makeSpec(profileID: String = "chat") -> PieControlLauncher.LaunchSpec {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    return try! PieControlLauncher.LaunchSpec(
      pieBinary: tmp.appendingPathComponent("ignored-pie"),
      wasmURL: tmp.appendingPathComponent("ignored.wasm"),
      manifestURL: tmp.appendingPathComponent("ignored.toml"),
      subprocessEnvironment: [:],
      pieHome: tmp.appendingPathComponent("home"),
      shmemName: "/pie_test_\(UUID().uuidString.prefix(8))",
      profileID: profileID,
      modelConfig: .dummy
    )
  }

  func test_kvUsageSnapshots_returnsEmptyWhenStopped() async throws {
    let host = PieEngineHost(launcher: { _ in (port: EnginePort(1), session: KVSession(json: nil)) })
    let snapshots = try await host.kvUsageSnapshots(now: { Date(timeIntervalSince1970: 1) })
    XCTAssertEqual(snapshots, [])
  }

  func test_kvUsageSnapshots_queriesRunningSessionAndStampsGeneration() async throws {
    let session = KVSession(json: #"{"default.kv_pages_used":2,"default.kv_pages_total":256}"#)
    let host = PieEngineHost(launcher: { _ in (port: EnginePort(45678), session: session) })
    let running = expectation(description: "running")
    let token = host.observe { status, _ in
      if case .running = status { running.fulfill() }
    }
    _ = host.start(makeSpec())
    await fulfillment(of: [running], timeout: 2)

    let first = try await host.kvUsageSnapshots(now: { Date(timeIntervalSince1970: 100) })
    let second = try await host.kvUsageSnapshots(now: { Date(timeIntervalSince1970: 101) })

    XCTAssertEqual(first.first?.modelID, "default")
    XCTAssertEqual(first.first?.pagesUsed, 2)
    XCTAssertEqual(first.first?.pagesTotal, 256)
    XCTAssertEqual(first.first?.observedAt, Date(timeIntervalSince1970: 100))
    XCTAssertEqual(first.first?.generation, 1)
    XCTAssertEqual(second.first?.generation, 2)
    token.cancel()
  }

  func test_kvUsageSnapshots_runningSessionMissingModelStatusThrows() async throws {
    let session = KVSession(json: nil)
    let host = PieEngineHost(launcher: { _ in (port: EnginePort(45678), session: session) })
    let running = expectation(description: "running")
    let token = host.observe { status, _ in
      if case .running = status { running.fulfill() }
    }
    _ = host.start(makeSpec())
    await fulfillment(of: [running], timeout: 2)

    do {
      _ = try await host.kvUsageSnapshots(now: { Date(timeIntervalSince1970: 102) })
      XCTFail("expected missing running model_status to throw")
    } catch {
      XCTAssertEqual(
        error as? KVUsageRefreshError,
        .modelStatusUnavailable(reason: "running engine did not provide model_status")
      )
    }
    token.cancel()
  }
}
