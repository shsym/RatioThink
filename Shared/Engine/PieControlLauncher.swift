import Foundation
import Darwin

/// Brings a `pie serve` engine up with the bundled `chat-apc`
/// inferlet installed and listening on an OS-picked HTTP port.
///
/// Swift port of the Python reference at
/// `Inferlets/chat-apc/e2e_test.py:main()` and the inline
/// race-guarded teardown helpers. The Python version was an e2e
/// smoke harness; this version is the production launcher used by
/// RatioThinkHelper at runtime and by `IsolatedTestCase` in tests.
///
/// Lifecycle in one launch:
///   1. Reserve a free port via `bind(127.0.0.1:0) → close` so we can
///      hand it to pie before pie itself binds.
///   2. Spawn `pie serve --no-auth --debug --config <tmp/config.toml>`
///      with `PIE_HOME=<tmp>` + `PIE_SHMEM_NAME=/pie_t_<pid>_<uuid8>`.
///   3. Parse the engine's stdout for
///        `pie-server serving on <host>:<port>`
///        `internal token: <token>`
///      Both must appear within `handshakeTimeout`.
///   4. Open a WebSocket to `ws://<host>:<port>`, auth_by_token,
///      install_program(wasm, manifest, force=true), launch_daemon
///      ("chat-apc@0.1.0", <free port>).
///   5. Write the free port to `<PIE_HOME>/http.port` so
///      `IsolatedTestCase.boundHTTPPort()` (the engine-side feedback
///      channel deferred under  §F7) succeeds.
///   6. On shutdown / failure: SIGINT → grace(10s) → SIGKILL the
///      child, then `shm_unlink(PIE_SHMEM_NAME)` quietly so the
///      POSIX region does not leak.
///
/// Concurrency: `LaunchedSession` is an actor because shutdown can
/// race the spawn task's stdout reader. The reader publishes lines
/// through a single `AsyncStream` consumed inside the actor; this
/// avoids the Python harness's `_drain_stdout` background task +
/// `_send_signal_safe` dance.
public enum PieControlLauncher {

  // MARK: - errors

  public enum LaunchError: Error, CustomStringConvertible {
    case freePortBindFailed(errno: Int32)
    case freePortGetSockNameFailed(errno: Int32)
    case pieBinaryMissing(path: String)
    case spawnFailed(underlying: String)
    case engineExitedEarly(code: Int32?, stderrTail: String)
    case handshakeTimeout(elapsed: TimeInterval, lastLines: [String])
    case configWriteFailed(path: String, underlying: String)
    case portFileWriteFailed(path: String, underlying: String)
    case clientError(underlying: String)
    case driverUnsupported(requested: String, binary: String, details: String)
    /// `PIE_HOME` is so deep that the engine's aux Unix-domain control
    /// socket path would overrun the OS `sun_path` limit. Thrown by the
    /// pre-launch budget check so the failure is loud and actionable
    /// instead of a silent model-load hang.
    case pieHomePathTooLong(pieHome: String, length: Int, limit: Int)

    public var description: String {
      switch self {
      case let .freePortBindFailed(e): return "PieControlLauncher: bind(127.0.0.1:0) failed errno=\(e)"
      case let .freePortGetSockNameFailed(e): return "PieControlLauncher: getsockname failed errno=\(e)"
      case let .pieBinaryMissing(path): return "PieControlLauncher: pie binary missing at \(path)"
      case let .spawnFailed(u): return "PieControlLauncher: spawn failed: \(u)"
      case let .engineExitedEarly(code, tail):
        return "PieControlLauncher: pie exited early code=\(code.map(String.init) ?? "?") stderr-tail:\n\(tail)"
      case let .handshakeTimeout(elapsed, lastLines):
        return "PieControlLauncher: pie handshake not seen within \(elapsed)s — last stdout lines:\n  - \(lastLines.joined(separator: "\n  - "))"
      case let .configWriteFailed(path, u): return "PieControlLauncher: cannot write config at \(path): \(u)"
      case let .portFileWriteFailed(path, u): return "PieControlLauncher: cannot write http.port at \(path): \(u)"
      case let .clientError(u): return "PieControlLauncher: WS client error: \(u)"
      case let .driverUnsupported(requested, binary, details):
        return "PieControlLauncher: driver unsupported: \(requested) by \(binary): \(details)"
      case let .pieHomePathTooLong(pieHome, length, limit):
        return "PieControlLauncher: PIE_HOME path too long (\(length) bytes > \(limit) max): the engine binds a Unix aux socket at \(pieHome)/standalone/<pid>/g0/aux.sock, which would exceed the macOS sun_path limit (\(auxSocketSunPathBytes) bytes) and hang at model load — use a shorter PIE_HOME (production uses ~/Library/Application Support/RatioThink; tests should anchor pieHome at a short /tmp path)"
      }
    }
  }

  // MARK: - inputs

  /// Selects which `[[model]]` block + `[model.driver]` `type` the
  /// launcher writes into `<PIE_HOME>/config.toml` before spawning
  /// `pie serve`. The CLI scenario tests (`S0_TestIsolationTests`) need
  /// `.dummy` — no real inference, no model download — but RatioThinkHelper's
  /// production Resume path needs `.portable`, which runs Metal on
  /// macOS and loads the user-selected model the operator picked via
  /// `ProfileStore.activeProfileID`.
  public enum ModelConfig: Sendable, Equatable {
    /// Test driver. Fast bring-up, no model bytes touched.
    case dummy
    /// Production driver. `modelSlug` is `profile.model` — either a
    /// bare GGUF filename or a `<repo>/<file>` slug; the launcher
    /// joins it against `modelsRoot` via `LaunchSpecResolver
    /// .joinModelPath` so the on-disk layout the downloader writes
    /// is the same one pie reads.
    case portable(modelSlug: String, modelsRoot: URL)
    /// Production driver with a pre-resolved `[[model]].hf_repo`
    /// value. This may be a local app-staged GGUF path, a local HF
    /// snapshot directory, or an HF repo id. The v1 resolver uses
    /// this to enforce app-staged-first / HF-cache-second ordering
    /// before launch.
    ///
    /// `servedModelID` is `profile.model` — the slug the App carries
    /// everywhere (toolbar override, manual load, chat-completion
    /// `model` field). The launcher writes it verbatim as the engine's
    /// `[[model]].name` so the id the engine advertises on `/v1/models`
    /// is the same id every send path uses — no translation layer.
    /// `modelRef` is the *resolved* on-disk path/repo for `hf_repo`,
    /// a separate resolution concern from the public id.
    case portableResolved(servedModelID: String, modelRef: String)
    /// Real Metal inference against an HF-cached model resolved via
    /// `hf_repo = "<modelID>"`. `pie-driver-portable` is the same
    /// ggml-backed driver as `.portable` — the difference is that
    /// `.metal` lets pie's HF resolver pick the snapshot dir off the
    /// system `~/.cache/huggingface/hub` layout instead of taking
    /// the path from the operator's profile. Used by S3_EngineSubprocess
    /// when `PIE_TEST_S3_REAL=1` so the test exercises the same Metal
    /// forward-pass code path as the production Resume flow without
    /// requiring a fully wired profile + downloader.
    case metal(modelID: String)
  }

