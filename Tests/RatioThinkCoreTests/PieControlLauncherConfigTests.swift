import Darwin
import Foundation
import XCTest
@testable import RatioThinkCore

/// Pins `PieControlLauncher.renderConfigBody` so a future TOML drift
/// in `pie serve --config` is caught at the unit-test layer instead
/// of surfacing as a runtime "engine exited early" on the helper
/// boot path.  introduced the `.portable` variant; the
/// existing `.dummy` body is pinned for the S0 isolation test
/// (which depends on the same emission shape).
final class PieControlLauncherConfigTests: XCTestCase {

  func test_configTimeout_matchesPieTemplateDefaultForSlowToTRequests() {
    let body = PieControlLauncher.renderConfigBody(modelConfig: .dummy)
    XCTAssertTrue(body.contains("request_timeout_secs = 120"),
                  "app launcher config must not lower pie's template/default 120s request timeout; slow ToT node/scorer passes can otherwise close SSE without a terminal frame")
    XCTAssertFalse(body.contains("request_timeout_secs = 60"),
                   "60s was too low for packaged-app ToT runs on slower hardware/profiles")
  }

  func test_subprocessEnvironment_liftsShmemTimeoutToMatchSchedulerTimeout() {
    let env = PieControlLauncher.renderSubprocessEnvironment(
      base: ["PIE_SHMEM_TIMEOUT_S": "1", "KEEP": "yes"],
      pieHome: URL(fileURLWithPath: "/tmp/pie-home", isDirectory: true),
      shmemName: "/pie-test"
    )
    XCTAssertEqual(env["PIE_HOME"], "/tmp/pie-home")
    XCTAssertEqual(env["PIE_SHMEM_NAME"], "/pie-test")
    XCTAssertEqual(env["PIE_SHMEM_TIMEOUT_S"], "120",
                   "the real fire_batch/shmem path reads PIE_SHMEM_TIMEOUT_S, not scheduler.request_timeout_secs directly")
    XCTAssertEqual(env["KEEP"], "yes")
  }

  func test_dummy_body_emits_dummy_driver_with_qwen3_fixture() {
    let body = PieControlLauncher.renderConfigBody(modelConfig: .dummy)
    XCTAssertTrue(body.contains("type = \"dummy\""),
                  "dummy config must declare the dummy driver")
    XCTAssertTrue(body.contains("hf_repo = \"Qwen/Qwen3-0.6B\""),
                  "dummy config must keep the existing Qwen fixture so S0 tests stay stable")
    XCTAssertTrue(body.contains("name = \"default\""),
                  "model name must remain \"default\" — chat-apc resolves against this name")
  }

  func test_servedModelID_mirrors_model_name_per_config() {
    // #476: the snapshot's servedModelID must equal the engine's advertised
    // `[[model]].name` — the chat-completion `model` field the App sends.
    XCTAssertEqual(PieControlLauncher.ModelConfig.dummy.servedModelID, "default")
    XCTAssertEqual(
      PieControlLauncher.ModelConfig.portable(
        modelSlug: "org/repo/file.gguf",
        modelsRoot: URL(fileURLWithPath: "/tmp/models", isDirectory: true)).servedModelID,
      "org/repo/file.gguf")
    XCTAssertEqual(
      PieControlLauncher.ModelConfig.portableResolved(
        servedModelID: "org/repo/file.gguf", modelRef: "/tmp/models/org/repo/file.gguf").servedModelID,
      "org/repo/file.gguf")
    XCTAssertEqual(
      PieControlLauncher.ModelConfig.metal(modelID: "Qwen/Qwen3-0.6B").servedModelID,
      "Qwen/Qwen3-0.6B")
  }

