import XCTest
import Foundation
@testable import RatioThinkCore

/// #326 merge-checklist E2E: the FULL fresh-install recovery loop on a
/// REAL engine, with NO mock and NO `PIE_TEST_ENGINE_BASE_URL` bypass
/// (that bypass would skip the exact `startEngine(profileID:)` transition
/// under test).
///
/// Exercises the production #326 path end to end:
///   1. Fresh install — an empty models root, the seeded default profile,
///      and the model NOT on disk (the no-model / failed(modelMissing)
///      condition).
///   2. REAL download — the App's `ModelDownloader` fetches the seeded
///      default GGUF (coordinates derived via `CuratedModelCatalog
///      .downloadTarget`, the #326 mapping) into the resolver's path.
///   3. Auto-start — the App's real `HelperXPCClient` +
///      `EngineStatusStore.startEngine(profileID:)` drive a real
///      `HelperExportedAPI` (real `PieEngineHost`, default launcher) over
///      a real `NSXPCConnection`, then the status poll observes
///      `EngineStatus.running`.
///   4. Chat — `/v1/models` advertises the profile slug and an HTTP chat
///      completion returns a non-empty reply.
///
/// Gated on the bundled `pie` binary + chat-apc resources (and network
/// for the download); CI without them skips. Driven by
/// `Scripts/run-ticket326-e2e.sh`, which sets `PIE_TEST_MODE=1` (so the
/// anonymous listener accepts an unsigned caller) and exports:
///   · PIE_TEST_REAL_PIE_BIN          — the bundled `pie` engine binary
///   · PIE_TEST_REAL_CHATAPC_WASM     — chat-apc.wasm
///   · PIE_TEST_REAL_CHATAPC_MANIFEST — chat-apc Pie.toml
@MainActor
final class S326FreshInstallDownloadE2ETests: XCTestCase {
  private var tempDir: URL!
  /// Short `/tmp`-anchored pieHome so the engine's aux Unix socket stays
  /// under the 104-char `sun_path` limit (mirrors RealEngineLaunchE2ETests).
  private var shortPieHome: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    let uuid = UUID().uuidString.prefix(8).lowercased()
    tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("pie-s326-e2e-\(uuid)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    shortPieHome = URL(fileURLWithPath: "/tmp/p326-\(uuid)", isDirectory: true)
    try FileManager.default.createDirectory(at: shortPieHome, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    if let shortPieHome { try? FileManager.default.removeItem(at: shortPieHome) }
    tempDir = nil
    shortPieHome = nil
    try super.tearDownWithError()
  }

  func test_freshInstall_download_startEngine_running_chat() async throws {
    let env = ProcessInfo.processInfo.environment
    func require(_ key: String) throws -> String {
      guard let v = env[key], !v.isEmpty else {
        throw XCTSkip("\(key) not set — run Scripts/run-ticket326-e2e.sh (sets PIE_TEST_MODE + the bundled pie binary + chat-apc resources)")
      }
      return v
    }
    let pieBin = URL(fileURLWithPath: try require("PIE_TEST_REAL_PIE_BIN"))
    let wasm = URL(fileURLWithPath: try require("PIE_TEST_REAL_CHATAPC_WASM"))
    let manifest = URL(fileURLWithPath: try require("PIE_TEST_REAL_CHATAPC_MANIFEST"))
    let fm = FileManager.default
    XCTAssertTrue(fm.isExecutableFile(atPath: pieBin.path), "pie binary missing/!exec at \(pieBin.path)")
    XCTAssertTrue(fm.fileExists(atPath: wasm.path), "chat-apc wasm missing at \(wasm.path)")
    XCTAssertTrue(fm.fileExists(atPath: manifest.path), "chat-apc manifest missing at \(manifest.path)")

    // ---- Step 1: fresh-install condition ---------------------------------
    let modelsRoot = tempDir.appendingPathComponent("models", isDirectory: true)
    try fm.createDirectory(at: modelsRoot, withIntermediateDirectories: true)
    let slug = ProfileStore.defaultChatModelID
    let resolverPath = LaunchSpecResolver.joinModelPath(modelsRoot: modelsRoot, slug: slug)
    XCTAssertFalse(fm.fileExists(atPath: resolverPath),
                   "fresh-install precondition: the seeded model must NOT be staged before the test (\(resolverPath))")

    // ---- Step 2: REAL download via the App's ModelDownloader -------------
    let target = try XCTUnwrap(CuratedModelCatalog.downloadTarget(forModelSlug: slug),
                               "the seeded default slug must map to a download target (#326)")
    NSLog("S326-E2E: downloading \(target.repo)/\(target.file) → \(modelsRoot.path)")
    let downloader = ModelDownloader(modelsRoot: { modelsRoot })
    let handle: DownloadHandle
    switch downloader.start(repo: target.repo, file: target.file) {
    case .success(let h): handle = h
    case .failure(let e): return XCTFail("ModelDownloader.start failed: \(e)")
    }
    var lastPhase: DownloadProgress.Phase = .starting
    let downloadDeadline = Date().addingTimeInterval(600)
    for await progress in downloader.progress(for: handle) {
      lastPhase = progress.phase
      switch progress.phase {
      case .completed:
        NSLog("S326-E2E: download completed (verification=\(String(describing: progress.verification)))")
      case .failed:
        return XCTFail("download failed: \(progress.failureReason ?? "no reason")")
      case .cancelled:
        return XCTFail("download cancelled unexpectedly")
      case .starting, .downloading, .verifying:
        break
      }
      if progress.phase.isTerminal { break }
      if Date() > downloadDeadline {
        return XCTFail("download did not complete within 600s (last phase=\(lastPhase))")
      }
    }
    XCTAssertEqual(lastPhase, .completed, "download must finish in the .completed phase")
    XCTAssertTrue(fm.fileExists(atPath: resolverPath),
                  "the real download must land at the exact resolver path \(resolverPath)")

    // ---- profile + active marker ----------------------------------------
    let profiles = tempDir.appendingPathComponent("profiles", isDirectory: true)
    try fm.createDirectory(at: profiles, withIntermediateDirectories: true)
    try """
    id = "chat"
    name = "Chat"
    model = "\(slug)"
    inferlet = "chat-apc"
    """.write(to: profiles.appendingPathComponent("chat.toml"), atomically: true, encoding: .utf8)
    let store = ProfileStore(
      directory: profiles,
      activeProfileURL: tempDir.appendingPathComponent("active-profile", isDirectory: false)
    )
    try store.start()
    try store.setActiveProfileID("chat")
    defer { store.stop() }

    // ---- real resolver + real PieEngineHost behind an anonymous listener -
    let resolver = LaunchSpecResolver(
      profileStore: store,
      pieBinary: { pieBin },
      modelsRoot: { modelsRoot },
      inferletsDir: { self.tempDir.appendingPathComponent("inferlets") },
      pieControlResources: { (wasm: wasm, manifest: manifest) },
      pieHome: { self.shortPieHome },
      subprocessEnvironment: { SpawnEnvSanitizer.sanitize(env) }
    )
    let host = PieEngineHost()
    defer { host.stop() }
    let exported = HelperExportedAPI(engineHost: host, launchSpecResolver: resolver.asClosure)
    let listenerOwner = HelperXPCListener.startAnonymous(exportedObject: exported)
    defer { listenerOwner.invalidate() }

    // ---- Step 3: the #326 App path — HelperXPCClient + EngineStatusStore -
    let client = HelperXPCClient(endpoint: .listenerEndpoint(listenerOwner.endpoint))
    let statusStore = EngineStatusStore(client: client)
    // Kick the start exactly as ChatScaffoldView does after a download.
    // EngineStatusStore.startEngine swallows the reply-timeout (the helper
    // only replies after the launch handshake). Same-profile idempotency is
    // handled inside HelperExportedAPI/PieEngineHost.startOrAttach; any
    // .alreadyRunning that reaches the app is an incompatible-start conflict.
    try await statusStore.startEngine(profileID: "chat")

    // Poll engineStatus over the real XPC wire until .running (model load +
    // Metal init can take ~10-30s cold), failing fast on .failed.
    var port = 0
    let runningDeadline = Date().addingTimeInterval(120)
    while Date() < runningDeadline {
      let status = try await statusStore.refresh()
      if case .running(let p, _) = status {
        port = Int(p)
        break
      }
      if case .failed(let code, let message) = status {
        return XCTFail("engine entered .failed(\(code.rawValue)) after startEngine: \(message)")
      }
      try await Task.sleep(nanoseconds: 250_000_000)
    }
    XCTAssertGreaterThan(port, 0, "engine must reach .running after the download + startEngine (#326 auto-start)")

    // ---- Step 4: served-id + chat completion ----------------------------
    try await Self.assertServedModelID(port: port, expected: slug)
    try await Self.assertChatCompletion(port: port, modelID: slug)
    NSLog("S326-E2E: PASS — fresh-install download → startEngine → running(port \(port)) → chat completion")
  }

  // MARK: - HTTP assertions (mirror RealEngineLaunchE2ETests)

  private static func assertServedModelID(port: Int, expected: String) async throws {
    let url = URL(string: "http://127.0.0.1:\(port)/v1/models")!
    let (data, response) = try await URLSession.shared.data(from: url)
    let http = try XCTUnwrap(response as? HTTPURLResponse)
    XCTAssertEqual(http.statusCode, 200, "/v1/models HTTP \(http.statusCode): \(String(data: data, encoding: .utf8) ?? "")")
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let ids = (json?["data"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
    XCTAssertEqual(ids, [expected],
                   "engine must advertise the profile slug as its served id; got \(ids)")
  }

  private static func assertChatCompletion(port: Int, modelID: String) async throws {
    let url = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.timeoutInterval = 120
    // The seeded default (Qwen3-0.6B) is a REASONING model — it emits a
    // <think>…</think> block before visible content. A tiny budget is
    // spent entirely inside reasoning, leaving content empty, so allow
    // enough tokens for it to finish thinking AND answer (matches the
    // real-Qwen3 reasoning-e2e budget from the </think>-leak work).
    req.httpBody = try JSONSerialization.data(withJSONObject: [
      "model": modelID,
      "messages": [["role": "user", "content": "Reply with the single word: pong"]],
      "max_tokens": 2048,
      "stream": false,
    ])
    let (data, response) = try await URLSession.shared.data(for: req)
    let http = try XCTUnwrap(response as? HTTPURLResponse)
    XCTAssertEqual(http.statusCode, 200, "chat completion HTTP \(http.statusCode): \(String(data: data, encoding: .utf8) ?? "")")
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let choices = json?["choices"] as? [[String: Any]]
    let content = (choices?.first?["message"] as? [String: Any])?["content"] as? String
    XCTAssertNotNil(content, "engine reply missing choices[0].message.content: \(String(data: data, encoding: .utf8) ?? "")")
    let trimmed = (content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    XCTAssertFalse(trimmed.isEmpty, "engine returned an empty assistant message")
    // Halt before the caller's success log if the reply is empty, so the
    // evidence never shows a spurious PASS after a recorded failure.
    if trimmed.isEmpty { throw E2EChatError.emptyReply }
    NSLog("S326-E2E: chat reply = \(trimmed.prefix(120))")
  }
}

private enum E2EChatError: Error { case emptyReply }
