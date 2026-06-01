import XCTest
import Foundation
@testable import RatioThinkCore

/// REAL end-to-end Helper-hosted engine launch ( follow-up).
///
/// Every other tier skips the actual engine spawn:
///   · StartEngineXPCIntegrationTests injects a synthetic launcher.
///   · The  full-e2e boots `pie` in the harness and points the GUI
///     at it via `PIE_TEST_ENGINE_BASE_URL` (bypass).
///
/// This drives the PRODUCTION path with NO mock: a real
/// `LaunchSpecResolver` reading a staged profile → `PieEngineHost()`
/// with the default launcher (`PieControlLauncher.launch`) → a real
/// `pie serve` subprocess loading a real GGUF → `EngineStatus.running`,
/// then an HTTP chat round-trip against the engine the Helper would
/// spawn. Closes the gap that hid the  model-load hang (engine
/// never started; nothing exercised the spawn).
///
/// Gated on a staged model + bundled binary so CI without them skips.
/// Driven by `Scripts/run-engine-e2e.sh`, which stages the
/// GGUF and exports:
///   · PIE_TEST_REAL_PIE_BIN          — the bundled `pie` engine binary
///   · PIE_TEST_REAL_MODEL_PATH       — a real .gguf on disk
///   · PIE_TEST_REAL_CHATAPC_WASM     — chat-apc.wasm
///   · PIE_TEST_REAL_CHATAPC_MANIFEST — chat-apc Pie.toml
///
/// Isolation: subclasses `IsolatedTestCase` (not bare `XCTestCase`) so the
/// real `pie serve` it spawns is registered via `trackSubprocess(_:)` and
/// SIGKILL-reaped by the base's post-test reap loop even if the body throws
/// or `host.stop()` (async, fire-and-forget) hasn't finished — the same
/// safety net S0/S3 rely on. A hung engine no longer leaks into the next
/// test or the developer's machine.
final class RealEngineLaunchE2ETests: IsolatedTestCase {
  /// Short `/tmp`-anchored pieHome so the engine's aux Unix socket path
  /// stays under the 104-char `sun_path` limit (see resolver wiring).
  /// Deliberately NOT the base `tempPieHome` (which lives under the deep
  /// `NSTemporaryDirectory()` /var/folders root): only the engine's
  /// PIE_HOME carries the length-bounded socket, so the models/profiles
  /// scratch stays under `tempPieHome` while the engine gets this.
  private var shortPieHome: URL!