  public struct LaunchSpec: Sendable {
    public var pieBinary: URL
    public var wasmURL: URL
    public var manifestURL: URL
    /// Process env to give the spawned `pie serve`. The launcher
    /// overlays `PIE_HOME` and `PIE_SHMEM_NAME` on top of this; the
    /// caller is responsible for any sanitization (see
    /// `IsolatedTestCase.subprocessEnvironment` for the canonical
    /// test-side environment built on `SpawnEnvSanitizer`).
    public var subprocessEnvironment: [String: String]
    public var pieHome: URL
    public var shmemName: String
    /// Inferlet identifier used in `launch_daemon`. Must match the
    /// `name@version` recorded in the manifest.
    public var inferletNameAtVersion: String
    public var handshakeTimeout: TimeInterval
    /// Optional callback that receives the spawned pid the moment
    /// `Process.run()` returns. `IsolatedTestCase` passes
    /// `trackSubprocess(_:)` here so tearDown can reap stragglers.
    public var pidSink: (@Sendable (pid_t) -> Void)?
    /// Free-form metadata projected into `EngineStatus.running.profileID`
    /// by `PieEngineHost`. Not consumed by `pie serve`; carried so
    /// the menu-bar dot can show "running — <profile> @ port <port>"
    /// without piping the active id through a second channel.
    /// CLI scenario tests default to "isolated".
    public var profileID: String
    /// Which `[[model]]` body + driver `type` the launcher writes
    /// into the spawned `config.toml`. Required (no default) — review
    /// v1 F8: a `.dummy` default re-introduces the silent-fallback
    /// class of bug a future production caller might trip when they
    /// forget to set it. Every call site picks explicitly: tests
    /// pass `.dummy`, the resolver passes `.portable(...)` or
    /// `.metal(...)`.
    public var modelConfig: ModelConfig

    /// Memory-aware per-request output-token ceiling written as
    /// `[model.scheduler].default_token_limit` (#438). `nil` omits it so
    /// the engine keeps its default — used for `.dummy` launches, hosts
    /// whose model metadata can't be read, and the common case where the
    /// host can sustain the full default pool. Down-only: only set when it
    /// lowers the ceiling below the engine default. See `KVCacheBudget`.
    public var defaultTokenLimit: Int?

    public init(pieBinary: URL,
                wasmURL: URL,
                manifestURL: URL,
                subprocessEnvironment: [String: String],
                pieHome: URL,
                shmemName: String,
                inferletNameAtVersion: String = "chat-apc@0.1.0",
                handshakeTimeout: TimeInterval = 30,
                pidSink: (@Sendable (pid_t) -> Void)? = nil,
                profileID: String = "isolated",
                modelConfig: ModelConfig,
                defaultTokenLimit: Int? = nil) throws {
      try PieControlLauncher.validateDriverSupport(
        pieBinary: pieBinary,
        subprocessEnvironment: subprocessEnvironment,
        pieHome: pieHome,
        shmemName: shmemName,
        modelConfig: modelConfig
      )
      self.pieBinary = pieBinary
      self.wasmURL = wasmURL
      self.manifestURL = manifestURL
      self.subprocessEnvironment = subprocessEnvironment
      self.pieHome = pieHome
      self.shmemName = shmemName
      self.inferletNameAtVersion = inferletNameAtVersion
      self.handshakeTimeout = handshakeTimeout
      self.pidSink = pidSink
      self.profileID = profileID
      self.modelConfig = modelConfig
      self.defaultTokenLimit = defaultTokenLimit
    }
  }

  private static func validateDriverSupport(pieBinary: URL,
                                            subprocessEnvironment: [String: String],
                                            pieHome: URL,
                                            shmemName: String,
                                            modelConfig: ModelConfig) throws {
    var probeEnvironment = subprocessEnvironment
    probeEnvironment["PIE_HOME"] = pieHome.path
    probeEnvironment["PIE_SHMEM_NAME"] = shmemName

    switch modelConfig {
    case .dummy:
      return
    case .portable, .portableResolved:
      guard try probeDriverList(pieBinary: pieBinary,
                                environment: probeEnvironment,
                                requested: "portable") else {
        throw LaunchError.driverUnsupported(
          requested: "portable",
          binary: pieBinary.path,
          details: "portable driver is not compiled into this pie binary"
        )
      }
    case .metal:
      // Current pie has no separate "metal" readiness signal — Metal is
      // the embedded `portable` driver's device on macOS. Gate on
      // `portable` being compiled in; the actual Metal backend is
      // validated at `pie serve` boot (device = ["metal"] fails loud
      // there if a host built without PIE_PORTABLE_METAL=1), surfaced via
      // the launch handshake / liveness probe.
      guard try probeDriverList(pieBinary: pieBinary,
                                environment: probeEnvironment,
                                requested: "metal") else {
        throw LaunchError.driverUnsupported(
          requested: "metal",
          binary: pieBinary.path,
          details: "portable driver (provides the Metal device) is not compiled into this pie binary"
        )
      }
    }
  }

