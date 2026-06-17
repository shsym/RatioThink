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

  func test_launchSpec_defaults_daemon_bind_host_to_loopback() throws {
    let binary = try writeDriverListProbe(portable: true)
    let spec = try makeSpec(binary: binary, modelConfig: .dummy)

    XCTAssertEqual(spec.daemonBindHost, .loopback)
    XCTAssertEqual(spec.daemonBindHost.daemonHost, "127.0.0.1")
  }

  func test_launchSpec_accepts_external_daemon_bind_host() throws {
    let binary = try writeDriverListProbe(portable: true)
    let spec = try makeSpec(
      binary: binary,
      modelConfig: .dummy,
      daemonBindHost: .external
    )

    XCTAssertEqual(spec.daemonBindHost, .external)
    XCTAssertEqual(spec.daemonBindHost.daemonHost, "0.0.0.0")
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

  // MARK: - #687 size-aware engine timeout

  private static let gib: Int64 = 1_073_741_824

  func test_resolvedTimeout_smallModel_keepsFloor() {
    // nil/unmeasurable, zero, and any weight at/below the 4 GiB base all stay
    // at the 120s floor — small models keep today's behavior exactly.
    let floor = PieControlLauncher.requestTimeoutFloorSeconds
    XCTAssertEqual(PieControlLauncher.resolvedRequestTimeoutSeconds(
      modelWeightBytes: nil, environment: [:]), floor)
    XCTAssertEqual(PieControlLauncher.resolvedRequestTimeoutSeconds(
      modelWeightBytes: 0, environment: [:]), floor)
    XCTAssertEqual(PieControlLauncher.resolvedRequestTimeoutSeconds(
      modelWeightBytes: 2 * Self.gib, environment: [:]), floor)
    XCTAssertEqual(PieControlLauncher.resolvedRequestTimeoutSeconds(
      modelWeightBytes: 4 * Self.gib, environment: [:]), floor,
      "exactly the base size adds zero headroom")
  }

  func test_resolvedTimeout_largeModel_scalesUp() {
    // floor 120 + 30s per GiB above the 4 GiB base.
    XCTAssertEqual(PieControlLauncher.resolvedRequestTimeoutSeconds(
      modelWeightBytes: 8 * Self.gib, environment: [:]), 240,   // 120 + 30*4
      "an 8 GiB model scales above the floor")
    XCTAssertEqual(PieControlLauncher.resolvedRequestTimeoutSeconds(
      modelWeightBytes: 12 * Self.gib, environment: [:]), 360)  // 120 + 30*8
  }

  func test_resolvedTimeout_respectsCeiling() {
    // 24 GiB would compute 720s; the 600s cap clamps it. A 70B-class GGUF
    // stays at the ceiling rather than running away.
    XCTAssertEqual(PieControlLauncher.resolvedRequestTimeoutSeconds(
      modelWeightBytes: 24 * Self.gib, environment: [:]),
      PieControlLauncher.requestTimeoutCeilingSeconds)
    XCTAssertEqual(PieControlLauncher.resolvedRequestTimeoutSeconds(
      modelWeightBytes: 100 * Self.gib, environment: [:]),
      PieControlLauncher.requestTimeoutCeilingSeconds)
  }

  func test_resolvedTimeout_envOverrideWins() {
    // An explicit PIE_SHMEM_TIMEOUT_S beats BOTH the floor (small model) and
    // the size-aware default (large model) — the operator escape hatch.
    let env = ["PIE_SHMEM_TIMEOUT_S": "300"]
    XCTAssertEqual(PieControlLauncher.resolvedRequestTimeoutSeconds(
      modelWeightBytes: nil, environment: env), 300,
      "override beats the floor for a small/unmeasurable model")
    XCTAssertEqual(PieControlLauncher.resolvedRequestTimeoutSeconds(
      modelWeightBytes: 8 * Self.gib, environment: env), 300,
      "override beats the size-aware 240s default")
    XCTAssertEqual(PieControlLauncher.resolvedRequestTimeoutSeconds(
      modelWeightBytes: 100 * Self.gib, environment: env), 300,
      "override even beats the ceiling — it is unclamped on purpose")
  }

  func test_resolvedTimeout_envOverride_canExceedSizeCeiling() {
    // The escape hatch is deliberately allowed past the 600s size ceiling, but
    // it raises ONLY the per-request/shmem budget (`request_timeout_secs`,
    // child `PIE_SHMEM_TIMEOUT_S`). The cold-BOOT lease stays clamped at the
    // ceiling via `bootHandshakeTimeoutSeconds` (see
    // test_bootHandshake_staysBelowXPCDeadline_forAnyOverrideMagnitude), so an override above 600
    // does NOT extend the pre-READY weight-load window — it only lengthens the
    // per-request forward/generation budget once the engine is serving.
    XCTAssertGreaterThan(700, PieControlLauncher.requestTimeoutCeilingSeconds)
    XCTAssertEqual(PieControlLauncher.resolvedRequestTimeoutSeconds(
      modelWeightBytes: nil, environment: ["PIE_SHMEM_TIMEOUT_S": "700"]), 700)
  }

  func test_resolvedTimeout_envOverride_clampsHugeFiniteValueWithoutTrapping() {
    // Finite-but-huge values (> Int.max) must clamp to the 24h bound, NOT trap
    // `Int(secs)` and crash the privileged helper at launch.
    for huge in ["1e30", "99999999999999999999", "1e400"] {  // 1e400 → +inf, rejected
      let got = PieControlLauncher.resolvedRequestTimeoutSeconds(
        modelWeightBytes: nil, environment: ["PIE_SHMEM_TIMEOUT_S": huge])
      // 1e30 / the 20-digit literal clamp to the 24h max; 1e400 overflows to
      // +inf (non-finite) and falls back to the floor.
      XCTAssertTrue(got == PieControlLauncher.requestTimeoutOverrideMaxSeconds
                    || got == PieControlLauncher.requestTimeoutFloorSeconds,
                    "override \(huge) must yield a finite clamped Int, got \(got)")
    }
    XCTAssertEqual(PieControlLauncher.resolvedRequestTimeoutSeconds(
      modelWeightBytes: nil, environment: ["PIE_SHMEM_TIMEOUT_S": "1e30"]),
      PieControlLauncher.requestTimeoutOverrideMaxSeconds)
  }

  func test_resolvedTimeout_envOverride_rejectsGarbageAndFallsBackToSize() {
    // Non-numeric, non-finite, and non-positive overrides are ignored so a
    // stray/empty value can't silently disable the size-aware default.
    for bad in ["abc", "", "0", "-5", "nan", "inf"] {
      XCTAssertEqual(PieControlLauncher.resolvedRequestTimeoutSeconds(
        modelWeightBytes: 8 * Self.gib, environment: ["PIE_SHMEM_TIMEOUT_S": bad]), 240,
        "invalid override \(bad.debugDescription) must fall back to the size-aware default")
    }
  }

  func test_rejectedTimeoutOverride_namesPresentButInvalidValueOnly() {
    // #698 F3: the classifier the launch site uses to warn on a silently
    // dropped override. Must mirror `resolvedRequestTimeoutSeconds`'s accept
    // predicate EXACTLY so the warning fires iff the value was actually ignored.
    // Present-but-invalid → returns the raw value verbatim (for the log).
    for bad in ["abc", "", "0", "-5", "nan", "inf"] {
      XCTAssertEqual(
        PieControlLauncher.rejectedTimeoutOverride(environment: ["PIE_SHMEM_TIMEOUT_S": bad]),
        bad,
        "invalid override \(bad.debugDescription) must be reported as rejected")
    }
    // Absent → nil (nothing to warn about).
    XCTAssertNil(PieControlLauncher.rejectedTimeoutOverride(environment: [:]))
    // Valid (incl. the huge-but-finite escape-hatch values the resolver clamps
    // rather than rejects) → nil: the override was honored, not dropped.
    for good in ["120", "300", "700", "1e30", "99999999999999999999"] {
      XCTAssertNil(
        PieControlLauncher.rejectedTimeoutOverride(environment: ["PIE_SHMEM_TIMEOUT_S": good]),
        "valid override \(good.debugDescription) must not be reported as rejected")
    }
  }

  func test_bootHandshake_staysBelowXPCDeadline_forAnyOverrideMagnitude() {
    // F2: the request/shmem value may exceed the 600s ceiling (escape hatch),
    // but the BOOT lease must not — the static startReplyDeadline is sized to
    // the ceiling, so a lease above it would let the XPC fallback kill a
    // still-booting engine. The clamp must hold for any override magnitude.
    let ceiling = PieControlLauncher.requestTimeoutCeilingSeconds
    for req in [120, 240, ceiling, 700, 900,
                PieControlLauncher.requestTimeoutOverrideMaxSeconds] {
      let lease = PieControlLauncher.bootHandshakeTimeoutSeconds(requestTimeoutSeconds: req)
      XCTAssertLessThanOrEqual(lease, ceiling,
                               "boot lease for request=\(req) must never exceed the ceiling")
      XCTAssertLessThan(TimeInterval(lease) + PieEngineHost.defaultLaunchTimeoutSlack,
                        HelperExportedAPI.startReplyDeadline,
                        "boot lease for request=\(req) must stay strictly below the static XPC reply deadline")
    }
    // Sub-ceiling values pass through unchanged (no clamp side effect).
    XCTAssertEqual(PieControlLauncher.bootHandshakeTimeoutSeconds(requestTimeoutSeconds: 240), 240)
    XCTAssertEqual(PieControlLauncher.bootHandshakeTimeoutSeconds(requestTimeoutSeconds: 900), ceiling)
  }

  func test_renderedTimeout_lockstep_acrossConfigAndEnv() {
    // The single resolved value drives BOTH the TOML scheduler timeout and the
    // injected child PIE_SHMEM_TIMEOUT_S, so they can never drift.
    let body = PieControlLauncher.renderConfigBody(
      modelConfig: .portableResolved(servedModelID: "m", modelRef: "/tmp/m.gguf"),
      requestTimeoutSeconds: 360)
    XCTAssertTrue(body.contains("request_timeout_secs = 360"), "got:\n\(body)")
    let env = PieControlLauncher.renderSubprocessEnvironment(
      base: [:],
      pieHome: URL(fileURLWithPath: "/tmp/h", isDirectory: true),
      shmemName: "/pie-test",
      requestTimeoutSeconds: 360)
    XCTAssertEqual(env["PIE_SHMEM_TIMEOUT_S"], "360")
  }

  // MARK: - helpers

  private func makeSpec(binary: URL,
                        subprocessEnvironment: [String: String] = [:],
                        modelConfig: PieControlLauncher.ModelConfig,
                        daemonBindHost: EngineHTTPBindMode = .loopback) throws -> PieControlLauncher.LaunchSpec {
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
      daemonBindHost: daemonBindHost,
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
