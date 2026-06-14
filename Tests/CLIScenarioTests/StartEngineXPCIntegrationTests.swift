import XCTest
import Foundation
@testable import RatioThinkCore

/// E2E NSXPCConnection coverage for Phase 2.4.
///
/// Drives `startEngine(profileID:)` over a real `NSXPCConnection`
/// from a same-process peer into a `HelperExportedAPI` wired to:
///   · a live `PieSupervisor` with shrunk policy timeouts,
///   · a `LaunchSpecResolver` reading a freshly-created profile out
///     of a per-test `ProfileStore`,
///   · a fake `pie` shell script that prints `HTTP_LISTEN=...` and
///     stays alive so the supervisor reaches `.running`.
///
/// The wire path covered here is the one Phase 2.2's in-process
/// supervisor tests deliberately skipped: encoded reply bytes flow
/// through `NSXPCCoder` and the per-listener exported-object lookup
/// before the test sees the `EnginePort` payload.
///
/// Inherits `IsolatedTestCase` for the per-test mach service name +
/// `PIE_TEST_MODE=1` gate (so `startAnonymous()` accepts the
/// listener without a code-signed caller).
final class StartEngineXPCIntegrationTests: IsolatedTestCase {

  private var tempDir: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    let uuid = UUID().uuidString.prefix(8).lowercased()
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("pie-startengine-xpc-\(uuid)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    tempDir = dir
  }

  override func tearDownWithError() throws {
    if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    tempDir = nil
    try super.tearDownWithError()
  }

  /// Happy path: profile exists, the launcher seam returns a synthetic
  /// `(port, FakeSession)` tuple, and the XPC reply carries the bound
  /// port back through `NSXPCCoder`.  removed PieSupervisor
  /// from the production path; the XPC layer no longer depends on
  /// `pie serve` spawning so the fake-script harness collapses to a
  /// pure Swift launcher closure.
  func test_startEngine_overXPC_returnsPort() async throws {
    let store = try makeProfileStoreWithChat()
    defer { store.stop() }

    let host = makeEngineHost(port: 24601)
    defer { host.stop() }

    let ignored = try writeCapabilityProbe(portable: true, metal: true)
    let modelsRoot = tempDir.appendingPathComponent("models", isDirectory: true)
    try FileManager.default.createDirectory(at: modelsRoot, withIntermediateDirectories: true)
    try Data("ignored".utf8).write(
      to: modelsRoot.appendingPathComponent("ignored-by-fake-pie.gguf", isDirectory: false)
    )
    let resources = try writeInferletResources(name: "chat-apc", version: "0.1.0")
    let resolver = LaunchSpecResolver(
      profileStore: store,
      pieBinary: { ignored },
      modelsRoot: { modelsRoot },
      inferletsDir: { self.tempDir.appendingPathComponent("inferlets") },
      pieControlResources: { resources },
      pieHome: { self.tempDir },
      subprocessEnvironment: { [:] }
    )
    let exported = HelperExportedAPI(engineHost: host,
                                     launchSpecResolver: resolver.asClosure)

    let listenerOwner = HelperXPCListener.startAnonymous(exportedObject: exported)
    defer { listenerOwner.invalidate() }

    let connection = NSXPCConnection(listenerEndpoint: listenerOwner.endpoint)
    connection.remoteObjectInterface = PieHelperXPCInterface.make()
    connection.resume()
    defer { connection.invalidate() }

    let api = try XCTUnwrap(connection.remoteObjectProxyWithErrorHandler { err in
      XCTFail("XPC proxy error: \(err)")
    } as? PieHelperXPC, "remote proxy must conform to PieHelperXPC")

    let port = try await callStartEngine(api: api, profileID: "chat", timeout: 8)
    XCTAssertEqual(port, 24601,
                   "supervisor must return the port pie printed over HTTP_LISTEN, round-tripped through NSXPCCoder")
  }

  // MARK: - #476 session-snapshot contract

  /// The `startEngine` reply carries the full `EngineSessionSnapshot` (port,
  /// profileID, servedModelID, effective ceiling, generation), and the SAME
  /// snapshot rides the `engineStatus` poll — one snapshot, two transports.
  func test_startEngine_overXPC_replyAndStatusCarryIdenticalSnapshot() async throws {
    let store = try makeProfileStoreWithChat(model: "ignored-by-fake-pie.gguf")
    defer { store.stop() }
    let host = makeEngineHost(port: 24611)
    defer { host.stop() }
    let exported = try makeExportedAPI(store: store, host: host) { modelsRoot in
      try Data("ignored".utf8).write(
        to: modelsRoot.appendingPathComponent("ignored-by-fake-pie.gguf", isDirectory: false))
    }
    let peer = try makeXPCPeer(exported: exported)
    defer { peer.owner.invalidate(); peer.connection.invalidate() }

    let snapshot = try await callStartEngineSnapshot(api: peer.api, profileID: "chat", timeout: 8)
    XCTAssertEqual(snapshot.port, 24611)
    XCTAssertEqual(snapshot.profileID, "chat")
    XCTAssertEqual(snapshot.servedModelID, "ignored-by-fake-pie.gguf",
                   "servedModelID must be the resolved boot model, not empty")
    // A fake (non-GGUF) artifact yields no arch metadata → no scheduler cap →
    // the engine's effective ceiling is the default pool capacity.
    XCTAssertEqual(snapshot.maxOutputTokens, KVCacheBudget.defaultPoolCapacityTokens)
    XCTAssertGreaterThan(snapshot.generation, 0, "generation must be a real launch id")

    let status = try await callEngineStatus(api: peer.api, timeout: 4)
    guard case .running(let polled) = status else {
      return XCTFail("expected .running over the status wire, got \(status)")
    }
    XCTAssertEqual(polled, snapshot,
                   "the engineStatus poll must carry the IDENTICAL snapshot the start reply returned")
  }