  /// Runs `pie driver list` and returns whether the embedded `portable`
  /// driver is compiled into this binary. Fails closed (throws
  /// `driverUnsupported`) on any spawn / non-zero-exit / parse failure.
  private static func probeDriverList(pieBinary: URL,
                                      environment: [String: String],
                                      requested: String) throws -> Bool {
    guard FileManager.default.fileExists(atPath: pieBinary.path) else {
      throw LaunchError.pieBinaryMissing(path: pieBinary.path)
    }
    let result: ProbeResult
    do {
      result = try runDriverListProbe(pieBinary: pieBinary, environment: environment)
    } catch let error as LaunchError {
      throw error
    } catch {
      throw LaunchError.driverUnsupported(
        requested: requested,
        binary: pieBinary.path,
        details: "`pie driver list` probe failed: \(error)"
      )
    }
    guard result.exitCode == 0 else {
      let detail = result.stderr.isEmpty ? result.stdout : result.stderr
      throw LaunchError.driverUnsupported(
        requested: requested,
        binary: pieBinary.path,
        details: "`pie driver list` probe exited \(result.exitCode): \(detail.trimmingCharacters(in: .whitespacesAndNewlines))"
      )
    }
    return try parseDriverList(
      result.stdout,
      pieBinary: pieBinary,
      requested: requested
    )
  }

  private struct ProbeResult {
    var exitCode: Int32
    var stdout: String
    var stderr: String
  }

  private static func runDriverListProbe(pieBinary: URL,
                                         environment: [String: String]) throws -> ProbeResult {
    let proc = Process()
    proc.executableURL = pieBinary
    // `pie driver list` is the documented driver-readiness surface — it
    // lists the embedded drivers compiled into the binary. (The older
    // `pie capabilities --json` still exists but is an undocumented,
    // feature-gated surface; standardize on `driver list` to avoid
    // coupling the launcher to it.)
    proc.arguments = ["driver", "list"]
    proc.environment = environment
    let stdout = Pipe()
    let stderr = Pipe()
    proc.standardOutput = stdout
    proc.standardError = stderr
    let stdoutCollector = PipeCollector(pipe: stdout)
    let stderrCollector = PipeCollector(pipe: stderr)
    stdoutCollector.start()
    stderrCollector.start()
    defer {
      stdoutCollector.stop()
      stderrCollector.stop()
    }

    try proc.run()
    let deadline = Date().addingTimeInterval(2)
    while proc.isRunning && Date() < deadline {
      Thread.sleep(forTimeInterval: 0.01)
    }
    if proc.isRunning {
      proc.terminate()
      throw LaunchError.driverUnsupported(
        requested: "driver list",
        binary: pieBinary.path,
        details: "`pie driver list` probe timed out"
      )
    }

    let outputDeadline = min(Date().addingTimeInterval(0.25), deadline)
    let stdoutClosed = stdoutCollector.waitForEOF(until: outputDeadline)
    let stderrClosed = stderrCollector.waitForEOF(until: outputDeadline)
    guard stdoutClosed && stderrClosed else {
      throw LaunchError.driverUnsupported(
        requested: "driver list",
        binary: pieBinary.path,
        details: "`pie driver list` probe output timed out"
      )
    }

    return ProbeResult(
      exitCode: proc.terminationStatus,
      stdout: stdoutCollector.stringValue(),
      stderr: stderrCollector.stringValue()
    )
  }

  private final class PipeCollector: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var data = Data()
    private var reachedEOF = false

    init(pipe: Pipe) {
      self.handle = pipe.fileHandleForReading
    }

    func start() {
      handle.readabilityHandler = { [weak self] handle in
        guard let self else { return }
        let chunk = handle.availableData
        lock.lock()
        if chunk.isEmpty {
          reachedEOF = true
        } else {
          data.append(chunk)
        }
        lock.unlock()
      }
    }

    func waitForEOF(until deadline: Date) -> Bool {
      while Date() < deadline {
        if hasReachedEOF() { return true }
        Thread.sleep(forTimeInterval: 0.01)
      }
      return hasReachedEOF()
    }

    func stop() {
      handle.readabilityHandler = nil
      try? handle.close()
    }

    func stringValue() -> String {
      lock.lock()
      let snapshot = data
      lock.unlock()
      return String(data: snapshot, encoding: .utf8) ?? ""
    }

