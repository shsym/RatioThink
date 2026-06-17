import Foundation
import CryptoKit

/// Minimal pie-server WebSocket control client. Only implements the
/// three calls the macOS launcher needs:
///
///   - `authByToken(_:)`     — internal-token bring-up
///   - `installProgram(...)` — chunked upload of wasm + manifest
///   - `launchDaemon(...)`   — bind a `name@version` to an HTTP port
///
/// The Python reference (`Vendor/pie/client/python/src/pie_client/client.py`)
/// covers the rest of the surface; we deliberately do not port what
/// the launcher does not call. Wire format matches the Rust schema in
/// `Vendor/pie/client/rust/src/message.rs`:
///
///   request:  msgpack map { type: <tag>, corr_id: u32, … }
///   response: msgpack map { type: "response", corr_id: u32, ok: bool, result: String }
///
/// Server framing is a single msgpack value per WebSocket binary
/// message; the listener task decodes and dispatches by `corr_id`.
public actor PieControlClient {

  public enum ClientError: Error, CustomStringConvertible {
    case notConnected
    case connectionClosed(reason: String)
    case serverRejected(message: String)
    case decodeFailed(underlying: String)
    case protocolViolation(detail: String)
    case wasmReadFailed(path: String, underlying: String)
    case manifestReadFailed(path: String, underlying: String)
    case alreadyConnected

    public var description: String {
      switch self {
      case .notConnected: return "PieControlClient: not connected"
      case let .connectionClosed(reason): return "PieControlClient: connection closed (\(reason))"
      case let .serverRejected(message): return "PieControlClient: server rejected request: \(message)"
      case let .decodeFailed(underlying): return "PieControlClient: msgpack decode failed: \(underlying)"
      case let .protocolViolation(detail): return "PieControlClient: protocol violation: \(detail)"
      case let .wasmReadFailed(path, u): return "PieControlClient: cannot read wasm at \(path): \(u)"
      case let .manifestReadFailed(path, u): return "PieControlClient: cannot read manifest at \(path): \(u)"
      case .alreadyConnected: return "PieControlClient: connect() called twice"
      }
    }
  }

  /// 256 KiB matches `Vendor/pie/client/rust/src/message.rs` `CHUNK_SIZE_BYTES`.
  /// Keep in sync; smaller chunks waste round-trips, larger chunks may
  /// exceed pie's per-frame upper bound.
  public static let chunkSize = 256 * 1024

  // MARK: - connection state

  private let url: URL
  private let session: URLSession
  private var task: URLSessionWebSocketTask?
  private var listenerTask: Task<Void, Never>?
  private var corrCounter: UInt32 = 0
  private var pending: [UInt32: CheckedContinuation<Response, Error>] = [:]

  public init(url: URL, session: URLSession = .shared) {
    self.url = url
    self.session = session
  }

  // MARK: - lifecycle

  public func connect() async throws {
    guard task == nil else { throw ClientError.alreadyConnected }
    let ws = session.webSocketTask(with: url)
    self.task = ws
    ws.resume()
    self.listenerTask = Task { [weak self] in
      await self?.listenLoop()
    }
  }

  public func close() async {
    listenerTask?.cancel()
    listenerTask = nil
    task?.cancel(with: .goingAway, reason: nil)
    task = nil
    failAllPending(with: ClientError.connectionClosed(reason: "client close"))
  }

  // MARK: - RPCs

  public func authByToken(_ token: String) async throws {
    try await sendAndAwait(type: "auth_by_token", extra: [("token", .string(token))])
  }

  /// Mirrors `pie_client.PieClient.install_program` — uploads `wasm`
  /// in 256 KiB chunks, framing each chunk as an `add_program` message
  /// with the same `corr_id`. The server replies once after the final
  /// chunk; intermediate chunks are fire-and-forget.
  public func installProgram(wasmURL: URL,
                             manifestURL: URL,
                             forceOverwrite: Bool) async throws {
    let wasmBytes: Data
    do { wasmBytes = try Data(contentsOf: wasmURL) }
    catch { throw ClientError.wasmReadFailed(path: wasmURL.path, underlying: "\(error)") }

    let manifestText: String
    do { manifestText = try String(contentsOf: manifestURL, encoding: .utf8) }
    catch { throw ClientError.manifestReadFailed(path: manifestURL.path, underlying: "\(error)") }

    // pie's `add_program` handler treats `program_hash` as an opaque
    // session-scoped dedup key — see `Vendor/pie/runtime/src/server/
    // handler.rs:106` (`inflight_uploads.contains_key`). No buffer
    // verification on the upload path (`process_chunk` doesn't read
    // the hash). Python uses BLAKE3 to deduplicate identical uploads;
    // SHA-256 satisfies the same property without pulling a BLAKE3
    // dependency into the macOS app. The key just needs to be stable
    // across chunks of the same wasm.
    let programHash = SHA256.hash(data: wasmBytes)
      .map { String(format: "%02x", $0) }.joined()
    let chunkCount = max(1, (wasmBytes.count + Self.chunkSize - 1) / Self.chunkSize)

    let corrID = nextCorrID()
    let response = try await withResponseContinuation(corrID: corrID) {
      for chunkIndex in 0..<chunkCount {
        let chunkData: Data
        if wasmBytes.isEmpty {
          chunkData = Data()
        } else {
          let start = chunkIndex * Self.chunkSize
          let end = min(start + Self.chunkSize, wasmBytes.count)
          chunkData = wasmBytes.subdata(in: start ..< end)
        }
        try await self.sendMap([
          ("type", .string("add_program")),
          ("corr_id", .uint(UInt64(corrID))),
          ("program_hash", .string(programHash)),
          ("manifest", .string(manifestText)),
          ("force_overwrite", .bool(forceOverwrite)),
          ("chunk_index", .uint(UInt64(chunkIndex))),
          ("total_chunks", .uint(UInt64(chunkCount))),
          ("chunk_data", .binary(chunkData)),
        ])
      }
    }
    if !response.ok { throw ClientError.serverRejected(message: response.result) }
  }

  public func launchDaemon(inferlet: String,
                           port: UInt32,
                           host: String = EngineHTTPBindMode.loopback.daemonHost,
                           input: [String: Any] = [:]) async throws {
    let inputJSON: String
    if input.isEmpty {
      inputJSON = "{}"
    } else {
      let data = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
      inputJSON = String(data: data, encoding: .utf8) ?? "{}"
    }
    try await sendAndAwait(type: "launch_daemon", extra: [
      ("port", .uint(UInt64(port))),
      ("host", .string(host)),
      ("inferlet", .string(inferlet)),
      ("input", .string(inputJSON)),
    ])
  }

  /// Mirrors pie's `auth_identify` handshake message. Under `--no-auth`
  /// (how the macOS launcher starts the engine) the server accepts any
  /// username and replies `ok` immediately
  /// (`Vendor/pie/runtime/src/server.rs` `handle_auth_request`,
  /// `is_auth_enabled()==false` arm). The control plane gates every
  /// non-auth request behind one auth message
  /// (`server.rs` session dispatch: `if !self.authenticated { … }`), so
  /// a fresh probe connection must send this once before `ping()`. No
  /// token is required on the `--no-auth` path, so liveness probes do
  /// not need the launch-time internal token retained.
  public func authIdentify(_ username: String) async throws {
    try await sendAndAwait(type: "auth_identify", extra: [("username", .string(username))])
  }

  /// Mirrors pie's control-plane `ping` (the primitive behind
  /// `pie-cli ping`): sends `{type:"ping",corr_id}` and expects the
  /// server's `(ok=true, result="Pong")` reply
  /// (`Vendor/pie/runtime/src/server.rs` `ClientMessage::Ping`).
  /// Returns on Pong; a non-ok reply throws `ClientError.serverRejected`
  /// and a dropped socket throws `ClientError.connectionClosed` (via
  /// `failAllPending`) — the engine-gone signal for  G1 liveness
  /// probes. Requires a prior `authIdentify(_:)` on the same connection.
  public func ping() async throws {
    try await sendAndAwait(type: "ping", extra: [])
  }

  /// Generic pie control-plane query. The wire subject is handled by
  /// pie itself (not by the chat-apc HTTP inferlet) and the response
  /// payload is returned as the raw `result` string from the server.
  ///
  /// `subject == "model_status"` is the existing pie runtime endpoint
  /// that reports model-scoped counters including `*.kv_pages_used`
  /// and `*.kv_pages_total`; callers can JSON-decode that string into
  /// a typed snapshot at the App/XPC boundary.
  public func query(subject: String, record: String = "") async throws -> String {
    let response = try await sendAndReceive(type: "query", extra: [
      ("subject", .string(subject)),
      ("record", .string(record)),
    ])
    return response.result
  }

  // MARK: - framing

  /// Decoded server response. `internal` (not `fileprivate`) so the
  /// `@testable` RatioThinkCore consumer (RatioThinkCoreTests.PieControlClientTests)
  /// can assert classifier output directly.
  struct Response: Equatable {
    let ok: Bool
    let result: String
  }

  private func sendAndAwait(type: String, extra: [(String, MessagePack.Value)]) async throws {
    _ = try await sendAndReceive(type: type, extra: extra)
  }

  private func sendAndReceive(type: String, extra: [(String, MessagePack.Value)]) async throws -> Response {
    let corrID = nextCorrID()
    let response = try await withResponseContinuation(corrID: corrID) {
      try await self.sendFrame(Self.encodeRequestFrame(type: type, corrID: corrID, extra: extra))
    }
    if !response.ok { throw ClientError.serverRejected(message: response.result) }
    return response
  }

  /// Registers a Response continuation under `corrID`, runs `send`,
  /// and awaits the matching server reply. If `send` throws, the
  /// waiter is removed and the error propagates. If the connection
  /// drops mid-flight, `failAllPending` resumes the waiter with
  /// `connectionClosed`.
  private func withResponseContinuation(corrID: UInt32,
                                         send: @escaping @Sendable () async throws -> Void)
    async throws -> Response {
    // Register first so a sub-millisecond reply can't beat us to
    // `pending[corrID]`. The listener checks `pending[corrID]` only
    // after the actor releases isolation post-send, so registration
    // → send → suspend is the only valid order.
    let response: Response = try await withCheckedThrowingContinuation { cont in
      pending[corrID] = cont
      Task {
        do {
          try await send()
        } catch {
          // Send failed: remove our waiter and resume with the error.
          // The listener will never resolve this corr_id, so a leaked
          // entry would deadlock the next connection cycle.
          if let stillPending = pending.removeValue(forKey: corrID) {
            stillPending.resume(throwing: error)
          }
        }
      }
    }
    return response
  }

  private func nextCorrID() -> UInt32 {
    corrCounter &+= 1
    return corrCounter
  }

  static func encodeRequestFrame(
    type: String,
    corrID: UInt32,
    extra: [(String, MessagePack.Value)]
  ) -> Data {
    var fields: [(String, MessagePack.Value)] = [
      ("type", .string(type)),
      ("corr_id", .uint(UInt64(corrID))),
    ]
    fields.append(contentsOf: extra)
    let kvs: [(MessagePack.Value, MessagePack.Value)] = fields.map { (.string($0.0), $0.1) }
    return MessagePack.encode(.map(kvs))
  }

  private func sendFrame(_ data: Data) async throws {
    guard let task else { throw ClientError.notConnected }
    try await task.send(.data(data))
  }

  private func sendMap(_ fields: [(String, MessagePack.Value)]) async throws {
    let kvs: [(MessagePack.Value, MessagePack.Value)] = fields.map { (.string($0.0), $0.1) }
    try await sendFrame(MessagePack.encode(.map(kvs)))
  }

  // MARK: - listener

  private func listenLoop() async {
    guard let task else { return }
    while !Task.isCancelled {
      let message: URLSessionWebSocketTask.Message
      do {
        message = try await task.receive()
      } catch {
        failAllPending(with: ClientError.connectionClosed(reason: "\(error)"))
        return
      }
      switch message {
      case let .data(data):
        handleFrame(data: data)
      case let .string(s):
        // The pie protocol is binary-only; a string frame is a
        // protocol violation. Log + ignore — the connection itself
        // may still be usable for other corr_ids.
        diagnose("unexpected string frame: \(s.prefix(120))")
      @unknown default:
        continue
      }
    }
  }

  /// Decoded outcome from a single inbound WS frame. Drives the
  /// fail-pending policy for review  F2: a frame we cannot
  /// associate with any specific corr_id (decode failure, missing
  /// `type`) fails ALL pending requests so the caller surfaces a
  /// typed `protocolViolation` instead of waiting out the launcher's
  /// 30 s handshake timeout. A frame that targets one parseable
  /// corr_id fails only that waiter; the listener stays alive for
  /// the rest.
  /// Pure-functional classification of an inbound WS frame. Exposed
  /// at `internal` so the wire-policy unit test (review  F3) can
  /// drive `classifyFrame` with synthetic msgpack bytes; the
  /// production `handleFrame` is the only consumer beyond tests.
  enum FrameOutcome: Equatable {
    case resolved(corrID: UInt32, response: Response)
    case nonResponse        // process_event / file / mcp_request — keep listener alive
    case fatalProtocolViolation(detail: String)
    case scopedProtocolViolation(corrID: UInt32, detail: String)
  }

  private func handleFrame(data: Data) {
    let outcome = Self.classifyFrame(data: data)
    switch outcome {
    case .nonResponse:
      return
    case let .resolved(corrID, response):
      if let cont = pending.removeValue(forKey: corrID) {
        cont.resume(returning: response)
      }
    case let .scopedProtocolViolation(corrID, detail):
      diagnose("protocol violation for corr_id=\(corrID): \(detail)")
      if let cont = pending.removeValue(forKey: corrID) {
        cont.resume(throwing: ClientError.protocolViolation(detail: detail))
      }
    case let .fatalProtocolViolation(detail):
      // No parseable corr_id; we don't know which request this was
      // supposed to answer. Fail every awaiting caller so a bad
      // frame becomes a fast typed error instead of a launcher
      // handshake timeout (review  F2). The listener keeps
      // running — subsequent good frames remain serviceable.
      diagnose("fatal protocol violation: \(detail)")
      failAllPending(with: ClientError.protocolViolation(detail: detail))
    }
  }

  /// Pure classifier — separated from `handleFrame` so a unit test
  /// can assert the policy without standing up a real WS task.
  /// `internal static` for the same reason `FrameOutcome` is internal.
  static func classifyFrame(data: Data) -> FrameOutcome {
    let decoded: MessagePack.Value
    do { decoded = try MessagePack.decode(data) }
    catch {
      return .fatalProtocolViolation(detail: "msgpack decode failed: \(error)")
    }
    guard let type = decoded.field("type")?.asString else {
      return .fatalProtocolViolation(detail: "frame missing 'type' field")
    }
    guard type == "response" else {
      // The pie server can also send `process_event`, `file`,
      // `mcp_request`. The launcher does not consume them; drop
      // silently to keep the listener alive.
      return .nonResponse
    }
    // Response frame: corr_id MUST be parseable. ok is a softer
    // requirement — when only corr_id resolves we can still tear
    // down that one waiter with a scoped error.
    guard let corrIDRaw = decoded.field("corr_id")?.asUInt else {
      return .fatalProtocolViolation(detail: "response missing corr_id")
    }
    let corrID = UInt32(corrIDRaw & UInt64(UInt32.max))
    guard let ok = decoded.field("ok")?.asBool else {
      return .scopedProtocolViolation(corrID: corrID, detail: "response missing 'ok' field")
    }
    let result = decoded.field("result")?.asString ?? ""
    return .resolved(corrID: corrID, response: Response(ok: ok, result: result))
  }

  private func failAllPending(with error: Error) {
    let dead = pending
    pending.removeAll()
    for (_, cont) in dead { cont.resume(throwing: error) }
  }

  private nonisolated func diagnose(_ msg: String) {
    // Keep diagnostics off the unified log to avoid leaking tokens
    // from a misdecoded auth frame. stderr is enough during test +
    // dev; production wiring lives in the launcher.
    FileHandle.standardError.write(Data("[PieControlClient] \(msg)\n".utf8))
  }
}
