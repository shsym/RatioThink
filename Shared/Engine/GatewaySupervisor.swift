import Foundation

/// Owns the gateway process attached to a helper-owned PIE engine.
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
  private var standardInput: Pipe?
  private var boundPort: UInt16?
  private var publishedPort: UInt16?
  private var spec: Spec?
  private var portFile: URL?
  private var shutdownInProgress = false
  private var shutdownResult: EngineShutdownResult?
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
    self.spec = spec
    self.portFile = portFile
    let port = try await startProcess(spec: spec, port: 0, portFile: portFile)
    publishedPort = port
    return port
  }

  private func startProcess(spec: Spec, port: UInt16, portFile: URL) async throws -> UInt16 {
    try removePortFile(portFile)

    let proc = Process()
    proc.executableURL = spec.binary
    proc.arguments = [
      "--listen", "127.0.0.1:\(port)",
      "--pie-url", spec.pieURL,
      "--pie-token", spec.pieToken,
      "--inferlet-dir", spec.inferlets.path,
      "--port-file", portFile.path,
      "--exit-on-stdin-eof",
    ]
    let output = Pipe()
    let input = Pipe()
    proc.standardOutput = output
    proc.standardError = output
    proc.standardInput = input

    let handle = output.fileHandleForReading
    handle.readabilityHandler = { [weak self] h in
      let data = h.availableData
      guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
      Task { await self?.appendTail(text) }
    }

    do {
      try proc.run()
    } catch {
      handle.readabilityHandler = nil
      try? removePortFile(portFile)
      throw error
    }
    self.process = proc
    self.standardInput = input

    let deadline = Date().addingTimeInterval(spec.readinessTimeout)
    while Date() < deadline {
      if !proc.isRunning {
        _ = await stopCurrentProcess()
        throw SupervisorError.exitedEarly(code: proc.terminationStatus, tail: await currentTail())
      }
      if let port = readPort(portFile), await probeHealthz(port: port) {
        boundPort = port
        return port
      }
      try? await Task.sleep(nanoseconds: 100_000_000)
    }
    _ = await stopCurrentProcess()
    throw SupervisorError.readinessTimeout(
      elapsed: spec.readinessTimeout, tail: await currentTail())
  }

  /// Ongoing health verdict, for the engine session's liveness ladder.
  ///
  /// Two signals, cheapest first: the child process, then an actual `/healthz`
  /// round trip — a wedged gateway can still be "running".
  public func health() async -> String? {
    guard let proc = process else {
      return spec == nil || shutdownResult != nil ? nil : "gateway process unavailable"
    }
    if !proc.isRunning {
      return "gateway process exited (code \(proc.terminationStatus))"
    }
    guard let port = boundPort else { return nil } // pre-readiness; defer
    if await probeHealthz(port: port) { return nil }
    return "gateway /healthz unreachable on port \(port)"
  }

  /// Restarts only the gateway on its published port when PIE is still alive.
  public func recoverIfNeeded() async -> String? {
    guard let failure = await health() else { return nil }
    guard !shutdownInProgress, shutdownResult == nil,
          let spec, let port = publishedPort, let portFile
    else { return failure }

    let stopped = await stopCurrentProcess()
    guard stopped.reaped else {
      return "\(failure); gateway could not be reaped: \(stopped.message)"
    }
    do {
      _ = try await startProcess(spec: spec, port: port, portFile: portFile)
      return nil
    } catch {
      return "\(failure); gateway recovery failed: \(error)"
    }
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

  public func shutdown(reason: String) async -> EngineShutdownResult {
    if let shutdownResult { return shutdownResult }
    if shutdownInProgress {
      while shutdownResult == nil {
        try? await Task.sleep(nanoseconds: 10_000_000)
      }
      return shutdownResult ?? .unreaped("gateway shutdown did not complete")
    }
    shutdownInProgress = true
    let result = await stopCurrentProcess()
    shutdownResult = result
    NSLog("GatewaySupervisor: shut down (\(reason))")
    return result
  }

  private func stopCurrentProcess() async -> EngineShutdownResult {
    guard let proc = process else {
      if let portFile { try? removePortFile(portFile) }
      return .reaped
    }
    let input = standardInput
    process = nil
    standardInput = nil
    boundPort = nil
    try? input?.fileHandleForWriting.close()
    for _ in 0..<20 where proc.isRunning {
      try? await Task.sleep(nanoseconds: 100_000_000)
    }
    if proc.isRunning {
      proc.terminate()
      for _ in 0..<50 where proc.isRunning {
        try? await Task.sleep(nanoseconds: 100_000_000)
      }
    }
    if proc.isRunning {
      kill(proc.processIdentifier, SIGKILL)
      for _ in 0..<50 where proc.isRunning {
        try? await Task.sleep(nanoseconds: 100_000_000)
      }
    }
    if let portFile { try? removePortFile(portFile) }
    return proc.isRunning
      ? .unreaped("SIGKILL did not reap gateway pid \(proc.processIdentifier)")
      : .reaped
  }

  private func removePortFile(_ file: URL) throws {
    do {
      try FileManager.default.removeItem(at: file)
    } catch CocoaError.fileNoSuchFile {
      return
    }
  }

  func processIdentifierForTesting() -> Int32? { process?.processIdentifier }
  func portFileForTesting() -> URL? { portFile }
}

/// Which backend serves `/v1/chat/completions`.
public enum ChatBackend: String, Sendable {
  case daemon
  case gateway

  public static func fromEnvironment(
    _ env: [String: String] = ProcessInfo.processInfo.environment
  ) -> ChatBackend {
    ChatBackend(rawValue: env["RATIO_CHAT_BACKEND"]?.lowercased() ?? "") ?? .daemon
  }
}