    private func hasReachedEOF() -> Bool {
      lock.lock()
      defer { lock.unlock() }
      return reachedEOF
    }
  }

  /// Parse `pie driver list` output for the embedded `portable` driver.
  ///
  /// `pie driver list` prints, under an "Embedded drivers (compiled into
  /// this binary…)" section, one line per embedded driver:
  ///
  ///     portable     (compiled in)
  ///     cuda_native  (not compiled)
  ///     dummy        (compiled in)
  ///
  /// We need only `portable` — current pie has no separate "metal"
  /// readiness signal (Metal is the portable driver's macOS device,
  /// validated at serve boot), so the `.metal` gate also keys on
  /// `portable` being compiled in. Fails CLOSED if the output never
  /// mentions `portable` at all (an unexpected/changed CLI format), so a
  /// future drift is caught loud rather than passed blind. Returns
  /// whether the portable driver is compiled in.
  static func parseDriverList(_ text: String,
                              pieBinary: URL,
                              requested: String) throws -> Bool {
    let lines = text.split(separator: "\n").map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    let mentionsPortable = lines.contains { $0.hasPrefix("portable") }
    guard mentionsPortable else {
      throw LaunchError.driverUnsupported(
        requested: requested,
        binary: pieBinary.path,
        details: "`pie driver list` output did not list the portable driver: \(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))"
      )
    }
    return lines.contains {
      $0.hasPrefix("portable") && $0.contains("(compiled in)")
    }
  }

  // MARK: - aux socket path budget

  /// Darwin caps `sockaddr_un.sun_path` at 104 bytes (incl. NUL). The
  /// `pie serve` engine binds a per-launch aux control socket at
  /// `$PIE_HOME/standalone/<pid>/g<group>[r<rank>]/aux.sock` (pie
  /// `server/src/embedded_driver.rs`). A `PIE_HOME` deep enough to push
  /// that path past the limit makes the engine's `bind()` fail and it
  /// hangs at model load — the exact failure a too-deep
  /// `NSTemporaryDirectory()` pieHome produced. The pre-launch check
  /// below converts that hang into a loud, actionable error.
  static let auxSocketSunPathBytes = 104

  /// Modeled worst-case engine-appended suffix under PIE_HOME:
  /// `/standalone/<pid>/g0/aux.sock` — `/standalone/` (12) + a 7-digit
  /// pid allowance (well beyond macOS pid_max defaults) + `/g0/aux.sock`
  /// (12) = 31. Single-device Metal is always group 0; any multi-rank
  /// `r<n>` suffix stays within the pid slack.
  static let auxSocketSuffixReserve = 31

  /// Longest PIE_HOME (UTF-8 bytes) that still leaves room for the
  /// engine's aux socket path + NUL terminator: `104 - 1 - 31 = 72`.
  static var maxSafePieHomePathLength: Int {
    auxSocketSunPathBytes - 1 - auxSocketSuffixReserve
  }

  /// `nil` when `pieHome` leaves room for the engine's aux socket;
  /// otherwise the loud pre-launch error to throw. Pure + deterministic
  /// (no pid read) so it is directly unit-testable.
  static func auxSocketBudgetError(pieHome: URL) -> LaunchError? {
    let length = pieHome.path.utf8.count
    guard length > maxSafePieHomePathLength else { return nil }
    return .pieHomePathTooLong(
      pieHome: pieHome.path,
      length: length,
      limit: maxSafePieHomePathLength
    )
  }

  /// Whether `modelConfig` spawns a real driver that binds the aux Unix
  /// socket (and is therefore subject to the `sun_path` budget). The
  /// `.dummy` driver has no aux socket (pie `rpc_loop.rs`), so its
  /// launches are exempt — that keeps the long `NSTemporaryDirectory()`
  /// pieHomes used by the dummy-driver CLI scenarios valid.
  static func modelConfigBindsAuxSocket(_ modelConfig: ModelConfig) -> Bool {
    switch modelConfig {
    case .dummy: return false
    case .portable, .portableResolved, .metal: return true
    }
  }

  // MARK: - launch

  /// Returns the bound HTTP port and a `LaunchedSession` whose
  /// `shutdown()` tears the engine down idempotently.
  public static func launch(spec: LaunchSpec) async throws -> (httpPort: UInt16, session: LaunchedSession) {
    guard FileManager.default.fileExists(atPath: spec.pieBinary.path) else {
      throw LaunchError.pieBinaryMissing(path: spec.pieBinary.path)
    }
    // Fail loud before spawning if PIE_HOME is so deep the engine's aux
    // Unix socket path would overrun sun_path and hang. Only real drivers
    // (portable/metal) bind that socket.
    if modelConfigBindsAuxSocket(spec.modelConfig),
       let budgetError = auxSocketBudgetError(pieHome: spec.pieHome) {
      throw budgetError
    }
    let httpPort = try reserveFreePort()
    let configURL = try writeConfig(
      modelConfig: spec.modelConfig, defaultTokenLimit: spec.defaultTokenLimit, in: spec.pieHome
    )

    var env = spec.subprocessEnvironment
    env["PIE_HOME"] = spec.pieHome.path
    env["PIE_SHMEM_NAME"] = spec.shmemName

    let proc = Process()
    proc.executableURL = spec.pieBinary
    proc.arguments = ["serve", "--config", configURL.path, "--no-auth", "--debug"]
    proc.environment = env

    // Single pipe for stdout + stderr. The Python harness uses
    // `stderr=subprocess.STDOUT` for the same reason: pie under
    // `--debug` writes a lot to stderr (tracing layer), and a
    // separate Pipe whose reader we never drain would fill its
    // kernel buffer (~64 KiB) and block the child on write. Merging
    // both streams into one drained Pipe avoids the wedge.
    let stdout = Pipe()
    proc.standardOutput = stdout
    proc.standardError = stdout

    do {
      try proc.run()
    } catch {
      throw LaunchError.spawnFailed(underlying: "\(error)")
    }
    spec.pidSink?(proc.processIdentifier)

    let session = LaunchedSession(process: proc,
                                  stdout: stdout,
                                  shmemName: spec.shmemName,
                                  pieHome: spec.pieHome)

    let handshake: Handshake
    do {
      handshake = try await session.awaitHandshake(timeout: spec.handshakeTimeout)
    } catch {
      await session.shutdown()
      throw error
    }

    let wsURL = URL(string: "ws://\(handshake.address)")!
    // Retain the control-plane WS address so the session can re-open a
    // probe connection for post-launch liveness pings ( G1). The
    // launch client below is closed after launchDaemon; the probe
    // reconnects on demand.
    await session.recordControlWSURL(wsURL)
    let client = PieControlClient(url: wsURL)
    do {
      try await client.connect()
      try await client.authByToken(handshake.token)
      try await client.installProgram(wasmURL: spec.wasmURL,
                                      manifestURL: spec.manifestURL,
                                      forceOverwrite: true)
      try await client.launchDaemon(inferlet: spec.inferletNameAtVersion, port: UInt32(httpPort))
      await client.close()
    } catch {
      await client.close()
      await session.shutdown()
      throw LaunchError.clientError(underlying: "\(error)")
    }

    do {
      try writePortFile(port: httpPort, in: spec.pieHome)
    } catch {
      await session.shutdown()
      throw error
    }

    return (httpPort, session)
  }

  // MARK: - free port

  /// Bind 127.0.0.1:0, read the OS-assigned port, close the socket.
  /// Matches the Python `_free_port()` helper. There is a race
  /// between close + pie's later bind, but pie always picks a fresh
  /// port via `--http-listen :0` on its own — this free port is for
  /// the inferlet daemon, which the engine binds *after* the WS
  /// install completes. By that point the kernel has had the port
  /// in TIME_WAIT-free state long enough that reuse is reliable on
  /// loopback. Same race window as the Python reference.
  private static func reserveFreePort() throws -> UInt16 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    if fd < 0 { throw LaunchError.freePortBindFailed(errno: errno) }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    let bindRC = withUnsafePointer(to: &addr) { ptr -> Int32 in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
        bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    if bindRC != 0 { throw LaunchError.freePortBindFailed(errno: errno) }
    var out = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let gsnRC = withUnsafeMutablePointer(to: &out) { ptr -> Int32 in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
        getsockname(fd, sa, &len)
      }
    }
    if gsnRC != 0 { throw LaunchError.freePortGetSockNameFailed(errno: errno) }
    return UInt16(bigEndian: out.sin_port)
  }

  // MARK: - config + port file

  /// `pie serve --config` requires a config file. Two driver bodies
  /// today:
  ///  · `.dummy` — fast bring-up, no model bytes touched. Used by
  ///    `S0_TestIsolationTests` and the Python e2e harness.
  ///  · `.portable` — production driver (Metal on macOS). `hf_repo`
  ///    points at either a local app-staged GGUF path or an existing
  ///    HF snapshot directory/repo resolved by `LaunchSpecResolver`.
  ///    `pie serve` resolves `model.hf_repo` into the `hf_path` passed
  ///    down to `pie-driver-portable`.
  ///
  /// `[[model]].name` is the engine's *served* model id — what
  /// `/v1/models` advertises and what a chat-completion `model` field
  /// must equal (`chat-apc` validates the request `model` against
  /// `runtime::models()` and rejects a non-match with `model_not_found`).
  /// For production bodies it is `profile.model` verbatim, so the App
  /// sends the same slug it resolved the profile against — one id, no
  /// translation. `.dummy` keeps the synthetic `"default"` (no real
  /// model id exists). The `launch_daemon` control call passes no
  /// model, so the daemon binds to the single registered model
  /// regardless of its name.
  static func writeConfig(modelConfig: ModelConfig,
                          defaultTokenLimit: Int? = nil,
                          in pieHome: URL) throws -> URL {
    let configURL = pieHome.appendingPathComponent("config.toml")
    let body = renderConfigBody(modelConfig: modelConfig, defaultTokenLimit: defaultTokenLimit)
    do {
      try FileManager.default.createDirectory(at: pieHome, withIntermediateDirectories: true)
      try body.write(to: configURL, atomically: true, encoding: .utf8)
    } catch {
      throw LaunchError.configWriteFailed(path: configURL.path, underlying: "\(error)")
    }
    return configURL
  }

  /// Pure TOML projection of `ModelConfig`. Internal so the unit
  /// tests can pin the emitted body without writing to disk.
  static func renderConfigBody(modelConfig: ModelConfig,
                               defaultTokenLimit: Int? = nil) -> String {
    let preamble = """
    [server]
    host = "127.0.0.1"
    port = 0

    [auth]
    enabled = false

    [telemetry]
    enabled = false

    [runtime]
    allow_fs = false
    allow_network = true

    """
    // #438: the memory-aware per-request output ceiling rides
    // `default_token_limit` (the scheduler's total-token compute cap).
    // chat-apc follows it via `runtime::max-output-tokens`. Omitted when
    // nil → engine keeps its default (no clamp).
    let limitLine = defaultTokenLimit.map { "\ndefault_token_limit = \($0)" } ?? ""
    let scheduler = """

    [model.scheduler]
    batch_policy = "adaptive"
    request_timeout_secs = 60
    default_endowment_pages = 4
    admission_oversubscription_factor = 8.0
    restore_pause_at_utilization = 0.85\(limitLine)

    """
    switch modelConfig {
    case .dummy:
      let model = """
      [[model]]
      name = "default"
      hf_repo = "Qwen/Qwen3-0.6B"
      """
      let driver = """

      [model.driver]
      type = "dummy"
      device = ["cpu"]

      [model.driver.options]
      vocab_size = 32000
      arch_name = "test"
      """
      return preamble + model + scheduler + driver
    case let .portable(modelSlug, modelsRoot):
      // Join modelsRoot + slug the same way LaunchSpecResolver does so
      // the path we write into TOML matches what the downloader put
      // on disk (multi-segment `<repo>/<file>` slugs do NOT get
      // percent-escaped — review v150 F8). The slug is also the served
      // id (`name`).
      let modelPath = LaunchSpecResolver.joinModelPath(
        modelsRoot: modelsRoot, slug: modelSlug
      )
      return renderPortableModel(
        servedID: modelSlug, modelRef: modelPath, preamble: preamble,
        scheduler: scheduler
      )
    case let .portableResolved(servedModelID, modelRef):
      return renderPortableModel(
        servedID: servedModelID, modelRef: modelRef, preamble: preamble,
        scheduler: scheduler
      )
    case let .metal(modelID):
      // `pie-driver-portable` with ggml-metal selected at C++ build
      // time (Scripts/build-pie-engine.sh sets PIE_PORTABLE_METAL=1).
      // Review v3 F5: pin `device = ["metal"]` explicitly. `"auto"`
      // would silently fall back to CPU on a host built without
      // PIE_PORTABLE_METAL=1 or running on non-Apple-Silicon, masking
      // a broken Metal toolchain as a green test. With `"metal"` the
      // engine fails loud at boot when the Metal backend wasn't
      // compiled in. `hf_repo` defers snapshot resolution to pie's
      // HF resolver against `~/.cache/huggingface/hub`.
      let model = """
      [[model]]
      name = \(tomlString(modelID))
      hf_repo = \(tomlString(modelID))
      """
      let driver = """

      [model.driver]
      type = "portable"
      device = ["metal"]
      """
      return preamble + model + scheduler + driver
    }
  }

  private static func renderPortableModel(servedID: String,
                                          modelRef: String,
                                          preamble: String,
                                          scheduler: String) -> String {
    let model = """
    [[model]]
    name = \(tomlString(servedID))
    hf_repo = \(tomlString(modelRef))
    """
    let driver = """

    [model.driver]
    type = "portable"
    device = ["metal"]
    """
    return preamble + model + scheduler + driver
  }

  /// Minimal TOML basic-string escape: wrap in `"..."` and backslash-
  /// escape `\` + `"`. macOS filesystem paths cannot contain NUL bytes
  /// or raw newlines, so the basic-string form is sufficient — no
  /// multi-line / literal-string fallback needed. The path itself is
  /// the only caller-supplied value that can carry quotes; quoting
  /// defends against a profile-supplied model slug containing one.
  private static func tomlString(_ value: String) -> String {
    let escaped = value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
  }

  /// Atomic write of `<PIE_HOME>/http.port`. `IsolatedTestCase.
  /// boundHTTPPort()` polls this; an atomic write avoids the
  /// "file opened mid-write" race that would surface as
  /// `boundPortMalformed`.
  private static func writePortFile(port: UInt16, in pieHome: URL) throws {
    let target = pieHome.appendingPathComponent("http.port")
    let tmp = pieHome.appendingPathComponent("http.port.tmp")
    do {
      try "\(port)\n".write(to: tmp, atomically: true, encoding: .utf8)
      try FileManager.default.moveItem(at: tmp, to: target)
    } catch {
      // Replace-existing fallback if `moveItem` failed because the
      // target already exists (test-rerun in the same PIE_HOME).
      do {
        _ = try FileManager.default.replaceItemAt(target, withItemAt: tmp)
      } catch {
        throw LaunchError.portFileWriteFailed(path: target.path, underlying: "\(error)")
      }
    }
  }

  fileprivate struct Handshake {
    let address: String
    let token: String
  }
}