  func test_portable_body_emits_portable_driver_with_resolved_hf_repo_path() {
    let modelsRoot = URL(fileURLWithPath: "/tmp/pie/models")
    let body = PieControlLauncher.renderConfigBody(
      modelConfig: .portable(modelSlug: "Qwen3-0.6B-Q4_K_M.gguf",
                             modelsRoot: modelsRoot)
    )
    XCTAssertTrue(body.contains("type = \"portable\""),
                  "production config must declare the portable driver (Metal on macOS)")
    XCTAssertTrue(body.contains("hf_repo = \"/tmp/pie/models/Qwen3-0.6B-Q4_K_M.gguf\""),
                  "pie serve config must pass the resolved local model path through model.hf_repo")
    XCTAssertTrue(body.contains("name = \"Qwen3-0.6B-Q4_K_M.gguf\""),
                  "served model name must be the profile slug (the id the App's chat requests carry), not \"default\"")
    XCTAssertTrue(body.contains("device = [\"metal\"]"),
                  "v1 macOS production config should request Metal explicitly instead of relying on an implicit default")
    XCTAssertFalse(body.contains("hf_path"),
                   "pie serve config no longer accepts top-level hf_path; it resolves model.hf_repo")
    XCTAssertFalse(body.contains("type = \"dummy\""),
                   "portable config must not emit the dummy-driver block")
  }

  func test_portable_body_omits_default_token_limit_when_nil() {
    // #438: with no memory-aware ceiling, the scheduler block must NOT
    // carry default_token_limit — the engine keeps its default (no clamp),
    // preserving pre-#438 behavior on hosts that sustain the full pool.
    let body = PieControlLauncher.renderConfigBody(
      modelConfig: .portableResolved(servedModelID: "m", modelRef: "/tmp/m.gguf"),
      defaultTokenLimit: nil
    )
    XCTAssertFalse(body.contains("default_token_limit"),
                   "nil defaultTokenLimit must not write the override; got:\n\(body)")
    XCTAssertFalse(body.contains("[model.driver.options]"),
                   "the pool-resize path is gone — no driver-options block; got:\n\(body)")
  }

  func test_portable_body_emits_default_token_limit_when_set() {
    // #438: the memory-aware ceiling rides [model.scheduler].default_token_limit.
    let body = PieControlLauncher.renderConfigBody(
      modelConfig: .portableResolved(servedModelID: "m", modelRef: "/tmp/m.gguf"),
      defaultTokenLimit: 5000
    )
    // Exact key = value line, under the scheduler section, not driver options.
    XCTAssertTrue(body.contains("default_token_limit = 5000"), "got:\n\(body)")
    XCTAssertTrue(body.contains("[model.scheduler]"), "got:\n\(body)")
    XCTAssertFalse(body.contains("max_num_kv_pages"),
                   "the old pool-resize knob must not be emitted; got:\n\(body)")
    XCTAssertTrue(body.contains("type = \"portable\""))
  }

  func test_metal_body_emits_default_token_limit_when_set() {
    let body = PieControlLauncher.renderConfigBody(
      modelConfig: .metal(modelID: "Qwen/Qwen3-0.6B"),
      defaultTokenLimit: 4096
    )
    XCTAssertTrue(body.contains("default_token_limit = 4096"), "got:\n\(body)")
    XCTAssertTrue(body.contains("device = [\"metal\"]"), "got:\n\(body)")
  }

  func test_portable_body_emits_max_num_kv_pages_when_set() {
    // #475: the engine KV-pool override rides [model.driver.options].
    // max_num_kv_pages — the knob the memory-budget sweep turns to lower the
    // raw KV capacity (and so the effective ceiling) directly. Omitted when
    // nil (guarded by `..._omits_default_token_limit_when_nil`).
    let body = PieControlLauncher.renderConfigBody(
      modelConfig: .portableResolved(servedModelID: "m", modelRef: "/tmp/m.gguf"),
      defaultTokenLimit: nil,
      maxNumKvPages: 256
    )
    XCTAssertTrue(body.contains("[model.driver.options]"),
                  "a set maxNumKvPages must emit the driver-options block; got:\n\(body)")
    XCTAssertTrue(body.contains("max_num_kv_pages = 256"), "got:\n\(body)")
    XCTAssertTrue(body.contains("type = \"portable\""), "got:\n\(body)")
    // The override is independent of the scheduler ceiling.
    XCTAssertFalse(body.contains("default_token_limit"), "got:\n\(body)")
  }