  override func setUpWithError() throws {
    // super first: IsolatedTestCase.invokeTest already allocated
    // `tempPieHome` and bound `PieDirs.homeOverride` to it; super's setUp
    // precondition verifies that binding. Only the short engine pieHome
    // is ours to create.
    try super.setUpWithError()
    let uuid = UUID().uuidString.prefix(8).lowercased()
    shortPieHome = URL(fileURLWithPath: "/tmp/pe2e-\(uuid)", isDirectory: true)
    try FileManager.default.createDirectory(at: shortPieHome, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    // Best-effort: races the async `host.stop()` shutdown, but POSIX
    // unlink succeeds even while the engine still holds fds, and the
    // wrapper's EXIT sweep (Scripts/run-engine-e2e.sh) is the
    // deterministic outer net for an externally-killed bundle. The
    // base's verified `cleanupTempPieHome()` (runs post-reap in
    // invokeTest) owns `tempPieHome`.
    if let shortPieHome { try? FileManager.default.removeItem(at: shortPieHome) }
    shortPieHome = nil
    try super.tearDownWithError()
  }

  func test_realEngine_startsServesAndStops() async throws {
    let env = ProcessInfo.processInfo.environment
    func require(_ key: String) throws -> String {
      guard let v = env[key], !v.isEmpty else {
        throw XCTSkip("\(key) not set — run Scripts/run-engine-e2e.sh (stages a GGUF + the bundled pie binary)")
      }
      return v
    }
    let pieBin = URL(fileURLWithPath: try require("PIE_TEST_REAL_PIE_BIN"))
    let modelPath = URL(fileURLWithPath: try require("PIE_TEST_REAL_MODEL_PATH"))
    let wasm = URL(fileURLWithPath: try require("PIE_TEST_REAL_CHATAPC_WASM"))
    let manifest = URL(fileURLWithPath: try require("PIE_TEST_REAL_CHATAPC_MANIFEST"))
    let fm = FileManager.default
    XCTAssertTrue(fm.isExecutableFile(atPath: pieBin.path), "pie binary missing/!exec at \(pieBin.path)")
    XCTAssertTrue(fm.fileExists(atPath: modelPath.path), "model missing at \(modelPath.path)")

    // Stage a models root containing the GGUF (the slug is the leaf
    // filename, matching the resolver's flat-slug join) + a profile
    // pointing at it. Symlink so we don't copy ~500 MB per run.
    let modelsRoot = tempPieHome.appendingPathComponent("models", isDirectory: true)
    try fm.createDirectory(at: modelsRoot, withIntermediateDirectories: true)
    let slug = modelPath.lastPathComponent
    let staged = modelsRoot.appendingPathComponent(slug, isDirectory: false)
    try? fm.removeItem(at: staged)
    // The resolver requires a regular file (rejects symlinks as an
    // anti-symlink-attack guard), so hardlink when possible (same
    // volume, no copy) and fall back to a full copy across volumes.
    do {
      try fm.linkItem(at: modelPath, to: staged)
    } catch {
      try fm.copyItem(at: modelPath, to: staged)
    }

    let profiles = tempPieHome.appendingPathComponent("profiles", isDirectory: true)
    try fm.createDirectory(at: profiles, withIntermediateDirectories: true)
    try """
    id = "chat"
    name = "Chat"
    model = "\(slug)"
    inferlet = "chat-apc"
    """.write(to: profiles.appendingPathComponent("chat.toml"), atomically: true, encoding: .utf8)
    let store = ProfileStore(
      directory: profiles,
      activeProfileURL: tempPieHome.appendingPathComponent("active-profile", isDirectory: false)
    )
    try store.start()
    try store.setActiveProfileID("chat")
    defer { store.stop() }

    // Real resolver → real launcher (no PieEngineHost launcher override).
    let resolver = LaunchSpecResolver(
      profileStore: store,
      pieBinary: { pieBin },
      modelsRoot: { modelsRoot },
      inferletsDir: { self.tempPieHome.appendingPathComponent("inferlets") },
      pieControlResources: { (wasm: wasm, manifest: manifest) },
      // The engine binds an aux Unix-domain socket under
      // <pieHome>/standalone/<pid>/g0/aux.sock, which must fit the
      // sun_path 104-char limit. NSTemporaryDirectory() (/var/folders/…)
      // is far too deep, so anchor pieHome at a short /tmp path. (:
      // production's ~/Library/Application Support/RatioThink is short enough.)
      pieHome: { self.shortPieHome },
      subprocessEnvironment: { SpawnEnvSanitizer.sanitize(ProcessInfo.processInfo.environment) }
    )
    var spec: PieControlLauncher.LaunchSpec
    switch resolver.asClosure("chat") {
    case .success(let s): spec = s
    case .failure(let e): return XCTFail("resolver rejected chat profile: \(e.code.rawValue): \(e.message)")
    }
    // Register the about-to-be-spawned `pie serve` pid with the
    // IsolatedTestCase reap net so a hung engine is SIGKILL-reaped after
    // the test even if the body throws or `host.stop()` (async) hasn't
    // run. The resolver leaves `pidSink` nil; this is the sole sink.
    reapEngineSubprocess(in: &spec)

    let host = PieEngineHost()
    defer { host.stop() }
    if case .failure(let e) = host.start(spec) {
      return XCTFail("engineHost.start rejected: \(e.code.rawValue): \(e.message)")
    }

    // Await .running (model load + Metal init can take ~10-30s cold).
    let port = try await awaitRunning(host: host, timeout: 120)
    XCTAssertGreaterThan(port, 0, "engine must publish a real port")

    // Engine is genuinely serving: HTTP chat round-trip. The served id
    // must be the profile slug (id-unification,  follow-up) — assert
    // /v1/models advertises it, then chat against that exact id.
    try await assertServedModelID(port: port, expected: slug)
    try await assertChatCompletion(port: port, modelID: slug)
  }

  /// Poll the host until it reports `.running`, failing fast on `.failed`.
  private func awaitRunning(host: PieEngineHost, timeout: TimeInterval) async throws -> Int {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      switch host.status {
      case .running(let port, _):
        return Int(port)
      case .failed(let code, let message):
        XCTFail("engine entered .failed(\(code.rawValue)): \(message)")
        return 0
      default:
        try await Task.sleep(nanoseconds: 250_000_000)
      }
    }
    XCTFail("engine did not reach .running within \(timeout)s (last status=\(host.status))")
    return 0
  }

