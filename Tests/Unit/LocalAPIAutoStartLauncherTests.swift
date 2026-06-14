import XCTest
@testable import RatioThink

@MainActor
final class LocalAPIAutoStartLauncherTests: XCTestCase {
  func test_enabledAutoStartSurfacesRealStartFailure() async {
    let client = ThrowingStartClient(
      startError: EngineError(code: .modelMissing, message: "model not staged"))
    let store = EngineStatusStore(client: client, initialStatus: .stopped)

    let result = await LocalAPIAutoStartLauncher.run(
      enabled: true,
      status: store.status,
      activeProfileID: "chat",
      startEngine: { try await store.startEngine(profileID: $0) },
      errorMessage: { ChatScaffoldView.engineErrorMessage($0, verb: "start") }
    )

    XCTAssertEqual(client.startCalls, 1)
    XCTAssertEqual(result, .failed(message: "Couldn't start the engine. The selected model isn’t downloaded. Download it in Settings → Models, or pick another model."))
  }

  private final class ThrowingStartClient: AppXPCClient, @unchecked Sendable {
    private let lock = NSLock()
    private let startError: Error
    private var _startCalls = 0
    var startCalls: Int { lock.withLock { _startCalls } }

    init(startError: Error) {
      self.startError = startError
    }

    func helperProtocolVersion() async throws -> Int { HelperProtocolCompatibility.currentVersion }
    func engineStatus() async throws -> EngineStatus { .stopped }
    func stopEngine() async throws {}
    func startEngine(profileID: String, modelOverride: String?) async throws {
      lock.withLock { _startCalls += 1 }
      throw startError
    }
    func restartEngine(profileID: String, modelOverride: String?) async throws {}
  }
}