  func test_metal_body_emits_max_num_kv_pages_when_set() {
    let body = PieControlLauncher.renderConfigBody(
      modelConfig: .metal(modelID: "Qwen/Qwen3-0.6B"),
      defaultTokenLimit: 4096,
      maxNumKvPages: 512
    )
    XCTAssertTrue(body.contains("[model.driver.options]"), "got:\n\(body)")
    XCTAssertTrue(body.contains("max_num_kv_pages = 512"), "got:\n\(body)")
    XCTAssertTrue(body.contains("default_token_limit = 4096"),
                  "both knobs coexist — scheduler cap + driver pool; got:\n\(body)")
    XCTAssertTrue(body.contains("device = [\"metal\"]"), "got:\n\(body)")
  }

  func test_portableResolved_serves_under_profile_slug_with_distinct_hf_repo_path() {
    // The crux of the id-unification fix ( follow-up): the engine's
    // served `name` is the profile slug the App carries everywhere, while
    // `hf_repo` is the separately-resolved on-disk path. The two are
    // intentionally different strings — the public id is NOT the resolved
    // path, and it is NOT the old hardcoded "default".
    let body = PieControlLauncher.renderConfigBody(
      modelConfig: .portableResolved(
        servedModelID: "Qwen/Qwen3-0.6B",
        modelRef: "/Users/me/.cache/huggingface/hub/models--Qwen--Qwen3-0.6B/snapshots/abc"
      )
    )
    XCTAssertTrue(body.contains("name = \"Qwen/Qwen3-0.6B\""),
                  "served name must be the profile slug verbatim so /v1/models and the chat `model` field agree")
    XCTAssertTrue(body.contains("hf_repo = \"/Users/me/.cache/huggingface/hub/models--Qwen--Qwen3-0.6B/snapshots/abc\""),
                  "hf_repo must carry the resolved on-disk path, independent of the served id")
    XCTAssertFalse(body.contains("name = \"default\""),
                   "production bodies must no longer hardcode the served name to \"default\"")
  }

  func test_portable_body_joins_multi_segment_slug_without_percent_escaping() {
    // Mirrors `LaunchSpecResolver.joinModelPath` — the downloader
    // writes `<repo>/<file>` slugs to disk, and the production
    // config must point pie at the same on-disk layout. Without
    // explicit path-component splitting, Foundation would emit
    // `repo%2Ffile`.
    let modelsRoot = URL(fileURLWithPath: "/tmp/pie/models")
    let body = PieControlLauncher.renderConfigBody(
      modelConfig: .portable(modelSlug: "TheBloke/Llama-2-7B-Chat-GGUF/llama-2-7b.gguf",
                             modelsRoot: modelsRoot)
    )
    XCTAssertTrue(body.contains("hf_repo = \"/tmp/pie/models/TheBloke/Llama-2-7B-Chat-GGUF/llama-2-7b.gguf\""),
                  "portable hf_repo path must preserve `/`-segmented downloader layout")
  }

