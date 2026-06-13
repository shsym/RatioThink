import XCTest
import Foundation
import RatioThinkCore

/// S0_TestIsolation — End-to-end verification that PieControlLauncher
/// satisfies the IsolatedTestCase contract from  §F7.
///
/// The launcher must:
///   1. Spawn `pie serve` under the test's ephemeral PIE_HOME +
///      PIE_SHMEM_NAME (so two concurrent invocations don't alias
///      `~/Library/Application Support/RatioThink/` or `/pie_shmem_*`).
///   2. Reserve an OS-picked HTTP port and write it to
///      `<PIE_HOME>/http.port` BEFORE the test reads it via
///      `IsolatedTestCase.boundHTTPPort()`.
///   3. Tear the engine subprocess down cleanly on shutdown so the
///      isolated /tmp dir can be rmdir'd.
///
/// What this test does NOT cover:
///   - Real driver bring-up (still uses dummy driver — deferred).
///   - Two concurrent IsolatedTestCase methods (XCTest serializes
///     within-bundle, the wrapper script refuses --parallel; the
///     setUpWithError precondition is the load-bearing guard).
///
/// Skipped when the pie binary or the bundled wasm is missing — the
/// scenario test target compiles even without the engine, which
/// matches the rest of CLIScenarioTests.
final class S0_TestIsolationTests: IsolatedTestCase {

  func test_launcher_brings_engine_up_and_boundHTTPPort_resolves() async throws {
    let pieURL = try discoverPieBinary()
    let resources = try discoverBundledInferletResources()

    let launcherSpec = try PieControlLauncher.LaunchSpec(
      pieBinary: pieURL,
      wasmURL: resources.wasm,
      manifestURL: resources.manifest,
      subprocessEnvironment: subprocessEnvironment,
      pieHome: tempPieHome,
      shmemName: shmemName,
      handshakeTimeout: 30,
      pidSink: { [weak self] pid in self?.trackSubprocess(pid) },
      modelConfig: .dummy
    )

    let (bound, session) = try await PieControlLauncher.launch(spec: launcherSpec)

    // Shutdown is idempotent — running it again from tearDown's
    // reap loop is safe.
    defer { Task { _ = await session.shutdown() } }

    let pollPort = try await boundHTTPPort(timeout: 5)
    XCTAssertEqual(Int(bound), pollPort,
                   "launcher returned port \(bound) but http.port resolved to \(pollPort) — the launcher's port-file write contract is broken")

    // /healthz proves the daemon actually bound and the chat-apc
    // inferlet installed. The dummy driver answers control-plane
    // requests; this is a structural check, not a model check.
    let url = URL(string: "http://127.0.0.1:\(pollPort)/healthz")!
    let (data, response) = try await urlSessionGET(url, timeout: 15)
    let http = try XCTUnwrap(response as? HTTPURLResponse,
                              "expected HTTPURLResponse for \(url)")
    XCTAssertEqual(http.statusCode, 200, "GET /healthz status; body=\(String(data: data, encoding: .utf8) ?? "<binary>")")
    let json = try JSONSerialization.jsonObject(with: data) as? [String: String]
    XCTAssertEqual(json?["status"], "ok", "GET /healthz body=\(json ?? [:])")
  }

  // MARK: - probes

  private func discoverPieBinary() throws -> URL {
    if let env = ProcessInfo.processInfo.environment["PIE_BIN"] {
      return URL(fileURLWithPath: env)
    }
    let probe = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("Vendor/pie/target/release/pie")
    try XCTSkipUnless(FileManager.default.fileExists(atPath: probe.path),
                      "pie binary missing at \(probe.path); run `cd Vendor/pie && PIE_PORTABLE_METAL=1 cargo build -p pie-server --release` or set PIE_BIN")
    return probe
  }

  private func discoverBundledInferletResources() throws -> (wasm: URL, manifest: URL) {
    // The CLIScenarioTests bundle is an SPM test target; it has no
    // Rational.app resources of its own. Fall through to the source-tree
    // prebuilt + manifest the e2e harness uses. The launcher
    // production caller (RatioThinkHelper) resolves these via
    // `InferletResources.pieControl(in:)` — covered by the unit
    // tests in RatioThinkCoreTests.
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let wasm = cwd.appendingPathComponent("Inferlets/chat-apc/prebuilt/chat-apc.wasm")
    let manifest = cwd.appendingPathComponent("Inferlets/chat-apc/Pie.toml")
    try XCTSkipUnless(FileManager.default.fileExists(atPath: wasm.path),
                      "chat-apc prebuilt wasm missing at \(wasm.path); run the source-tree build before this test")
    try XCTSkipUnless(FileManager.default.fileExists(atPath: manifest.path),
                      "chat-apc manifest missing at \(manifest.path)")
    return (wasm, manifest)
  }

  private func urlSessionGET(_ url: URL, timeout: TimeInterval) async throws -> (Data, URLResponse) {
    var req = URLRequest(url: url)
    req.timeoutInterval = timeout
    return try await URLSession.shared.data(for: req)
  }
}