// MARK: - LaunchedSession

/// Owns the spawned `pie serve` subprocess + its pipes. Idempotent
/// shutdown is implemented in one place so the launcher's error
/// paths and the caller's `defer { await session.shutdown() }` both
/// converge here.
public actor LaunchedSession {

  private let process: Process
  private let stdout: Pipe  // stderr is merged into this (see launch())
  private let shmemName: String
  private let pieHome: URL
  private var collectedLines: [String] = []
  /// Last 32 lines are enough for a timeout diagnostic.
  private static let recentLineLimit = 32
  private var shutdownDone = false
  /// Control-plane WS address, retained post-handshake so liveness
  /// probes can reconnect ( G1). `nil` until `launch()` records it.
  private var controlWSURL: URL?
  /// Username sent on the probe's `auth_identify`. Any value works on
  /// the launcher's `--no-auth` engine; not the internal token.
  private static let livenessProbeIdentity = "pie-mac-liveness"
  /// Bound on a single probe round-trip so a wedged engine that accepts
  /// the socket but never answers can't hang the monitor.
  private static let livenessProbeTimeout: TimeInterval = 5

  fileprivate init(process: Process, stdout: Pipe,
                   shmemName: String, pieHome: URL) {
    self.process = process
    self.stdout = stdout
    self.shmemName = shmemName
    self.pieHome = pieHome
  }

  // MARK: - public surface

  public var pid: pid_t { process.processIdentifier }
  public var isRunning: Bool { process.isRunning }

  /// Resident memory of the live pie process in bytes, or nil if the
  /// engine is not running or the sample fails. Satisfies
  /// `PieEngineHost.EngineSession`. Reads the actor-owned pid, then defers
  /// to the nonisolated `proc_pid_rusage` helper. Measures the parent pie
  /// process only; summing the process group is a deliberate follow-up.
  ///
  /// Liveness gate: never sample a dead/reaped engine. Foundation flips
  /// `process.isRunning` false the instant the child exits — well before
  /// `PieEngineHost`'s liveness monitor takes
  /// ~`livenessFailureThreshold × livenessInterval` (~10 s) to demote
  /// `_state` from `.running` — so this closes the window where the
  /// popover would otherwise render a dead engine's STALE RSS (measured:
  /// `proc_pid_rusage` returns rc==0 with ~1.2 MB of stale bytes for a
  /// zombie pid). The static helper re-checks the raw pid as defence.
  public func residentMemoryBytes() async -> UInt64? {
    guard process.isRunning else { return nil }
    return LaunchedSession.residentMemory(ofPID: process.processIdentifier)
  }

  /// `proc_pid_rusage(RUSAGE_INFO_V2)` → `ri_resident_size` for `pid`, or
  /// nil when `pid` is not a live process or the sample is not a real
  /// reading. `static` (nonisolated) so unit tests can sample a known pid
  /// (e.g. `getpid()`) without standing up an actor.
  ///
  /// Two gates beyond rc:
  ///  · LIVENESS — `proc_pid_rusage` returns rc==0 with STALE non-zero
  ///    bytes for a zombie (exited-but-unreaped) pid, and the OS may reuse
  ///    a dead pid for an unrelated process. `isPidLive` rejects both, so
  ///    a dead engine never reports phantom (or someone else's) memory.
  ///  · NON-ZERO — a live engine is never 0-resident; rc==0 with 0 bytes
  ///    is an edge/failed reading, not a measurement, so it collapses into
  ///    the same nil ("unavailable") channel rather than rendering "0 MB".
  static func residentMemory(ofPID pid: pid_t) -> UInt64? {
    guard isPidLive(pid) else { return nil }
    var info = rusage_info_v2()
    let rc = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
      ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
        proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
      }
    }
    guard rc == 0 else { return nil }
    guard info.ri_resident_size > 0 else { return nil }
    return info.ri_resident_size
  }

  /// True only when `pid` names a LIVE process — not a zombie
  /// (exited-but-unreaped) nor a vanished/reused-dead pid. Measured:
  /// `proc_pidinfo(PROC_PIDTBSDINFO)` returns the struct size for a live
  /// process and 0 for a zombie or a gone pid, so a short read means
  /// "not live"; the `SZOMB` check is defensive belt-and-suspenders. This
  /// is the pid-validity guard `proc_pid_rusage` itself cannot provide.
  static func isPidLive(_ pid: pid_t) -> Bool {
    guard pid > 0 else { return false }
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
    return n == size && info.pbi_status != UInt32(SZOMB)
  }

  /// Record the control-plane WS address for later liveness probes.
  /// Called once by `launch()` after the handshake resolves it.
  func recordControlWSURL(_ url: URL) { controlWSURL = url }

  /// Post-launch liveness verdict for `PieEngineHost`'s monitor (
  /// G1). Two signals, no  dependency:
  ///  1. Process exit — definitive death. Cheap; catches crashes.
  ///  2. Control-plane ping — catches a hang where the process is alive
  ///     but the engine stopped servicing the WS. Reconnects a fresh
  ///     `PieControlClient` (the launch client was closed), authenticates
  ///     (`--no-auth` accepts any identify), and pings; a Pong means
  ///     alive, any failure/timeout means gone. The control-plane ping
  ///     hits the pie ENGINE (server.rs), distinct from `/healthz` which
  ///     hits the inferlet — that is what lets the caller tell engine
  ///     death from an inferlet rejection.
  public func checkLiveness() async -> EngineLiveness {
    if !process.isRunning {
      return .gone(reason: "engine process exited (status \(process.terminationStatus))")
    }
    guard let controlWSURL else {
      // Pre-handshake (address not yet recorded): the process is up;
      // defer to the next probe rather than declaring a false death.
      return .alive
    }
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = Self.livenessProbeTimeout
    config.timeoutIntervalForResource = Self.livenessProbeTimeout
    let client = PieControlClient(url: controlWSURL, session: URLSession(configuration: config))
    do {
      try await client.connect()
      try await client.authIdentify(Self.livenessProbeIdentity)
      try await client.ping()
      await client.close()
      return .alive
    } catch {
      await client.close()
      return .gone(reason: "engine control plane unreachable: \(error)")
    }
  }

  /// Idempotent: SIGINT → wait(10s) → SIGKILL → wait(5s) → shm_unlink.
  /// Mirrors Python `_terminate_subprocess` + `_shm_unlink_quiet`.
  /// Any error inside is logged to stderr but never re-thrown — the
  /// caller already failed; making cleanup throwable would just
  /// mask the original error.
  public func shutdown() async {
    guard !shutdownDone else { return }
    shutdownDone = true

    if process.isRunning {
      sendSignalQuiet(SIGINT, label: "SIGINT")
      let exited = await waitForExit(timeout: 10)
      if !exited {
        diagnose("SIGINT timed out after 10s; escalating to SIGKILL")
        sendSignalQuiet(SIGKILL, label: "SIGKILL")
        let killed = await waitForExit(timeout: 5)
        if !killed {
          diagnose("SIGKILL + 5s waitpid window did not reap pid \(process.processIdentifier); leaking to process exit")
        }
      }
    }

    // Close pipe so any reader (awaitHandshake's task, if still
    // running) sees EOF.
    try? stdout.fileHandleForReading.close()

    shmUnlinkQuiet(shmemName)
  }

  /// Reads stdout until both handshake markers appear or the
  /// timeout/exit window elapses. Stdout lines are also buffered
  /// in `collectedLines` for diagnostics on failure paths.
  ///
  /// Implementation: `FileHandle.readabilityHandler` is the only
  /// stable non-blocking pipe-reader macOS offers from Swift —
  /// `read(upToCount:)` blocks until at least one byte arrives,
  /// which deadlocks if pie's stdout buffers a partial line and
  /// then waits for WS install before flushing more. A handler-driven
  /// AsyncStream covers both the "burst then quiet" and "early-exit"
  /// cases without us spinning a poll loop on a DispatchSource.
  fileprivate func awaitHandshake(timeout: TimeInterval) async throws -> PieControlLauncher.Handshake {
    let urlRegex = try! NSRegularExpression(pattern: #"pie-server serving on (\S+:\d+)"#)
    let tokRegex = try! NSRegularExpression(pattern: #"internal token: (\S+)"#)
    let started = Date()
    let lines = startLineStream()

    return try await withThrowingTaskGroup(of: PieControlLauncher.Handshake.self) { group in
      // Reader child — yields the Handshake when both markers
      // appear or throws engineExitedEarly when pie dies.
      group.addTask { [weak self] in
        var address: String?
        var token: String?
        for await line in lines {
          await self?.append(line: line)
          if address == nil, let m = await self?.match(urlRegex, in: line) { address = m }
          if token == nil, let m = await self?.match(tokRegex, in: line) { token = m }
          if let a = address, let t = token {
            return PieControlLauncher.Handshake(address: a, token: t)
          }
          // #2 root: confirm a REAL exit before classifying engineExitedEarly.
          // `process.isRunning` is wait4-backed and can momentarily misread a
          // still-loading engine under heavy model-load pressure; a brief
          // settle + re-check separates a true exit from a transient blip, so a
          // live engine is never mislabeled `.spawnFailed`.
          if await self?.confirmedExit() == true {
            throw PieControlLauncher.LaunchError.engineExitedEarly(
              code: Int32((await self?.terminationStatusIfExited()) ?? -1),
              stderrTail: (await self?.recentLinesJoined()) ?? ""
            )
          }
        }
        // Stream finished (stdout EOF or parent cancellation). Only a
        // CONFIRMED process exit is `engineExitedEarly`; a benign EOF while the
        // engine is still alive (stdout closed before READY) falls back to the
        // handshake timeout rather than a spurious early-exit (#2 root).
        if await self?.confirmedExit() == true {
          throw PieControlLauncher.LaunchError.engineExitedEarly(
            code: Int32((await self?.terminationStatusIfExited()) ?? -1),
            stderrTail: (await self?.recentLinesJoined()) ?? ""
          )
        }
        throw PieControlLauncher.LaunchError.handshakeTimeout(
          elapsed: Date().timeIntervalSince(started),
          lastLines: (await self?.recentLines()) ?? []
        )
      }
      // Timeout child — wins if the reader doesn't find both
      // markers within `timeout`.
      group.addTask { [weak self] in
        try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        throw PieControlLauncher.LaunchError.handshakeTimeout(
          elapsed: Date().timeIntervalSince(started),
          lastLines: (await self?.recentLines()) ?? []
        )
      }
      // Whoever wins, cancel the other and surface the result.
      defer { group.cancelAll() }
      guard let first = try await group.next() else {
        throw PieControlLauncher.LaunchError.handshakeTimeout(
          elapsed: Date().timeIntervalSince(started), lastLines: []
        )
      }
      return first
    }
  }

  private func recentLines() -> [String] { Array(collectedLines.suffix(Self.recentLineLimit)) }
  private func recentLinesJoined() -> String { recentLines().joined(separator: "\n") }
  private func isProcessRunning() -> Bool { process.isRunning }
  private func terminationStatusIfExited() -> Int32 {
    process.isRunning ? -1 : process.terminationStatus
  }

  /// Confirm a REAL subprocess exit before classifying `engineExitedEarly`.
  /// Foundation's `process.isRunning` is wait4-backed and can momentarily
  /// misread under load (the same class of race as the supervisor handshake
  /// timeout); one brief settle + re-check separates a true exit from a
  /// transient blip or a benign stdout EOF while the engine is still loading
  /// (#2 root). Returns true only when the process is confirmed not-running
  /// after the settle.
  private func confirmedExit() async -> Bool {
    guard !process.isRunning else { return false }
    try? await Task.sleep(nanoseconds: 250_000_000)
    return !process.isRunning
  }

  /// Streams `\n`-terminated lines from `stdout` until either:
  ///   - the deadline (the parent `awaitHandshake` task cancels), OR
  ///   - the pipe sees EOF (subprocess exited and reader returned 0 bytes).
  private func startLineStream() -> AsyncStream<String> {
    let fh = stdout.fileHandleForReading
    let carryBox = LineCarry()
    return AsyncStream { cont in
      // Hook readabilityHandler — fires on every byte the kernel
      // ships up the pipe. Each call gets *some* data (never
      // partial below 1 byte) or empty Data on EOF.
      fh.readabilityHandler = { handle in
        let chunk = handle.availableData
        if chunk.isEmpty {
          handle.readabilityHandler = nil
          cont.finish()
          return
        }
        for line in carryBox.feed(chunk) {
          cont.yield(line)
        }
      }
      cont.onTermination = { _ in
        // Drop the handler so the kernel buffer drains naturally
        // into close(); we don't want stale callbacks firing into
        // a finished continuation.
        fh.readabilityHandler = nil
      }
    }
  }

  // MARK: - private

  /// Token-bearing lines are redacted before being appended to the
  /// diagnostic buffer. Both `engineExitedEarly.stderrTail` and
  /// `handshakeTimeout.lastLines` are surfaced verbatim to callers
  /// and may end up in crash reports or log aggregators (review 
  /// F1). Even though the token is loopback-scoped, never store live
  /// credentials in error descriptions. Redaction happens at the
  /// entry point so every consumer of `collectedLines`
  /// (`recentLines`, `recentLinesJoined`) is safe by construction.
  private func append(line: String) {
    collectedLines.append(Self.redactToken(in: line))
    if collectedLines.count > Self.recentLineLimit * 4 {
      collectedLines.removeFirst(collectedLines.count - Self.recentLineLimit * 2)
    }
  }

  /// Replaces `internal token: <opaque>` with `internal token: <REDACTED>`.
  /// `nonisolated` + `static` so the matching regex (the same one
  /// `awaitHandshake` uses to capture) is the single source of truth
  /// for what a token line looks like.
  static func redactToken(in line: String) -> String {
    let pattern = #"internal token: \S+"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return line }
    let range = NSRange(line.startIndex..., in: line)
    return regex.stringByReplacingMatches(in: line,
                                          range: range,
                                          withTemplate: "internal token: <REDACTED>")
  }

  private func match(_ regex: NSRegularExpression, in line: String) -> String? {
    let range = NSRange(line.startIndex..., in: line)
    guard let m = regex.firstMatch(in: line, range: range), m.numberOfRanges >= 2,
          let r = Range(m.range(at: 1), in: line)
    else { return nil }
    return String(line[r])
  }

  private func sendSignalQuiet(_ sig: Int32, label: String) {
    let rc = kill(process.processIdentifier, sig)
    if rc != 0 {
      let e = errno
      if e == ESRCH {
        diagnose("\(label) raced ESRCH; subprocess already exited")
      } else {
        diagnose("\(label) failed errno=\(e)")
      }
    }
  }

  private func waitForExit(timeout: TimeInterval) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if !process.isRunning { return true }
      try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return !process.isRunning
  }

  private func readAll(_ fh: FileHandle) -> [UInt8] {
    let data = (try? fh.readToEnd()) ?? Data()
    return Array(data)
  }

  /// Quiet best-effort `shm_unlink`. Matches the Python `_shm_unlink_quiet`
  /// helper: announces itself, never throws. POSIX shmem is
  /// host-global, so a leaked region persists across runs and a
  /// later run that recycles the same pid would attach to stale
  /// geometry.
  ///
  /// pie's `pie-driver-dummy` (and any single-shard driver) appends
  /// `_g<shard>` to the env-supplied `PIE_SHMEM_NAME` before calling
  /// `shm_open`; verified at runtime: passing `/pie_t_<pid>_<uuid>`
  /// produces `/pie_t_<pid>_<uuid>_g0`. We unlink BOTH the base and
  /// the `_g0` shard so neither leaks. Multi-shard drivers will need
  /// to broaden this; that's the carry-over of review  nit 6c.
  private func shmUnlinkQuiet(_ name: String) {
    unlinkOne(name)
    unlinkOne(name + "_g0")
  }

  private func unlinkOne(_ name: String) {
    let rc = name.withCString { c in shm_unlink(c) }
    if rc == 0 {
      diagnose("shm_unlink(\(name)) OK")
    } else if errno == ENOENT {
      diagnose("shm_unlink(\(name)) ENOENT (already gone)")
    } else {
      diagnose("shm_unlink(\(name)) FAILED errno=\(errno)")
    }
  }

  private nonisolated func diagnose(_ msg: String) {
    // Route through the unified log so shutdown anomalies (SIGKILL did
    // not reap the pid, `shm_unlink` FAILED — both host-global corruption
    // vectors) are visible in the shipped, detached Helper, where stderr
    // is not captured. Keep the stderr write too for CLI/test contexts
    // that DO capture it.
    Log.engine.error("[LaunchedSession] \(msg, privacy: .public)")
    FileHandle.standardError.write(Data("[LaunchedSession] \(msg)\n".utf8))
  }
}

