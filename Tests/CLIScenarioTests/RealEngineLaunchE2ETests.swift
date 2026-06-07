import XCTest
import Foundation
import Darwin
import os
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
    // When driven by Scripts/run-engine-e2e.sh, anchor under the wrapper's
    // per-run id (`/tmp/pe2e-<runID>-<uuid>`) so its EXIT sweep can scope
    // its `rm` to THIS run's pieHomes and never delete a concurrent run's
    // (or a still-live bundle's) live engine home. Plain `swift test` (no
    // PE2E_RUN_ID) keeps the flat `/tmp/pe2e-<uuid>` form. The run id is
    // the wrapper's PID — digits only, so it stays sun_path-short and
    // regex-safe for the wrapper's scoped pkill.
    let runID = ProcessInfo.processInfo.environment["PE2E_RUN_ID"]
      .flatMap { $0.isEmpty ? nil : $0 }
    let leaf = runID.map { "pe2e-\($0)-\(uuid)" } ?? "pe2e-\(uuid)"
    shortPieHome = URL(fileURLWithPath: "/tmp/\(leaf)", isDirectory: true)
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
    let env = try realEngineEnvOrSkip()
    let host = PieEngineHost()
    defer { host.stop() }
    let (port, slug) = try await launchRealEngine(env, host: host)

    // Engine is genuinely serving: HTTP chat round-trip. The served id
    // must be the profile slug (id-unification,  follow-up) — assert
    // /v1/models advertises it, then chat against that exact id.
    try await assertServedModelID(port: port, expected: slug)
    try await assertChatCompletion(port: port, modelID: slug)
  }

  /// Real-model proof for the reasoning-channel split: a thinking model
  /// (Qwen3) must keep raw `<think>`/`</think>` delimiters OFF the
  /// visible-content channel and surface the scratchpad on
  /// `reasoning_content` instead. Gated behind
  /// `PIE_TEST_REAL_EXPECT_REASONING=1` so the model-agnostic suite
  /// (Qwen2.5 etc.) doesn't run it — a non-thinking model has no
  /// reasoning to assert on. Drive with:
  ///   PIE_TEST_REAL_EXPECT_REASONING=1 \
  ///   PIE_TEST_E2E_REPO=Qwen/Qwen3-0.6B-GGUF \
  ///   PIE_TEST_E2E_FILE=Qwen3-0.6B-Q8_0.gguf  Scripts/run-engine-e2e.sh
  func test_realEngine_keepsThinkDelimitersOffContentChannel() async throws {
    let env = try realEngineEnvOrSkip()
    guard ProcessInfo.processInfo.environment["PIE_TEST_REAL_EXPECT_REASONING"] == "1" else {
      throw XCTSkip("set PIE_TEST_REAL_EXPECT_REASONING=1 with a thinking model (e.g. Qwen3) to run")
    }
    let host = PieEngineHost()
    defer { host.stop() }
    let (port, slug) = try await launchRealEngine(env, host: host)
    try await assertReasoningSeparatedFromContent(port: port, modelID: slug)
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

  /// Drive a real thinking-model completion and assert the
  /// `<think>`/`</think>` delimiters never reach `message.content`, while
  /// the scratchpad arrives on `message.reasoning_content`. Non-streaming
  /// for a single deterministic JSON to inspect. A generous `max_tokens`
  /// gives Qwen3 room to finish its reasoning chain; even if it caps
  /// before the answer, the delimiter-free + reasoning-present invariant
  /// still holds (reasoning streams first).
  private func assertReasoningSeparatedFromContent(port: Int, modelID: String) async throws {
    let url = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.timeoutInterval = 180
    req.httpBody = try JSONSerialization.data(withJSONObject: [
      "model": modelID,
      "messages": [["role": "user", "content": "What is 2 + 2? Think briefly, then answer."]],
      "max_tokens": 4096,
      "stream": false,
    ])
    let (data, response) = try await URLSession.shared.data(for: req)
    let http = try XCTUnwrap(response as? HTTPURLResponse)
    let bodyText = String(data: data, encoding: .utf8) ?? ""
    XCTAssertEqual(http.statusCode, 200, "chat HTTP \(http.statusCode): \(bodyText)")
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let message = (json?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
    let content = (message?["content"] as? String) ?? ""
    let reasoning = (message?["reasoning_content"] as? String) ?? ""

    // Core acceptance: no raw delimiter in the visible answer.
    XCTAssertFalse(content.contains("</think>"), "raw </think> leaked into content: \(content.debugDescription)")
    XCTAssertFalse(content.contains("<think>"), "raw <think> leaked into content: \(content.debugDescription)")
    // Separation actually engaged: the thinking model routed its
    // scratchpad to the reasoning channel, not into content.
    XCTAssertFalse(reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   "expected non-empty reasoning_content for a thinking model; body=\(bodyText.prefix(400))")
    XCTAssertFalse(reasoning.contains("</think>"),
                   "reasoning_content must hold clean scratchpad text, not the delimiter")
  }

  // MARK: - launch helper

  private struct RealEngineEnv {
    let pieBin: URL
    let modelPath: URL
    let wasm: URL
    let manifest: URL
  }

  private func realEngineEnvOrSkip() throws -> RealEngineEnv {
    let env = ProcessInfo.processInfo.environment
    func require(_ key: String) throws -> String {
      guard let v = env[key], !v.isEmpty else {
        throw XCTSkip("\(key) not set — run Scripts/run-engine-e2e.sh (stages a GGUF + the bundled pie binary)")
      }
      return v
    }
    let e = RealEngineEnv(
      pieBin: URL(fileURLWithPath: try require("PIE_TEST_REAL_PIE_BIN")),
      modelPath: URL(fileURLWithPath: try require("PIE_TEST_REAL_MODEL_PATH")),
      wasm: URL(fileURLWithPath: try require("PIE_TEST_REAL_CHATAPC_WASM")),
      manifest: URL(fileURLWithPath: try require("PIE_TEST_REAL_CHATAPC_MANIFEST"))
    )
    let fm = FileManager.default
    XCTAssertTrue(fm.isExecutableFile(atPath: e.pieBin.path), "pie binary missing/!exec at \(e.pieBin.path)")
    XCTAssertTrue(fm.fileExists(atPath: e.modelPath.path), "model missing at \(e.modelPath.path)")
    return e
  }

  /// Drives the PRODUCTION launch path (real `LaunchSpecResolver` →
  /// `PieEngineHost` → real `pie serve` subprocess) and returns once the
  /// engine reports `.running`. The caller owns `host` (and its
  /// `host.stop()` defer) so the engine outlives this call. The spawned
  /// `pie serve` pid is routed into the `IsolatedTestCase` reap net via
  /// `reapEngineSubprocess(in:)` so a hung engine is SIGKILL-reaped
  /// post-test even if the body throws.
  private func launchRealEngine(
    _ e: RealEngineEnv,
    host: PieEngineHost
  ) async throws -> (port: Int, slug: String) {
    let fm = FileManager.default
    // Stage a models root containing the GGUF (the slug is the leaf
    // filename, matching the resolver's flat-slug join) + a profile
    // pointing at it. Hardlink so we don't copy ~500 MB per run.
    let modelsRoot = tempPieHome.appendingPathComponent("models", isDirectory: true)
    try fm.createDirectory(at: modelsRoot, withIntermediateDirectories: true)
    let slug = e.modelPath.lastPathComponent
    let staged = modelsRoot.appendingPathComponent(slug, isDirectory: false)
    try? fm.removeItem(at: staged)
    // The resolver requires a regular file (rejects symlinks as an
    // anti-symlink-attack guard), so hardlink when possible (same
    // volume, no copy) and fall back to a full copy across volumes.
    do {
      try fm.linkItem(at: e.modelPath, to: staged)
    } catch {
      try fm.copyItem(at: e.modelPath, to: staged)
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

    // Real resolver → real launcher (no PieEngineHost launcher override).
    let resolver = LaunchSpecResolver(
      profileStore: store,
      pieBinary: { e.pieBin },
      modelsRoot: { modelsRoot },
      inferletsDir: { self.tempPieHome.appendingPathComponent("inferlets") },
      pieControlResources: { (wasm: e.wasm, manifest: e.manifest) },
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
    case .failure(let err):
      store.stop()
      XCTFail("resolver rejected chat profile: \(err.code.rawValue): \(err.message)")
      throw XCTSkip("resolver failure")
    }
    // Register the about-to-be-spawned `pie serve` pid with the
    // IsolatedTestCase reap net so a hung engine is SIGKILL-reaped after
    // the test even if the body throws or `host.stop()` (async) hasn't
    // run. The resolver leaves `pidSink` nil; this is the sole sink.
    reapEngineSubprocess(in: &spec)
    // ProfileStore must outlive the launch; the engine has its config by
    // the time .running is reported, so stopping it after is safe.
    defer { store.stop() }

    if case .failure(let err) = host.start(spec) {
      XCTFail("engineHost.start rejected: \(err.code.rawValue): \(err.message)")
      throw XCTSkip("host start failure")
    }
    // Await .running (model load + Metal init can take ~10-30s cold).
    let port = try await awaitRunning(host: host, timeout: 120)
    XCTAssertGreaterThan(port, 0, "engine must publish a real port")
    return (port, slug)
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

  // MARK: - launch fires pidSink (engine-free production coverage)

  /// The seam test above proves `reapEngineSubprocess` installs a pidSink,
  /// but NOT that `PieControlLauncher.launch` actually FIRES it — the only
  /// tests that drive `launch()` -> pidSink (S0_TestIsolationTests,
  /// ScenarioBindings' S3) are `XCTSkipUnless`-gated on the pie binary, so
  /// every engine-free lane has zero coverage of that production call. A
  /// regression dropping the sink call would keep all default-lane tests
  /// green while the real-engine test silently leaked.
  ///
  /// Drive a real `launch()` against a tiny stub `pie` that emits the two
  /// handshake markers `awaitHandshake` waits on, with its advertised WS
  /// address pointed at a just-closed loopback port so the post-handshake
  /// control-plane install fails fast (ECONNREFUSED) — no real engine.
  /// Assert (a) the sink received the spawned pid, and (b) `launch` failed
  /// at the WS step (`.clientError`), which also pins the stub's marker
  /// strings against the launcher's `awaitHandshake` regexes: a drift
  /// would surface as `.handshakeTimeout` and fail (b).
  func test_launch_fires_pidSink_with_spawned_pid_engineFree() async throws {
    let deadPort = try Self.reserveClosedLoopbackPort()
    let stub = try writeStubPie(advertisedWSPort: deadPort)
    let captured = OSAllocatedUnfairLock<pid_t>(initialState: 0)

    let spec = try PieControlLauncher.LaunchSpec(
      pieBinary: stub,
      wasmURL: tempPieHome.appendingPathComponent("chat-apc.wasm"),
      manifestURL: tempPieHome.appendingPathComponent("Pie.toml"),
      subprocessEnvironment: subprocessEnvironment,
      pieHome: tempPieHome,
      shmemName: shmemName,
      handshakeTimeout: 5,
      pidSink: { pid in captured.withLock { $0 = pid } },
      modelConfig: .dummy
    )

    do {
      // Unreachable in practice (the dead WS port refuses the post-handshake
      // connect) — but if a future change ever let it succeed, shut the
      // session down so the stub subprocess can't leak.
      let (_, session) = try await PieControlLauncher.launch(spec: spec)
      _ = await session.shutdown()
      XCTFail("engine-free stub cannot complete the WS install; launch must throw")
    } catch let error as PieControlLauncher.LaunchError {
      guard case .clientError = error else {
        return XCTFail("expected .clientError (handshake passed, post-handshake WS install failed); got \(error) — stub markers may have drifted from PieControlLauncher.awaitHandshake")
      }
    }

    let pid = captured.withLock { $0 }
    XCTAssertGreaterThan(pid, 0,
                         "PieControlLauncher.launch must fire pidSink with the spawned pie pid — the production fact the hand-rolled seam test does not cover")
  }

  /// Write an executable stub mimicking `pie serve` only as far as
  /// `PieControlLauncher.awaitHandshake` reads: emit the serving-address
  /// line and the internal-token line (the exact two markers the launcher
  /// captures), then re-exec as `sleep` so the pid stays stable for the
  /// launcher's shutdown SIGINT. It runs no WS server, so the launcher's
  /// install step fails by design — after the pidSink has already fired.
  private func writeStubPie(advertisedWSPort port: UInt16) throws -> URL {
    let url = tempPieHome.appendingPathComponent("stub-pie")
    let script = """
    #!/bin/sh
    echo "pie-server serving on 127.0.0.1:\(port)"
    echo "internal token: stub-token-deadbeef"
    exec sleep 30
    """
    try script.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                          ofItemAtPath: url.path)
    return url
  }

  /// Bind 127.0.0.1:0, read the OS-assigned port, close the socket — so a
  /// later connect to that port fails fast with ECONNREFUSED. Mirrors the
  /// launcher's own `reserveFreePort`; gives the stub a dead WS port so
  /// `launch()`'s post-handshake connect fails without a real engine.
  /// (Same close->reuse race as the launcher; negligible on loopback for a
  /// single-shot test.)
  private static func reserveClosedLoopbackPort() throws -> UInt16 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw stubSocketError("socket", errno) }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    let bindRC = withUnsafePointer(to: &addr) { p in
      p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bindRC == 0 else { throw stubSocketError("bind", errno) }
    var out = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameRC = withUnsafeMutablePointer(to: &out) { p in
      p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(fd, $0, &len)
      }
    }
    guard nameRC == 0 else { throw stubSocketError("getsockname", errno) }
    return UInt16(bigEndian: out.sin_port)
  }

  private static func stubSocketError(_ call: String, _ err: Int32) -> NSError {
    NSError(domain: "RealEngineLaunchE2ETests.stub", code: Int(err),
            userInfo: [NSLocalizedDescriptionKey: "\(call) failed: \(String(cString: strerror(err)))"])
  }
}
