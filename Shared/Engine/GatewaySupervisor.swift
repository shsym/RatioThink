import Foundation

/// Spawns and supervises `ratio-gateway` as a sibling process of the engine.
///
/// Design decision (2026-08-01): the gateway is a **supervised sibling
/// process**, not a library linked into the helper. So something must own its
/// lifecycle and publish its port, and that is this type.
///
/// Why the port matters more than it looks: the app does NOT read
/// `<PIE_HOME>/http.port`. `HTTPEngineClient` resolves its base URL from
/// `EngineStatus.running(port:)` (`EngineStatusStore.baseURL`), which
/// `PieEngineHost` publishes from whatever `PieControlLauncher.launch`
/// returns. Redirecting the app to the gateway therefore means returning the
/// GATEWAY's port from the launcher — rewriting the port file only moves test
/// harnesses.
///
/// The gateway runs in **attach** mode: `pie serve` is already up and owned by
/// `PieControlLauncher`, so the gateway is handed the existing control address
/// and token rather than spawning an engine of its own.
public actor GatewaySupervisor {

  public enum SupervisorError: Error, CustomStringConvertible {
    case binaryMissing(path: String)
    case readinessTimeout(elapsed: TimeInterval, tail: [String])
    case exitedEarly(code: Int32, tail: [String])

    public var description: String {
      switch self {
      case let .binaryMissing(path):
        return "GatewaySupervisor: ratio-gateway not found at \(path)"
      case let .readinessTimeout(elapsed, tail):
        return "GatewaySupervisor: not ready within \(elapsed)s — last output:\n  - "
          + tail.joined(separator: "\n  - ")
      case let .exitedEarly(code, tail):
        return "GatewaySupervisor: exited early (code \(code)):\n  - "
          + tail.joined(separator: "\n  - ")
      }
    }
  }

  public struct Spec: Sendable {
    /// `Rational.app/Contents/Resources/gateway/ratio-gateway`
    public let binary: URL
    /// Directory holding `chat.wasm` + `chat.Pie.toml`.
    public let inferlets: URL
    /// Control-plane address of the already-running engine, e.g.
    /// `ws://127.0.0.1:53211`.
    public let pieURL: String
    /// The engine's `internal token:` from the launch handshake.
    public let pieToken: String
    public let readinessTimeout: TimeInterval

    public init(
      binary: URL, inferlets: URL, pieURL: String, pieToken: String,
      readinessTimeout: TimeInterval = 30
    ) {
      self.binary = binary
      self.inferlets = inferlets
      self.pieURL = pieURL
      self.pieToken = pieToken
      self.readinessTimeout = readinessTimeout
    }
  }

  private var process: Process?
  /// Remembered so health can be re-probed after startup. Readiness alone is
  /// not supervision: a gateway that dies later leaves the app pinned to a
  /// dead port while pie itself stays perfectly healthy.
  private var boundPort: UInt16?
  private var tail: [String] = []
  private let tailLimit = 40

  public init() {}

  /// Boots the gateway and returns the port it bound.
  ///
  /// Readiness is an explicit `/healthz` probe rather than "the process is
  /// alive": the app publishes this port as `EngineStatus.running`, and a
  /// premature publish would let the first chat request race the listener.
  public func start(spec: Spec) async throws -> UInt16 {
    guard FileManager.default.fileExists(atPath: spec.binary.path) else {
      throw SupervisorError.binaryMissing(path: spec.binary.path)
    }

    let portFile = FileManager.default.temporaryDirectory
      .appendingPathComponent("ratio-gateway-\(ProcessInfo.processInfo.processIdentifier).port")
    try? FileManager.default.removeItem(at: portFile)

    let proc = Process()
    proc.executableURL = spec.binary
    proc.arguments = [
      "--listen", "127.0.0.1:0",           // ephemeral; we read the real port back
      "--pie-url", spec.pieURL,
      "--pie-token", spec.pieToken,
      // The gateway scans this directory for `{name}.wasm` + `{name}.Pie.toml`
      // pairs, so shipping a new inferlet is a bundle change, not a code change.
      // No `--admin-token`: the bundle is read-only and reload would have
      // nothing new to find, so /v1/admin/reload stays disabled here.
      "--inferlet-dir", spec.inferlets.path,
      "--port-file", portFile.path,
    ]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = pipe

    let handle = pipe.fileHandleForReading
    handle.readabilityHandler = { [weak self] h in
      let data = h.availableData
      guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
      Task { await self?.appendTail(text) }
    }

    try proc.run()
    self.process = proc

    let deadline = Date().addingTimeInterval(spec.readinessTimeout)
    while Date() < deadline {
      if !proc.isRunning {
        throw SupervisorError.exitedEarly(code: proc.terminationStatus, tail: await currentTail())
      }
      if let port = readPort(portFile), await probeHealthz(port: port) {
        boundPort = port
        return port
      }
      try? await Task.sleep(nanoseconds: 100_000_000)
    }
    await shutdown(reason: "readiness_timeout")
    throw SupervisorError.readinessTimeout(
      elapsed: spec.readinessTimeout, tail: await currentTail())
  }

  /// Ongoing health verdict, for the engine session's liveness ladder.
  ///
  /// Two signals, cheapest first: the child process, then an actual `/healthz`
  /// round trip — a wedged gateway can still be "running".
  public func health() async -> String? {
    guard let proc = process else { return nil }   // never started / already torn down
    if !proc.isRunning {
      return "gateway process exited (code \(proc.terminationStatus))"
    }
    guard let port = boundPort else { return nil } // pre-readiness; defer
    if await probeHealthz(port: port) { return nil }
    return "gateway /healthz unreachable on port \(port)"
  }

  private func readPort(_ file: URL) -> UInt16? {
    guard let s = try? String(contentsOf: file, encoding: .utf8) else { return nil }
    return UInt16(s.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  private func probeHealthz(port: UInt16) async -> Bool {
    guard let url = URL(string: "http://127.0.0.1:\(port)/healthz") else { return false }
    var req = URLRequest(url: url)
    req.timeoutInterval = 2
    guard let (_, resp) = try? await URLSession.shared.data(for: req),
          let http = resp as? HTTPURLResponse
    else { return false }
    return http.statusCode == 200
  }

  private func appendTail(_ text: String) {
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
      tail.append(String(line))
    }
    if tail.count > tailLimit { tail.removeFirst(tail.count - tailLimit) }
  }

  private func currentTail() async -> [String] { tail }

  /// Idempotent. SIGTERM, then SIGKILL if it does not exit — mirroring the
  /// engine's own teardown discipline.
  public func shutdown(reason: String) async {
    guard let proc = process else { return }
    process = nil
    boundPort = nil
    guard proc.isRunning else { return }
    proc.terminate()
    for _ in 0..<50 where proc.isRunning {
      try? await Task.sleep(nanoseconds: 100_000_000)
    }
    if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
    NSLog("GatewaySupervisor: shut down (\(reason))")
  }
}

/// Which backend serves `/v1/chat/completions`.
///
/// The A/B switch phase 5 exists to deliver: `RATIO_CHAT_BACKEND=gateway`
/// routes the app through `ratio-gateway` + `chat.wasm`; anything else keeps
/// the chat-apc daemon. Defaults to `daemon` so the flag is opt-in until the
/// phase-6 flip.
public enum ChatBackend: String, Sendable {
  case daemon
  case gateway

  public static func fromEnvironment(
    _ env: [String: String] = ProcessInfo.processInfo.environment
  ) -> ChatBackend {
    ChatBackend(rawValue: env["RATIO_CHAT_BACKEND"]?.lowercased() ?? "") ?? .daemon
  }
}