  func test_portable_body_escapes_embedded_quotes_in_slug() {
    // Defensive: a profile-supplied model slug containing a literal
    // `"` would otherwise emit malformed TOML. macOS filesystem
    // paths can technically contain `"`; the launcher must escape
    // before writing.
    let modelsRoot = URL(fileURLWithPath: "/tmp")
    let body = PieControlLauncher.renderConfigBody(
      modelConfig: .portable(modelSlug: "weird\"name.gguf",
                             modelsRoot: modelsRoot)
    )
    XCTAssertTrue(body.contains(#"hf_repo = "/tmp/weird\"name.gguf""#),
                  "embedded quotes must be backslash-escaped; got:\n\(body)")
  }

  func test_writeConfig_writes_file_under_pieHome() throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("pie-config-\(UUID().uuidString.prefix(8))",
                              isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let url = try PieControlLauncher.writeConfig(modelConfig: .dummy, in: tmp)
    XCTAssertEqual(url.lastPathComponent, "config.toml")
    let written = try String(contentsOf: url)
    XCTAssertTrue(written.contains("type = \"dummy\""))
  }

  func test_launchSpecConstruction_rejects_portable_when_binary_lacks_portable_driver() throws {
    let binary = try writeDriverListProbe(portable: false)
    XCTAssertThrowsError(try makeSpec(binary: binary,
                                      modelConfig: .portable(modelSlug: "model.gguf",
                                                             modelsRoot: tempModelsRoot()))) { error in
      guard case PieControlLauncher.LaunchError.driverUnsupported(
        requested: let requested, binary: _, details: _
      ) = error else {
        return XCTFail("expected driverUnsupported, got \(error)")
      }
      XCTAssertEqual(requested, "portable")
    }
  }

  // Current pie has no separate "metal" capability — Metal is the
  // portable driver's device. So a `.metal` launch is rejected when the
  // PORTABLE driver is not compiled in (the only thing the probe can know);
  // the actual Metal backend is validated at serve boot.
  func test_launchSpecConstruction_rejects_metal_when_portable_not_compiled() throws {
    let binary = try writeDriverListProbe(portable: false)
    XCTAssertThrowsError(try makeSpec(binary: binary,
                                      modelConfig: .metal(modelID: "Qwen/Qwen3-0.6B"))) { error in
      guard case PieControlLauncher.LaunchError.driverUnsupported(
        requested: let requested, binary: _, details: _
      ) = error else {
        return XCTFail("expected driverUnsupported, got \(error)")
      }
      XCTAssertEqual(requested, "metal")
    }
  }

  func test_launchSpecConstruction_accepts_metal_when_portable_compiled_in() throws {
    let binary = try writeDriverListProbe(portable: true)
    let spec = try makeSpec(binary: binary,
                            modelConfig: .metal(modelID: "Qwen/Qwen3-0.6B"))
    XCTAssertEqual(spec.pieBinary, binary)
  }

  func test_launchSpecConstruction_uses_subprocessEnvironment_for_driverListProbe() throws {
    let binary = try writeEnvironmentSensitiveDriverListProbe(
      key: "CAPABILITY_TEST_FLAG",
      expectedValue: "from-launch-spec"
    )

    XCTAssertNoThrow(try makeSpec(
      binary: binary,
      subprocessEnvironment: ["CAPABILITY_TEST_FLAG": "from-launch-spec"],
      modelConfig: .portable(modelSlug: "model.gguf", modelsRoot: tempModelsRoot())
    ))
  }

  func test_launchSpecConstruction_returnsBoundedFailureWhenProbeChildKeepsStdoutOpen() throws {
    let childPIDFile = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("pie-capability-child-\(UUID().uuidString.prefix(8)).pid")
    let binary = try writeStdoutLeakingDriverListProbe(childPIDFile: childPIDFile)
    defer { killChildRecorded(in: childPIDFile) }

    let finished = expectation(description: "capability probe returns")
    final class ResultBox: @unchecked Sendable {
      private let lock = NSLock()
      private var value: Result<PieControlLauncher.LaunchSpec, Error>?
      func store(_ newValue: Result<PieControlLauncher.LaunchSpec, Error>) {
        lock.lock()
        value = newValue
        lock.unlock()
      }
      func load() -> Result<PieControlLauncher.LaunchSpec, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return value
      }
    }
    let resultBox = ResultBox()

    DispatchQueue.global().async {
      resultBox.store(Result {
        try self.makeSpec(
          binary: binary,
          modelConfig: .portable(modelSlug: "model.gguf", modelsRoot: self.tempModelsRoot())
        )
      })
      finished.fulfill()
    }

    let waitResult = XCTWaiter.wait(for: [finished], timeout: 1.5)
    guard waitResult == .completed else {
      killChildRecorded(in: childPIDFile)
      XCTFail("capability probe blocked on inherited stdout pipe instead of returning a bounded driverUnsupported error")
      return
    }

    guard case .failure(let error) = resultBox.load() else {
      return XCTFail("expected bounded driverUnsupported failure when probe pipe stays open")
    }
    guard case PieControlLauncher.LaunchError.driverUnsupported(
      requested: _, binary: _, details: let details
    ) = error else {
      return XCTFail("expected driverUnsupported, got \(error)")
    }
    XCTAssertTrue(details.contains("timed out"),
                  "expected timeout detail for inherited stdout pipe, got \(details)")
  }

