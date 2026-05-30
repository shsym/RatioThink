import XCTest
@testable import RatioThinkCore

/// Coverage for the `engineMemory` XPC selector: the real
/// `HelperExportedAPI` samples a running host's RSS; the no-host and
/// degraded paths reply `nil` (engine not running / unavailable).
final class HelperExportedAPIMemoryTests: XCTestCase {

  /// Fake session reporting a fixed RSS so the selector can be exercised
  /// without spawning a real pie process.
  final class MemSession: PieEngineHost.EngineSession, @unchecked Sendable {
    let bytes: UInt64
    init(_ bytes: UInt64) { self.bytes = bytes }
    func shutdown() async {}
    func residentMemoryBytes() async -> UInt64? { bytes }
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

  /// Drive the selector and decode its reply blob to `EngineMemorySample?`.
  private func decodeMemoryReply(_ api: PieHelperXPC) async -> EngineMemorySample? {
    let data: Data = await withCheckedContinuation { cont in
      api.engineMemory { cont.resume(returning: $0) }
    }
    return try? XPCPayload.decode(EngineMemorySample?.self, from: data)
  }

  func test_no_host_replies_nil() async {
    let sample = await decodeMemoryReply(HelperExportedAPI())
    XCTAssertNil(sample, "no engine host wired ⇒ memory unavailable")
  }

  func test_degraded_replies_nil() async {
    let api = DegradedHelperAPI(reasonMessage: "cannot reach state dir")
    let sample = await decodeMemoryReply(api)
    XCTAssertNil(sample, "degraded helper runs no engine ⇒ memory unavailable")
  }

  func test_running_host_replies_sample() async {
    let session = MemSession(987_654)
    let host = PieEngineHost(launcher: { _ in (port: EnginePort(45678), session: session) })
    let running = expectation(description: "host reaches .running")
    let token = host.observe { status, _ in
      if case .running = status { running.fulfill() }
    }
    _ = host.start(makeSpec())
    await fulfillment(of: [running], timeout: 2)

    let api = HelperExportedAPI(engineHost: host, launchSpecResolver: nil)
    let sample = await decodeMemoryReply(api)
    XCTAssertEqual(sample?.residentBytes, 987_654,
                   "engineMemory must surface the running session's RSS")
    token.cancel()
  }

  /// A 0-byte session reading is the dead/edge path, not a live
  /// measurement; the selector must reply nil — NOT
  /// `EngineMemorySample(residentBytes: 0)`, which renders "0 MB". Guards
  /// the `.flatMap(EngineMemorySample.from)` collapse at the XPC boundary.
  func test_zero_sample_replies_nil() async {
    let session = MemSession(0)
    let host = PieEngineHost(launcher: { _ in (port: EnginePort(45679), session: session) })
    let running = expectation(description: "host reaches .running")
    let token = host.observe { status, _ in
      if case .running = status { running.fulfill() }
    }
    _ = host.start(makeSpec())
    await fulfillment(of: [running], timeout: 2)

    let sample = await decodeMemoryReply(HelperExportedAPI(engineHost: host, launchSpecResolver: nil))
    XCTAssertNil(sample, "a 0-byte engine reading must decode as nil, not a 0 MB sample")
    token.cancel()
  }
}