  /// An explicit per-start model override is reflected in the snapshot's
  /// `servedModelID` — the App reads the served id off the snapshot, not the
  /// profile default (#459 repro 1 / #476).
  func test_startEngine_explicitOverride_snapshotReportsOverriddenModel() async throws {
    let store = try makeProfileStoreWithChat(model: "profile-default.gguf")
    defer { store.stop() }
    let host = makeEngineHost(port: 24612)
    defer { host.stop() }
    let exported = try makeExportedAPI(store: store, host: host) { modelsRoot in
      try Data("a".utf8).write(to: modelsRoot.appendingPathComponent("profile-default.gguf", isDirectory: false))
      try Data("b".utf8).write(to: modelsRoot.appendingPathComponent("explicit-override.gguf", isDirectory: false))
    }
    let peer = try makeXPCPeer(exported: exported)
    defer { peer.owner.invalidate(); peer.connection.invalidate() }

    let snapshot = try await callStartEngineSnapshot(
      api: peer.api, profileID: "chat", modelOverride: "explicit-override.gguf", timeout: 8)
    XCTAssertEqual(snapshot.servedModelID, "explicit-override.gguf",
                   "an explicit override must be the served model, overriding the profile default")
  }

  /// A restart bumps the launch generation, so a snapshot the App composed
  /// against the prior session is detectably stale (#476 stale-state id).
  func test_restartEngine_overXPC_bumpsGenerationMakingPriorSnapshotStale() async throws {
    let store = try makeProfileStoreWithChat(model: "ignored-by-fake-pie.gguf")
    defer { store.stop() }
    let host = makeEngineHost(port: 24613)
    defer { host.stop() }
    let exported = try makeExportedAPI(store: store, host: host) { modelsRoot in
      try Data("ignored".utf8).write(
        to: modelsRoot.appendingPathComponent("ignored-by-fake-pie.gguf", isDirectory: false))
    }
    let peer = try makeXPCPeer(exported: exported)
    defer { peer.owner.invalidate(); peer.connection.invalidate() }

    let first = try await callStartEngineSnapshot(api: peer.api, profileID: "chat", timeout: 8)
    let second = try await callStartEngineSnapshot(
      api: peer.api, profileID: "chat", restart: true, timeout: 8)
    XCTAssertGreaterThan(second.generation, first.generation,
                         "a restart must mint a new launch generation")
    XCTAssertFalse(second.isSameSession(as: first),
                   "the prior snapshot must be detectably stale after a restart")
  }