  // MARK: - driver-list parse + real-binary contract

  private let pieURL = URL(fileURLWithPath: "/bin/pie")  // placeholder for parse tests

  func test_parseDriverList_portable_compiled_in() throws {
    let out = """
    Embedded drivers (compiled into this binary by feature):
      portable     (compiled in)
      cuda_native  (not compiled)
      dummy        (compiled in)
    """
    let portableCompiledIn = try PieControlLauncher.parseDriverList(out, pieBinary: pieURL, requested: "portable")
    XCTAssertTrue(portableCompiledIn)
  }

  func test_parseDriverList_portable_not_compiled() throws {
    let out = """
    Embedded drivers (compiled into this binary by feature):
      portable     (not compiled)
      dummy        (compiled in)
    """
    let portableCompiledIn = try PieControlLauncher.parseDriverList(out, pieBinary: pieURL, requested: "portable")
    XCTAssertFalse(portableCompiledIn)
  }

  func test_parseDriverList_failsClosed_whenPortableUnmentioned() {
    // An unexpected/changed CLI format that never names `portable` must
    // throw, not silently pass — this is the drift-guard.
    let out = "some totally different output\n  foo (compiled in)\n"
    XCTAssertThrowsError(
      try PieControlLauncher.parseDriverList(out, pieBinary: pieURL, requested: "portable")
    )
  }