  /// Assert `/v1/models` advertises exactly the profile slug as the
  /// served id. This is the wire-level proof of the id-unification fix:
  /// the engine no longer serves a hardcoded "default", so a client that
  /// sends the profile slug (as the App does on every path) matches.
  private func assertServedModelID(port: Int, expected: String) async throws {
    let url = URL(string: "http://127.0.0.1:\(port)/v1/models")!
    let (data, response) = try await URLSession.shared.data(from: url)
    let http = try XCTUnwrap(response as? HTTPURLResponse)
    XCTAssertEqual(http.statusCode, 200, "/v1/models HTTP \(http.statusCode): \(String(data: data, encoding: .utf8) ?? "")")
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let ids = (json?["data"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
    XCTAssertEqual(ids, [expected],
                   "engine must advertise the profile slug as its served id (not \"default\"); got \(ids)")
  }

  /// Hit the engine's OpenAI-compatible chat endpoint and assert a
  /// non-empty assistant reply — proves the model is loaded and serving,
  /// not just that the port is bound. `modelID` must be the served id
  /// (the profile slug) so the request matches chat-apc's registered
  /// model and does not 404 as `model_not_found`.
  private func assertChatCompletion(port: Int, modelID: String) async throws {
    let url = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.timeoutInterval = 90
    req.httpBody = try JSONSerialization.data(withJSONObject: [
      "model": modelID,
      "messages": [["role": "user", "content": "Reply with the single word: pong"]],
      "max_tokens": 16,
      "stream": false,
    ])
    let (data, response) = try await URLSession.shared.data(for: req)
    let http = try XCTUnwrap(response as? HTTPURLResponse)
    XCTAssertEqual(http.statusCode, 200, "chat completion HTTP \(http.statusCode): \(String(data: data, encoding: .utf8) ?? "")")
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let choices = json?["choices"] as? [[String: Any]]
    let content = (choices?.first?["message"] as? [String: Any])?["content"] as? String
    XCTAssertNotNil(content, "engine reply missing choices[0].message.content: \(String(data: data, encoding: .utf8) ?? "")")
    XCTAssertFalse((content ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   "engine returned an empty assistant message")
  }

  // MARK: - pid-reap wiring

  /// Route the about-to-be-spawned `pie serve` pid into the
  /// `IsolatedTestCase` reap net. Factored out of the launch body so the
  /// wiring is verifiable engine-free
  /// (`test_reapEngineSubprocess_wires_pid_into_reap_net`); the gated
  /// real-engine test only runs on a host with a staged model + binary.
  private func reapEngineSubprocess(in spec: inout PieControlLauncher.LaunchSpec) {
    spec.pidSink = { [weak self] pid in self?.trackSubprocess(pid) }
  }

  /// Engine-free regression guard for the pid-reap wiring. Subclassing
  /// `IsolatedTestCase` only helps if the spawned pid actually reaches
  /// `trackSubprocess(_:)`, so assert the seam forwards it. A real
  /// `/bin/sleep` stands in for the engine: the base reap loop SIGKILLs +
  /// waitpids it post-test, so there is no manual cleanup and no leak —
  /// the same pattern as `IsolatedTestCaseTests`' reap check.
  func test_reapEngineSubprocess_wires_pid_into_reap_net() throws {
    let sleeper = Process()
    sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
    sleeper.arguments = ["60"]
    try sleeper.run()

    var spec = try makeDummyLaunchSpec()
    XCTAssertNil(spec.pidSink, "precondition: a fresh spec has no pidSink")
    reapEngineSubprocess(in: &spec)
    XCTAssertNotNil(spec.pidSink, "reapEngineSubprocess must install a pidSink")

    let before = trackedSubprocessCountForTesting
    spec.pidSink?(sleeper.processIdentifier)
    XCTAssertEqual(trackedSubprocessCountForTesting, before + 1,
                   "the spec's pidSink must forward the spawned pid into the IsolatedTestCase reap net")
    // No teardown: the base reap loop SIGKILL + waitpids the sleeper.
  }

  /// Minimal `.dummy` LaunchSpec for the engine-free wiring test.
  /// `.dummy` skips PieControlLauncher's driver-capability probe, so the
  /// throwaway binary/resource paths need not exist on disk.
  private func makeDummyLaunchSpec() throws -> PieControlLauncher.LaunchSpec {
    try PieControlLauncher.LaunchSpec(
      pieBinary: tempPieHome.appendingPathComponent("pie"),
      wasmURL: tempPieHome.appendingPathComponent("chat-apc.wasm"),
      manifestURL: tempPieHome.appendingPathComponent("Pie.toml"),
      subprocessEnvironment: subprocessEnvironment,
      pieHome: tempPieHome,
      shmemName: shmemName,
      modelConfig: .dummy
    )
  }
}