  ///  G1: a mid-session engine death must surface as a coded
  /// `.failed(.engineGone)` through the real `engineStatus()` XPC wire
  /// (NSXPCCoder round-trip), not just inside the host. Drives the
  /// liveness-monitor seam with a session whose probe reports alive
  /// once (so `startEngine` returns the port) then gone — no real
  /// engine, no  dependency.
  func test_engineDeath_overXPC_surfacesEngineGoneStatus() async throws {
    let store = try makeProfileStoreWithChat()
    defer { store.stop() }

    let session = ScriptedLivenessSession([
      .alive,
      .gone(reason: "engine process exited (status 139)"),
    ])
    let host = PieEngineHost(
      launcher: { _ in (port: EnginePort(24602), session: session) },
      livenessInterval: 0.1,
      livenessFailureThreshold: 1
    )
    defer { host.stop() }

    let ignored = try writeCapabilityProbe(portable: true, metal: true)
    let modelsRoot = tempDir.appendingPathComponent("models", isDirectory: true)
    try FileManager.default.createDirectory(at: modelsRoot, withIntermediateDirectories: true)
    try Data("ignored".utf8).write(
      to: modelsRoot.appendingPathComponent("ignored-by-fake-pie.gguf", isDirectory: false)
    )
    let resources = try writeInferletResources(name: "chat-apc", version: "0.1.0")
    let resolver = LaunchSpecResolver(
      profileStore: store,
      pieBinary: { ignored },
      modelsRoot: { modelsRoot },
      inferletsDir: { self.tempDir.appendingPathComponent("inferlets") },
      pieControlResources: { resources },
      pieHome: { self.tempDir },
      subprocessEnvironment: { [:] }
    )
    let exported = HelperExportedAPI(engineHost: host,
                                     launchSpecResolver: resolver.asClosure)
    let listenerOwner = HelperXPCListener.startAnonymous(exportedObject: exported)
    defer { listenerOwner.invalidate() }
    let connection = NSXPCConnection(listenerEndpoint: listenerOwner.endpoint)
    connection.remoteObjectInterface = PieHelperXPCInterface.make()
    connection.resume()
    defer { connection.invalidate() }
    let api = try XCTUnwrap(connection.remoteObjectProxyWithErrorHandler { err in
      XCTFail("XPC proxy error: \(err)")
    } as? PieHelperXPC, "remote proxy must conform to PieHelperXPC")

    let port = try await callStartEngine(api: api, profileID: "chat", timeout: 8)
    XCTAssertEqual(port, 24602)

    // Poll engineStatus over the wire until the monitor surfaces
    // engine-gone (bounded so a regression can't hang the suite).
    var surfaced: EngineStatus = .starting
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      surfaced = try await callEngineStatus(api: api, timeout: 4)
      if case .failed(.engineGone, _) = surfaced { break }
      try await Task.sleep(nanoseconds: 40_000_000)
    }
    guard case .failed(.engineGone, let message) = surfaced else {
      return XCTFail("expected .failed(.engineGone) over XPC, got \(surfaced)")
    }
    XCTAssertFalse(message.isEmpty, "engine-gone status must carry a cause over the wire")
  }

  /// #448 regression: a HEALTHY engine that reaches `.running` must NOT be
  /// stopped by the `startEngine` reply-timeout fallback after the deadline
  /// elapses. Pre-fix, the fallback called `engineHost.stop()`
  /// unconditionally, killing a running engine exactly `startReplyDeadline`s
  /// (60s in prod) after every App-driven start — the "engine dies ~1 min
  /// after going idle" report. Here the deadline is shrunk to 0.3s via the
  /// DEBUG `replyTimeoutOverride` seam; the engine must still be `.running`
  /// after the timer would have fired.
  func test_startEngine_healthyEngineSurvivesReplyDeadline() async throws {
    let store = try makeProfileStoreWithChat()
    defer { store.stop() }

    let host = makeEngineHost(port: 24650)
    defer { host.stop() }

    let ignored = try writeCapabilityProbe(portable: true, metal: true)
    let modelsRoot = tempDir.appendingPathComponent("models", isDirectory: true)
    try FileManager.default.createDirectory(at: modelsRoot, withIntermediateDirectories: true)
    try Data("ignored".utf8).write(
      to: modelsRoot.appendingPathComponent("ignored-by-fake-pie.gguf", isDirectory: false)
    )
    let resources = try writeInferletResources(name: "chat-apc", version: "0.1.0")
    let resolver = LaunchSpecResolver(
      profileStore: store,
      pieBinary: { ignored },
      modelsRoot: { modelsRoot },
      inferletsDir: { self.tempDir.appendingPathComponent("inferlets") },
      pieControlResources: { resources },
      pieHome: { self.tempDir },
      subprocessEnvironment: { [:] }
    )
    // Shrink ONLY the start deadline so the fallback timer fires ~0.3s after
    // start; the engine reaches `.running` near-instantly via FakeSession.
    let exported = HelperExportedAPI(engineHost: host,
                                     launchSpecResolver: resolver.asClosure,
                                     replyTimeoutOverride: (start: 0.3, stop: 17))

    let listenerOwner = HelperXPCListener.startAnonymous(exportedObject: exported)
    defer { listenerOwner.invalidate() }
    let connection = NSXPCConnection(listenerEndpoint: listenerOwner.endpoint)
    connection.remoteObjectInterface = PieHelperXPCInterface.make()
    connection.resume()
    defer { connection.invalidate() }
    let api = try XCTUnwrap(connection.remoteObjectProxyWithErrorHandler { err in
      XCTFail("XPC proxy error: \(err)")
    } as? PieHelperXPC, "remote proxy must conform to PieHelperXPC")

    let port = try await callStartEngine(api: api, profileID: "chat", timeout: 8)
    XCTAssertEqual(port, 24650)

    // Wait well past the 0.3s start deadline (when the buggy fallback would
    // have stopped the engine).
    try await Task.sleep(nanoseconds: 900_000_000)

    let status = try await callEngineStatus(api: api, timeout: 4)
    guard case .running = status else {
      return XCTFail("healthy engine was stopped by the reply-timeout fallback after the deadline (got \(status)) — #448 idle-death regression")
    }
  }

  // MARK: - #461: App-initiated start as reliable as helper/menu Resume

  /// #461 core: the App route (`HelperXPCClient.startEngine` over a real
  /// `NSXPCConnection`) must wait out a slow cold start and return the real
  /// `.running` outcome, exactly as the in-process menu Resume does. The
  /// derived `defaultStartReplyTimeout` dominates the helper's start reply
  /// deadline; here both are scaled down deterministically (helper start
  /// budget 4s via `replyTimeoutOverride`, App budget 3s) and the launcher
  /// takes 0.5s — comfortably above the 2s the pure-start path used pre-#461.
  func test_appRoute_startEngine_waitsOutSlowColdStart() async throws {
    let store = try makeProfileStoreWithChat()
    defer { store.stop() }
    let host = makeSlowEngineHost(port: 24700, delay: 0.5)
    defer { host.stop() }

    let exported = HelperExportedAPI(
      engineHost: host,
      launchSpecResolver: try makeChatResolver(store: store).asClosure,
      replyTimeoutOverride: (start: 4, stop: 17)
    )
    let listenerOwner = HelperXPCListener.startAnonymous(exportedObject: exported)
    defer { listenerOwner.invalidate() }

    let client = HelperXPCClient(
      endpoint: .listenerEndpoint(listenerOwner.endpoint),
      startReplyTimeout: 3.0
    )

    // Must NOT throw: the App start budget (3s) sits above the launcher's 0.5s
    // cold start, so the selector delivers the real terminal result. Pre-#461
    // the 2s generic `replyTimeout` would not even be exercised here, but the
    // production default (135s+slack) is what guarantees a real large-model
    // boot is awaited rather than timed out at 2s.
    try await client.startEngine(profileID: "chat", modelOverride: nil)
    guard case .running(let snap) = host.status else {
      return XCTFail("App route must converge on .running; got \(host.status)")
    }
    XCTAssertEqual(snap.port, 24700,
                   "App route must converge on the same .running port the host reached")
    XCTAssertEqual(snap.profileID, "chat")
  }

  /// #461 acceptance 2: an App reply timeout (the App giving up early) must
  /// NOT stop a still-starting engine — launch lifetime is host-owned. Models
  /// the pre-#461 too-short budget by shrinking the App wait BELOW the
  /// launcher delay; the App `startEngine` throws `.replyTimeout`, but the
  /// engine must still reach `.running` on the host's own lease.
  func test_appRoute_startReplyTimeout_doesNotStopStillStartingEngine() async throws {
    let store = try makeProfileStoreWithChat()
    defer { store.stop() }
    let host = makeSlowEngineHost(port: 24701, delay: 0.6)
    defer { host.stop() }

    let exported = HelperExportedAPI(
      engineHost: host,
      launchSpecResolver: try makeChatResolver(store: store).asClosure,
      replyTimeoutOverride: (start: 4, stop: 17)
    )
    let listenerOwner = HelperXPCListener.startAnonymous(exportedObject: exported)
    defer { listenerOwner.invalidate() }

    // App budget 0.2s < 0.6s launcher delay → the App gives up before the
    // engine finishes booting.
    let client = HelperXPCClient(
      endpoint: .listenerEndpoint(listenerOwner.endpoint),
      startReplyTimeout: 0.2
    )

    do {
      try await client.startEngine(profileID: "chat", modelOverride: nil)
      XCTFail("App start budget below the launch delay must surface .replyTimeout")
    } catch let error as AppXPCClientError {
      guard case .replyTimeout = error else {
        return XCTFail("expected .replyTimeout, got \(error)")
      }
    }

    // The App gave up, but the host-owned launch must still complete: the
    // reply timeout is NOT a lifetime lease and must never stop the engine.
    try await pollHostUntilRunning(host, port: 24701, deadline: 3)
  }

  /// #461 acceptance 3: the App route and the menu/helper "Resume Engine"
  /// route converge on the same final engine state for the same profile/model.
  /// Same `ProfileStore` (activeProfile "chat") + same resolver feed both an
  /// App-route start (over NSXPC) and a menu-route start
  /// (`HelperResumeAction.run`, the in-process selector the status-bar Resume
  /// click takes); both reach `.running(port, "chat")`.
  func test_appRoute_and_menuResume_convergeOnSameRunningState() async throws {
    let store = try makeProfileStoreWithChat()
    defer { store.stop() }
    let resolver = try makeChatResolver(store: store)

    // App route over the real NSXPC wire.
    let appHost = makeSlowEngineHost(port: 24702, delay: 0.3)
    defer { appHost.stop() }
    let exported = HelperExportedAPI(engineHost: appHost,
                                     launchSpecResolver: resolver.asClosure,
                                     replyTimeoutOverride: (start: 4, stop: 17))
    let listenerOwner = HelperXPCListener.startAnonymous(exportedObject: exported)
    defer { listenerOwner.invalidate() }
    let client = HelperXPCClient(endpoint: .listenerEndpoint(listenerOwner.endpoint),
                                 startReplyTimeout: 3.0)
    try await client.startEngine(profileID: "chat", modelOverride: nil)

    // Menu/helper Resume route, in-process, same inputs.
    let menuHost = makeSlowEngineHost(port: 24702, delay: 0.3)
    defer { menuHost.stop() }
    let outcome = HelperResumeAction.run(engineHost: menuHost,
                                         profileStore: store,
                                         resolver: resolver.asClosure)
    XCTAssertEqual(outcome, .started(profileID: "chat"),
                   "menu Resume must resolve the active profile and start it")
    try await pollHostUntilRunning(menuHost, port: 24702, deadline: 3)

    XCTAssertEqual(appHost.status, menuHost.status,
                   "App-initiated start and menu Resume must converge on the same final engine state for the same profile/model")
  }

  /// #448 quitHelper over the real NSXPC wire: a running engine is stopped
  /// (reaped) and the helper-self-terminate hook fires, with a nil (accepted)
  /// reply. Proves the full-product quit reaches `pie` through the Helper —
  /// the App calls exactly this selector as the final step of a coordinated
  /// quit, which is what guarantees "no orphan pie".
  func test_quitHelper_overXPC_stopsEngineAndFiresTermination() async throws {
    let store = try makeProfileStoreWithChat()
    defer { store.stop() }

    let host = makeEngineHost(port: 24660)
    defer { host.stop() }

    let ignored = try writeCapabilityProbe(portable: true, metal: true)
    let modelsRoot = tempDir.appendingPathComponent("models", isDirectory: true)
    try FileManager.default.createDirectory(at: modelsRoot, withIntermediateDirectories: true)
    try Data("ignored".utf8).write(
      to: modelsRoot.appendingPathComponent("ignored-by-fake-pie.gguf", isDirectory: false)
    )
    let resources = try writeInferletResources(name: "chat-apc", version: "0.1.0")
    let resolver = LaunchSpecResolver(
      profileStore: store,
      pieBinary: { ignored },
      modelsRoot: { modelsRoot },
      inferletsDir: { self.tempDir.appendingPathComponent("inferlets") },
      pieControlResources: { resources },
      pieHome: { self.tempDir },
      subprocessEnvironment: { [:] }
    )
    let terminated = expectation(description: "onQuitRequested (helper self-terminate) fired")
    let exported = HelperExportedAPI(
      engineHost: host,
      launchSpecResolver: resolver.asClosure,
      onQuitRequested: { terminated.fulfill() }
    )

    let listenerOwner = HelperXPCListener.startAnonymous(exportedObject: exported)
    defer { listenerOwner.invalidate() }
    let connection = NSXPCConnection(listenerEndpoint: listenerOwner.endpoint)
    connection.remoteObjectInterface = PieHelperXPCInterface.make()
    connection.resume()
    defer { connection.invalidate() }
    let api = try XCTUnwrap(connection.remoteObjectProxyWithErrorHandler { err in
      XCTFail("XPC proxy error: \(err)")
    } as? PieHelperXPC, "remote proxy must conform to PieHelperXPC")

    let port = try await callStartEngine(api: api, profileID: "chat", timeout: 8)
    XCTAssertEqual(port, 24660)

    try await callQuitHelper(api: api, timeout: 8)
    await fulfillment(of: [terminated], timeout: 5)
    XCTAssertEqual(host.status, .stopped, "quitHelper must reap the engine before terminating")
  }

  func test_quitHelper_overXPC_timeoutReturnsEngineErrorAndDoesNotTerminateHelper() async throws {
    final class HangingShutdownSession: PieEngineHost.EngineSession, @unchecked Sendable {
      func shutdown() async -> EngineShutdownResult {
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        return .unreaped("test session did not reap")
      }
    }

    let store = try makeProfileStoreWithChat()
    defer { store.stop() }

    let host = PieEngineHost(launcher: { _ in
      (port: EnginePort(24661), session: HangingShutdownSession())
    })
    defer { host.stop() }

    let ignored = try writeCapabilityProbe(portable: true, metal: true)
    let modelsRoot = tempDir.appendingPathComponent("models", isDirectory: true)
    try FileManager.default.createDirectory(at: modelsRoot, withIntermediateDirectories: true)
    try Data("ignored".utf8).write(
      to: modelsRoot.appendingPathComponent("ignored-by-fake-pie.gguf", isDirectory: false)
    )
    let resources = try writeInferletResources(name: "chat-apc", version: "0.1.0")
    let resolver = LaunchSpecResolver(
      profileStore: store,
      pieBinary: { ignored },
      modelsRoot: { modelsRoot },
      inferletsDir: { self.tempDir.appendingPathComponent("inferlets") },
      pieControlResources: { resources },
      pieHome: { self.tempDir },
      subprocessEnvironment: { [:] }
    )
    let terminated = expectation(description: "onQuitRequested must not fire while pie may still be alive")
    terminated.isInverted = true
    let exported = HelperExportedAPI(
      engineHost: host,
      launchSpecResolver: resolver.asClosure,
      replyTimeoutOverride: (start: 8, stop: 0.05),
      onQuitRequested: { terminated.fulfill() }
    )

    let listenerOwner = HelperXPCListener.startAnonymous(exportedObject: exported)
    defer { listenerOwner.invalidate() }
    let connection = NSXPCConnection(listenerEndpoint: listenerOwner.endpoint)
    connection.remoteObjectInterface = PieHelperXPCInterface.make()
    connection.resume()
    defer { connection.invalidate() }
    let api = try XCTUnwrap(connection.remoteObjectProxyWithErrorHandler { err in
      XCTFail("XPC proxy error: \(err)")
    } as? PieHelperXPC, "remote proxy must conform to PieHelperXPC")

    let port = try await callStartEngine(api: api, profileID: "chat", timeout: 8)
    XCTAssertEqual(port, 24661)

    do {
      try await callQuitHelper(api: api, timeout: 2)
      XCTFail("quitHelper timeout must not be reported as nil success")
    } catch XPCError.engine(let err) {
      XCTAssertEqual(err.code, .handshakeTimeout)
      XCTAssertTrue(err.message.contains("quitHelper"))
      XCTAssertTrue(err.message.contains("0.05"))
    }
    await fulfillment(of: [terminated], timeout: 0.5)
  }

  func test_quitHelper_overXPC_unreapedShutdownReturnsKillRejectedInsteadOfNilSuccess() async throws {
    final class UnreapedShutdownSession: PieEngineHost.EngineSession, @unchecked Sendable {
      func shutdown() async -> EngineShutdownResult {
        .unreaped("SIGKILL + 5s waitpid window did not reap pid 4242")
      }
    }

    let store = try makeProfileStoreWithChat()
    defer { store.stop() }

    let host = PieEngineHost(launcher: { _ in
      (port: EnginePort(24662), session: UnreapedShutdownSession())
    })
    defer { host.stop() }

    let ignored = try writeCapabilityProbe(portable: true, metal: true)
    let modelsRoot = tempDir.appendingPathComponent("models", isDirectory: true)
    try FileManager.default.createDirectory(at: modelsRoot, withIntermediateDirectories: true)
    try Data("ignored".utf8).write(
      to: modelsRoot.appendingPathComponent("ignored-by-fake-pie.gguf", isDirectory: false)
    )
    let resources = try writeInferletResources(name: "chat-apc", version: "0.1.0")
    let resolver = LaunchSpecResolver(
      profileStore: store,
      pieBinary: { ignored },
      modelsRoot: { modelsRoot },
      inferletsDir: { self.tempDir.appendingPathComponent("inferlets") },
      pieControlResources: { resources },
      pieHome: { self.tempDir },
      subprocessEnvironment: { [:] }
    )
    let terminated = expectation(description: "onQuitRequested must not fire after failed reap")
    terminated.isInverted = true
    let exported = HelperExportedAPI(
      engineHost: host,
      launchSpecResolver: resolver.asClosure,
      replyTimeoutOverride: (start: 8, stop: 2),
      onQuitRequested: { terminated.fulfill() }
    )

    let listenerOwner = HelperXPCListener.startAnonymous(exportedObject: exported)
    defer { listenerOwner.invalidate() }
    let connection = NSXPCConnection(listenerEndpoint: listenerOwner.endpoint)
    connection.remoteObjectInterface = PieHelperXPCInterface.make()
    connection.resume()
    defer { connection.invalidate() }
    let api = try XCTUnwrap(connection.remoteObjectProxyWithErrorHandler { err in
      XCTFail("XPC proxy error: \(err)")
    } as? PieHelperXPC, "remote proxy must conform to PieHelperXPC")

    let port = try await callStartEngine(api: api, profileID: "chat", timeout: 8)
    XCTAssertEqual(port, 24662)

    do {
      try await callQuitHelper(api: api, timeout: 2)
      XCTFail("quitHelper unreaped shutdown must not be reported as nil success")
    } catch XPCError.engine(let err) {
      XCTAssertEqual(err.code, .killRejected)
      XCTAssertTrue(err.message.contains("did not reap pid 4242"))
    }
    await fulfillment(of: [terminated], timeout: 0.5)
  }

  /// Session whose `checkLiveness()` replays a scripted sequence, then
  /// repeats the final element — models a mid-session engine death for
  /// the XPC engine-gone integration test.
  private final class ScriptedLivenessSession: PieEngineHost.EngineSession, @unchecked Sendable {
    private let lock = NSLock()
    private let script: [EngineLiveness]
    private var idx = 0
    init(_ script: [EngineLiveness]) { self.script = script }
    func shutdown() async -> EngineShutdownResult { .reaped }
    func checkLiveness() async -> EngineLiveness {
      lock.lock(); defer { lock.unlock() }
      let v = script[min(idx, script.count - 1)]
      idx += 1
      return v
    }
  }

  /// Unknown profile id over the wire surfaces `.profileMissing` on
  /// the error slot — proves the resolver's failure shape survives
  /// `XPCPayload` encode/decode through the listener.
  func test_startEngine_overXPC_unknownProfile_returnsProfileMissing() async throws {
    let store = try makeProfileStoreWithChat()
    defer { store.stop() }
    let host = makeEngineHost(port: 24601)
    defer { host.stop() }

    let resolver = LaunchSpecResolver(
      profileStore: store,
      pieBinary: { self.tempDir.appendingPathComponent("ignored") },
      modelsRoot: { self.tempDir.appendingPathComponent("models") },
      inferletsDir: { self.tempDir.appendingPathComponent("inferlets") },
      pieControlResources: { (
        wasm: self.tempDir.appendingPathComponent("ignored.wasm"),
        manifest: self.tempDir.appendingPathComponent("ignored.toml")
      ) },
      pieHome: { self.tempDir },
      subprocessEnvironment: { [:] }
    )
    let exported = HelperExportedAPI(engineHost: host,
                                     launchSpecResolver: resolver.asClosure)

    let listenerOwner = HelperXPCListener.startAnonymous(exportedObject: exported)
    defer { listenerOwner.invalidate() }

    let connection = NSXPCConnection(listenerEndpoint: listenerOwner.endpoint)
    connection.remoteObjectInterface = PieHelperXPCInterface.make()
    connection.resume()
    defer { connection.invalidate() }

    let api = try XCTUnwrap(connection.remoteObjectProxyWithErrorHandler { err in
      XCTFail("XPC proxy error: \(err)")
    } as? PieHelperXPC)

    do {
      _ = try await callStartEngine(api: api, profileID: "ghost", timeout: 3)
      XCTFail("expected .profileMissing for unknown profile id")
    } catch XPCError.engine(let err) {
      XCTAssertEqual(err.code, .profileMissing)
    }
  }

  /// : an oversized app-staged model must be rejected by
  /// the profile resolver before `PieEngineHost` enters `.starting`.
  /// This is the real NSXPC boundary (NSXPCCoder + listener endpoint),
  /// not just the in-process HelperExportedAPI unit seam.
  func test_startEngine_overXPC_oversizedAppStagedModel_returnsMemoryRiskAndPublishesFailedStatus() async throws {
    let store = try makeProfileStoreWithChat(model: "too-big.gguf")
    defer { store.stop() }
    let host = makeEngineHost(port: 24601)
    defer { host.stop() }

    let exported = try makeExportedAPI(
      store: store,
      host: host,
      configureModelsRoot: { modelsRoot in
        try self.stageSparseModel(
          named: "too-big.gguf",
          in: modelsRoot,
          sizeBytes: ModelMemoryGuardrail.defaultPolicy.maxResolvedModelBytes + 1
        )
      }
    )
    let (api, owner, connection) = try makeXPCPeer(exported: exported)
    defer {
      connection.invalidate()
      owner.invalidate()
    }

    do {
      _ = try await callStartEngine(api: api, profileID: "chat", timeout: 3)
      XCTFail("expected .memoryRisk for oversized app-staged model")
    } catch XPCError.engine(let err) {
      XCTAssertEqual(err.code, .memoryRisk)
      XCTAssertTrue(err.message.contains("memory risk"), "got: \(err.message)")
      XCTAssertTrue(err.message.contains("choose a smaller model"), "got: \(err.message)")
    }

    let status = try await callEngineStatus(api: api, timeout: 3)
    guard case .failed(let code, let message) = status else {
      return XCTFail("expected resolver-level memory-risk rejection to publish .failed, got \(status)")
    }
    XCTAssertEqual(code, .memoryRisk)
    XCTAssertTrue(message.contains("choose a smaller model"), "got: \(message)")
  }

  ///  unknown-size policy through the scenario layer: once
  /// HF cache resolution finds a launchable snapshot, any artifact
  /// whose size cannot be determined safely fails closed as
  /// `.memoryRisk` before launch. A dangling extra symlink is a stable
  /// fixture for that condition without real model downloads/loads.
  func test_startEngine_overXPC_hfSnapshotWithUnknownSizeArtifact_returnsMemoryRiskAndPublishesFailedStatus() async throws {
    let store = try makeProfileStoreWithChat(model: "Qwen/Qwen3-0.6B")
    defer { store.stop() }
    let host = makeEngineHost(port: 24601)
    defer { host.stop() }

    let hfHome = tempDir.appendingPathComponent("hf-home", isDirectory: true)
    let snapshot = try writeHFCacheSnapshot(
      hfHome: hfHome,
      repo: "Qwen/Qwen3-0.6B",
      files: [
        "config.json": "{}",
        "tokenizer.json": "{}",
        "model.safetensors": "weights",
      ]
    )
    try FileManager.default.createSymbolicLink(
      atPath: snapshot.appendingPathComponent("unknown-size.bin", isDirectory: false).path,
      withDestinationPath: "../../blobs/missing-unknown-size"
    )

    let exported = try makeExportedAPI(
      store: store,
      host: host,
      hfHome: hfHome
    )
    let (api, owner, connection) = try makeXPCPeer(exported: exported)
    defer {
      connection.invalidate()
      owner.invalidate()
    }

    do {
      _ = try await callStartEngine(api: api, profileID: "chat", timeout: 3)
      XCTFail("expected .memoryRisk for unknown-size HF snapshot artifact")
    } catch XPCError.engine(let err) {
      XCTAssertEqual(err.code, .memoryRisk)
      XCTAssertTrue(err.message.contains("cannot determine model size safely"),
                    "got: \(err.message)")
      XCTAssertTrue(err.message.contains("choose a smaller model"), "got: \(err.message)")
    }

    let status = try await callEngineStatus(api: api, timeout: 3)
    guard case .failed(let code, let message) = status else {
      return XCTFail("expected unknown-size memory rejection to publish .failed, got \(status)")
    }
    XCTAssertEqual(code, .memoryRisk)
    XCTAssertTrue(message.contains("cannot determine model size safely"), "got: \(message)")
  }

  // MARK: - helpers

  private func makeProfileStoreWithChat() throws -> ProfileStore {
    try makeProfileStoreWithChat(model: "ignored-by-fake-pie.gguf")
  }

  private func makeProfileStoreWithChat(model: String) throws -> ProfileStore {
    let profiles = tempDir.appendingPathComponent("profiles", isDirectory: true)
    try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
    let toml = """
    id = "chat"
    name = "Chat"
    model = "\(model)"
    inferlet = "chat-apc"
    """
    try toml.write(to: profiles.appendingPathComponent("chat.toml"),
                   atomically: true, encoding: .utf8)
    let active = tempDir.appendingPathComponent("active-profile", isDirectory: false)
    let store = ProfileStore(directory: profiles, activeProfileURL: active)
    try store.start()
    try store.setActiveProfileID("chat")
    return store
  }

  private func makeExportedAPI(
    store: ProfileStore,
    host: PieEngineHost,
    hfHome: URL? = nil,
    configureModelsRoot: (URL) throws -> Void = { _ in }
  ) throws -> HelperExportedAPI {
    let ignored = try writeCapabilityProbe(portable: true, metal: true)
    let modelsRoot = tempDir.appendingPathComponent("models-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: modelsRoot, withIntermediateDirectories: true)
    try configureModelsRoot(modelsRoot)
    let resources = try writeInferletResources(name: "chat-apc", version: "0.1.0")
    let resolver = LaunchSpecResolver(
      profileStore: store,
      pieBinary: { ignored },
      modelsRoot: { modelsRoot },
      inferletsDir: { self.tempDir.appendingPathComponent("inferlets") },
      pieControlResources: { resources },
      pieHome: { self.tempDir },
      subprocessEnvironment: { [:] },
      hfHome: { hfHome ?? self.tempDir.appendingPathComponent("hf-empty", isDirectory: true) }
    )
    return HelperExportedAPI(engineHost: host,
                             launchSpecResolver: resolver.asClosure)
  }

  private func makeXPCPeer(exported: PieHelperXPC) throws
    -> (api: PieHelperXPC, owner: HelperXPCListener, connection: NSXPCConnection) {
    let listenerOwner = HelperXPCListener.startAnonymous(exportedObject: exported)
    let connection = NSXPCConnection(listenerEndpoint: listenerOwner.endpoint)
    connection.remoteObjectInterface = PieHelperXPCInterface.make()
    connection.resume()
    let api = try XCTUnwrap(connection.remoteObjectProxyWithErrorHandler { err in
      XCTFail("XPC proxy error: \(err)")
    } as? PieHelperXPC, "remote proxy must conform to PieHelperXPC")
    return (api, listenerOwner, connection)
  }

  private func writeInferletResources(name: String,
                                      version: String) throws -> (wasm: URL, manifest: URL) {
    let dir = tempDir.appendingPathComponent("inferlet-\(name)-\(version)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let wasm = dir.appendingPathComponent("\(name).wasm", isDirectory: false)
    try Data().write(to: wasm)
    let manifest = dir.appendingPathComponent("Pie.toml", isDirectory: false)
    try """
    [package]
    name = "\(name)"
    version = "\(version)"
    """.write(to: manifest, atomically: true, encoding: .utf8)
    return (wasm: wasm, manifest: manifest)
  }

  private func writeCapabilityProbe(portable: Bool, metal: Bool) throws -> URL {
    let binary = tempDir.appendingPathComponent("ignored-pie", isDirectory: false)
    // The launcher now probes `pie driver list` (not the removed
    // `pie capabilities`). `metal` is vestigial — Metal is the portable
    // driver's device, so the probe only reports portable.
    let mark = portable ? "(compiled in)" : "(not compiled)"
    let script = """
    #!/bin/sh
    if [ "$1" = "driver" ] && [ "$2" = "list" ]; then
      printf 'Embedded drivers (compiled into this binary by feature):\\n  portable     \(mark)\\n  dummy        (compiled in)\\n'
      exit 0
    fi
    exit 0
    """
    try script.write(to: binary, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o755)],
      ofItemAtPath: binary.path
    )
    return binary
  }

  @discardableResult
  private func stageSparseModel(named name: String,
                                in modelsRoot: URL,
                                sizeBytes: Int64) throws -> URL {
    let url = name
      .split(separator: "/", omittingEmptySubsequences: true)
      .map(String.init)
      .reduce(modelsRoot) { partial, component in
        partial.appendingPathComponent(component, isDirectory: false)
      }
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    _ = FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: UInt64(sizeBytes))
    try handle.close()
    return url
  }

  @discardableResult
  private func writeHFCacheSnapshot(hfHome: URL,
                                    repo: String,
                                    revision: String = "0123456789abcdef0123456789abcdef01234567",
                                    files: [String: String]) throws -> URL {
    let repoDir = hfHome
      .appendingPathComponent("hub", isDirectory: true)
      .appendingPathComponent("models--\(repo.replacingOccurrences(of: "/", with: "--"))",
                              isDirectory: true)
    let refsDir = repoDir.appendingPathComponent("refs", isDirectory: true)
    let snapshot = repoDir
      .appendingPathComponent("snapshots", isDirectory: true)
      .appendingPathComponent(revision, isDirectory: true)
    try FileManager.default.createDirectory(at: refsDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
    try revision.write(to: refsDir.appendingPathComponent("main"),
                       atomically: true, encoding: .utf8)
    for (relativePath, contents) in files {
      let url = snapshot.appendingPathComponent(relativePath, isDirectory: false)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try contents.write(to: url, atomically: true, encoding: .utf8)
    }
    return snapshot
  }

  /// Build a `PieEngineHost` whose launcher seam returns a synthetic
  /// `(port, FakeSession)` tuple.  replaced the
  /// fake-pie shell script harness — the XPC test surface no longer
  /// needs a real subprocess because `PieEngineHost` accepts an
  /// injectable launcher closure.
  private func makeEngineHost(port: EnginePort) -> PieEngineHost {
    PieEngineHost(launcher: { _ in
      return (port: port, session: FakeSession())
    })
  }

  /// `PieEngineHost` whose launcher sleeps `delay` before returning the
  /// session — a deterministic stand-in for a slow cold large-model boot
  /// (#461). The host stays `.starting` for `delay`, then reaches `.running`.
  private func makeSlowEngineHost(port: EnginePort, delay: TimeInterval) -> PieEngineHost {
    PieEngineHost(launcher: { _ in
      try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
      return (port: port, session: FakeSession())
    })
  }

  /// Resolver over the freshly-created "chat" profile with a staged
  /// fake-pie model + inferlet resources. Shared by the App route and the
  /// menu Resume route so #461's convergence test feeds both identical inputs.
  private func makeChatResolver(store: ProfileStore) throws -> LaunchSpecResolver {
    let ignored = try writeCapabilityProbe(portable: true, metal: true)
    let modelsRoot = tempDir.appendingPathComponent("models", isDirectory: true)
    try FileManager.default.createDirectory(at: modelsRoot, withIntermediateDirectories: true)
    try Data("ignored".utf8).write(
      to: modelsRoot.appendingPathComponent("ignored-by-fake-pie.gguf", isDirectory: false)
    )
    let resources = try writeInferletResources(name: "chat-apc", version: "0.1.0")
    return LaunchSpecResolver(
      profileStore: store,
      pieBinary: { ignored },
      modelsRoot: { modelsRoot },
      inferletsDir: { self.tempDir.appendingPathComponent("inferlets") },
      pieControlResources: { resources },
      pieHome: { self.tempDir },
      subprocessEnvironment: { [:] },
      // Pin the daemon bind mode: the default reads the machine-global
      // `persistedLocalAPIBindMode()` file, which other tests in the same
      // process mutate. The snapshot now carries `daemonBindHost`, so an
      // unpinned read would make route-convergence assertions flaky.
      daemonBindMode: { .loopback }
    )
  }

  /// Poll `host.status` until it is `.running` on `port` for profile "chat",
  /// or `deadline` elapses. Matches on the snapshot's identity (port +
  /// profileID), not full snapshot equality — the host-produced snapshot also
  /// carries a live generation + served-model id the caller doesn't pin.
  /// Bounded so a regression can't hang the suite.
  private func pollHostUntilRunning(_ host: PieEngineHost,
                                    port: EnginePort,
                                    deadline seconds: TimeInterval) async throws {
    func runningOnPort(_ status: EngineStatus) -> Bool {
      if case .running(let snap) = status { return snap.port == port && snap.profileID == "chat" }
      return false
    }
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      if runningOnPort(host.status) { return }
      try await Task.sleep(nanoseconds: 30_000_000)
    }
    XCTAssertTrue(runningOnPort(host.status),
                  "engine never reached .running(port: \(port), profileID: chat) within \(seconds)s (got \(host.status))")
  }

  /// Trivial `EngineSession` that records nothing; the XPC tests
  /// only need the host to reach `.running` and accept `.stop()`
  /// later. `PieEngineHostTests` covers shutdown invocation.
  private final class FakeSession: PieEngineHost.EngineSession, @unchecked Sendable {
    func shutdown() async -> EngineShutdownResult { .reaped }
  }

  /// Async bridge over `startEngine(profileID:reply:)`. Throws
  /// `XPCError.engine` on the error slot, `XPCError.replyTimeout` on
  /// a wedged supervisor, `XPCError.wireShape` on a malformed reply.
  private func callStartEngine(api: PieHelperXPC,
                               profileID: String,
                               timeout: TimeInterval) async throws -> EnginePort {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<EnginePort, Error>) in
      let resumed = ResumedOnceFlag()
      let timer = DispatchSource.makeTimerSource(queue: .global())
      timer.schedule(deadline: .now() + timeout)
      timer.setEventHandler {
        if resumed.markIfPending() {
          cont.resume(throwing: XPCError.replyTimeout(timeout: timeout))
        }
      }
      timer.resume()

      api.startEngine(profileID: profileID, modelOverride: nil) { successData, errorData in
        timer.cancel()
        guard resumed.markIfPending() else { return }
        do {
          let result = try PieHelperXPCWire.decodeStartEngineReply(
            successData: successData, errorData: errorData
          )
          switch result {
          case .success(let snapshot): cont.resume(returning: snapshot.port)
          case .failure(let err):      cont.resume(throwing: XPCError.engine(err))
          }
        } catch {
          cont.resume(throwing: XPCError.wireShape(underlying: error))
        }
      }
    }
  }

  /// Async bridge that returns the FULL `EngineSessionSnapshot` from a
  /// `startEngine` / `restartEngine` reply (#476) — lets the snapshot-contract
  /// tests assert servedModelID / maxOutputTokens / generation, not just the
  /// port. `restart == true` exercises the strict rebuild selector.
  private func callStartEngineSnapshot(api: PieHelperXPC,
                                       profileID: String,
                                       modelOverride: String? = nil,
                                       restart: Bool = false,
                                       timeout: TimeInterval) async throws -> EngineSessionSnapshot {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<EngineSessionSnapshot, Error>) in
      let resumed = ResumedOnceFlag()
      let timer = DispatchSource.makeTimerSource(queue: .global())
      timer.schedule(deadline: .now() + timeout)
      timer.setEventHandler {
        if resumed.markIfPending() {
          cont.resume(throwing: XPCError.replyTimeout(timeout: timeout))
        }
      }
      timer.resume()

      let handler: (Data?, Data?) -> Void = { successData, errorData in
        timer.cancel()
        guard resumed.markIfPending() else { return }
        do {
          let result = try PieHelperXPCWire.decodeStartEngineReply(
            successData: successData, errorData: errorData
          )
          switch result {
          case .success(let snapshot): cont.resume(returning: snapshot)
          case .failure(let err):      cont.resume(throwing: XPCError.engine(err))
          }
        } catch {
          cont.resume(throwing: XPCError.wireShape(underlying: error))
        }
      }
      if restart {
        api.restartEngine(profileID: profileID, modelOverride: modelOverride, reply: handler)
      } else {
        api.startEngine(profileID: profileID, modelOverride: modelOverride, reply: handler)
      }
    }
  }

  /// Async bridge over `quitHelper(reply:)`. Resolves on a nil (accepted)
  /// reply, throws `XPCError.engine` on a non-nil error payload.
  private func callQuitHelper(api: PieHelperXPC,
                              timeout: TimeInterval) async throws {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
      let resumed = ResumedOnceFlag()
      let timer = DispatchSource.makeTimerSource(queue: .global())
      timer.schedule(deadline: .now() + timeout)
      timer.setEventHandler {
        if resumed.markIfPending() {
          cont.resume(throwing: XPCError.replyTimeout(timeout: timeout))
        }
      }
      timer.resume()
      api.quitHelper { errorData in
        timer.cancel()
        guard resumed.markIfPending() else { return }
        guard let errorData else { cont.resume(returning: ()); return }
        do {
          let err = try XPCPayload.decode(EngineError.self, from: errorData)
          cont.resume(throwing: XPCError.engine(err))
        } catch {
          cont.resume(throwing: XPCError.wireShape(underlying: error))
        }
      }
    }
  }

  private func callEngineStatus(api: PieHelperXPC,
                                timeout: TimeInterval) async throws -> EngineStatus {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<EngineStatus, Error>) in
      let resumed = ResumedOnceFlag()
      let timer = DispatchSource.makeTimerSource(queue: .global())
      timer.schedule(deadline: .now() + timeout)
      timer.setEventHandler {
        if resumed.markIfPending() {
          cont.resume(throwing: XPCError.replyTimeout(timeout: timeout))
        }
      }
      timer.resume()

      api.engineStatus { data in
        timer.cancel()
        guard resumed.markIfPending() else { return }
        do {
          cont.resume(returning: try XPCPayload.decode(EngineStatus.self, from: data))
        } catch {
          cont.resume(throwing: XPCError.wireShape(underlying: error))
        }
      }
    }
  }
}

/// Local error shape so the test can assert against a specific cause
/// instead of opaque NSError messages.
private enum XPCError: Error, CustomStringConvertible {
  case engine(EngineError)
  case replyTimeout(timeout: TimeInterval)
  case wireShape(underlying: Error)

  var description: String {
    switch self {
    case .engine(let e): return "engine error: \(e.code.rawValue) — \(e.message)"
    case .replyTimeout(let t): return "startEngine reply did not arrive within \(t)s"
    case .wireShape(let u): return "wire decode failed: \(u)"
    }
  }
}

private final class ResumedOnceFlag {
  private var resumed = false
  private let lock = NSLock()
  func markIfPending() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if resumed { return false }
    resumed = true
    return true
  }
}