// MARK: - LineCarry

/// Mutable carry buffer for the readabilityHandler-driven line stream.
/// Lives outside the actor so the handler closure (which runs on
/// arbitrary queues) does not need to hop onto the actor for every
/// byte. The carry is appended-to from one queue (the FileHandle's
/// readability dispatch queue) and `feed()` is the only mutator;
/// `@unchecked Sendable` documents the invariant.
// MARK: - PieEngineHost.EngineSession conformance

/// Bridge so `PieEngineHost` can hold `LaunchedSession` behind its
/// minimal `EngineSession` protocol. The actor's own
/// `shutdown() async` already matches the protocol; declaring the
/// conformance here keeps the bridge next to the type rather than
/// scattered across modules.
extension LaunchedSession: PieEngineHost.EngineSession {}

fileprivate final class LineCarry: @unchecked Sendable {
  private var carry: Data = Data()

  /// Appends `chunk` and returns any newly-complete lines. Lines are
  /// stripped of trailing `\r\n` / `\n`. Partial trailing data stays
  /// in `carry` for the next feed.
  func feed(_ chunk: Data) -> [String] {
    carry.append(chunk)
    var out: [String] = []
    while let nlIdx = carry.firstIndex(of: 0x0a) {
      let lineData = carry[carry.startIndex ..< nlIdx]
      carry.removeSubrange(carry.startIndex ... nlIdx)
      var s = String(data: lineData, encoding: .utf8) ?? ""
      if s.hasSuffix("\r") { s.removeLast() }
      out.append(s)
    }
    return out
  }
}