  /// REAL-BINARY contract test: runs the ACTUAL pie binary's `driver
  /// list` — not a stub — and asserts the subcommand exists and reports
  /// the portable driver compiled in. Closes the gap a stubbed probe
  /// leaves: the unit tests fake the probe, so they stay green even if
  /// the real subcommand is removed/renamed upstream. Env-gated; falls
  /// back to the installed app; skips if no real binary is available.
  ///
  /// Both pipes are drained on background queues and the wait is bounded,
  /// so a chatty binary can't deadlock on a full pipe buffer and a hung
  /// binary fails the test rather than hanging the suite.
  func test_realPie_driverList_subcommand_exists_and_reports_portable() throws {
    let candidates = [
      ProcessInfo.processInfo.environment["PIE_TEST_REAL_PIE_BIN"],
      "/Applications/Rational.app/Contents/Resources/pie-engine/pie",
    ].compactMap { $0 }
    guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
      throw XCTSkip("no real pie binary (set PIE_TEST_REAL_PIE_BIN or install Rational.app)")
    }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: path)
    proc.arguments = ["driver", "list"]
    let out = Pipe(); let err = Pipe()
    proc.standardOutput = out; proc.standardError = err
    // Launch the real binary before draining/awaiting. Without this the pipe
    // reads never reach EOF (no child closes the write ends), the bounded
    // wait below times out, and terminate() then throws `task not launched`
    // on a process that was never started.
    try proc.run()

    // Drain both pipes concurrently (off this thread) so the child can
    // never block writing to a full pipe while we wait, and bound the
    // wait so a hung binary can't hang the suite.
    let outBuf = NSMutableData(); let errBuf = NSMutableData()
    let lock = NSLock()
    let group = DispatchGroup()
    let queue = DispatchQueue.global(qos: .userInitiated)
    for (pipe, buf) in [(out, outBuf), (err, errBuf)] {
      group.enter()
      queue.async {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        lock.lock(); buf.append(data); lock.unlock()
        group.leave()
      }
    }
    group.enter()
    queue.async { proc.waitUntilExit(); group.leave() }

    guard group.wait(timeout: .now() + 10) == .success else {
      proc.terminate()
      return XCTFail("`pie driver list` did not finish within 10s — possible hung binary")
    }

    let stdout = String(data: outBuf as Data, encoding: .utf8) ?? ""
    let stderr = String(data: errBuf as Data, encoding: .utf8) ?? ""
    XCTAssertEqual(proc.terminationStatus, 0,
                   "`pie driver list` must exist + exit 0 (CLI-contract drift guard); stderr: \(stderr)")
    XCTAssertFalse(stderr.contains("unrecognized subcommand"),
                   "`pie driver list` subcommand is missing — pie CLI contract drifted: \(stderr)")
    let portableCompiledIn = try PieControlLauncher.parseDriverList(
      stdout, pieBinary: URL(fileURLWithPath: path), requested: "portable"
    )
    XCTAssertTrue(portableCompiledIn,
                  "real pie must report the portable driver compiled in; got:\n\(stdout)")
  }

  // MARK: - helpers

  private func makeSpec(binary: URL,
                        subprocessEnvironment: [String: String] = [:],
                        modelConfig: PieControlLauncher.ModelConfig) throws -> PieControlLauncher.LaunchSpec {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("pie-launchspec-\(UUID().uuidString.prefix(8))",
                              isDirectory: true)
    return try PieControlLauncher.LaunchSpec(
      pieBinary: binary,
      wasmURL: tmp.appendingPathComponent("chat-apc.wasm"),
      manifestURL: tmp.appendingPathComponent("Pie.toml"),
      subprocessEnvironment: subprocessEnvironment,
      pieHome: tmp.appendingPathComponent("home"),
      shmemName: "/pie_test_\(UUID().uuidString.prefix(8))",
      modelConfig: modelConfig
    )
  }

  /// Emit the `Embedded drivers` section of `pie driver list`, with the
  /// `portable` driver marked compiled-in or not — the launcher now
  /// probes `pie driver list`, not the removed `pie capabilities`.
  private func driverListText(portable: Bool) -> String {
    let mark = portable ? "(compiled in)" : "(not compiled)"
    return """
    Subprocess drivers (Python wheels):
      dev       python -m pie_driver_dev

    Embedded drivers (compiled into this binary by feature):
      portable     \(mark)
      cuda_native  (not compiled)
      dummy        (compiled in)
    """
  }

  private func writeDriverListProbe(portable: Bool) throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("pie-driverlist-\(UUID().uuidString.prefix(8))",
                              isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let binary = dir.appendingPathComponent("pie", isDirectory: false)
    let script = """
    #!/bin/sh
    if [ "$1" = "driver" ] && [ "$2" = "list" ]; then
      cat <<'EOF'
    \(driverListText(portable: portable))
    EOF
      exit 0
    fi
    exit 64
    """
    try script.write(to: binary, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o755)],
      ofItemAtPath: binary.path
    )
    return binary
  }

  private func writeEnvironmentSensitiveDriverListProbe(key: String,
                                                        expectedValue: String) throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("pie-capabilities-\(UUID().uuidString.prefix(8))",
                              isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let binary = dir.appendingPathComponent("pie", isDirectory: false)
    let script = """
    #!/bin/sh
    if [ "$1" = "driver" ] && [ "$2" = "list" ]; then
      if [ "${\(key)}" = "\(expectedValue)" ]; then
        printf 'Embedded drivers (compiled into this binary by feature):\\n  portable     (compiled in)\\n'
      else
        printf 'Embedded drivers (compiled into this binary by feature):\\n  portable     (not compiled)\\n'
      fi
      exit 0
    fi
    exit 64
    """
    try script.write(to: binary, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o755)],
      ofItemAtPath: binary.path
    )
    return binary
  }

  private func writeStdoutLeakingDriverListProbe(childPIDFile: URL) throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("pie-capabilities-\(UUID().uuidString.prefix(8))",
                              isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let binary = dir.appendingPathComponent("pie", isDirectory: false)
    let script = """
    #!/bin/sh
    if [ "$1" = "driver" ] && [ "$2" = "list" ]; then
      ( sleep 30 ) &
      echo $! > '\(childPIDFile.path)'
      printf 'Embedded drivers (compiled into this binary by feature):\\n  portable     (compiled in)\\n'
      exit 0
    fi
    exit 64
    """
    try script.write(to: binary, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o755)],
      ofItemAtPath: binary.path
    )
    return binary
  }

  private func killChildRecorded(in childPIDFile: URL) {
    guard let raw = try? String(contentsOf: childPIDFile, encoding: .utf8),
          let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
      return
    }
    _ = Darwin.kill(pid, SIGKILL)
  }

  private func tempModelsRoot() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("models", isDirectory: true)
  }
}
