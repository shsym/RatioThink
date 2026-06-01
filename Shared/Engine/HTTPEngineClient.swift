import Foundation

/// `EngineClient` backed by the pie engine's loopback HTTP+SSE surface
/// (served in v1 by the `pie-control` inferlet — see
/// `Inferlets/pie-control/`). One `URLSession` for unary calls
/// (`health`, `models`); one for streaming (`loadModel`,
/// `chatCompletion`, `dispatchInferlet`). Streaming uses
/// `URLSession.bytes(for:)` so back-pressure and cancellation flow
/// naturally through Swift concurrency — dropping the consumer task
/// cancels the underlying network task without ceremony.
///
/// Wire shapes (per pie-control v1):
/// * `GET /healthz` → `{"status":"ok"}` (no `uptime_s`/`model` yet —
///   `EngineHealth` makes those optional).
/// * `GET /v1/models` → `{"object":"list","data":[{"id","object","owned_by"}]}`
///   (no `created` yet — `ModelInfo.created` is optional).
/// * `POST /v1/chat/completions` → SSE: meta-frame `{"event":"model_ready"}`
///   then OpenAI `chat.completion.chunk` frames, terminating with
///   `data: [DONE]`. `model_loading` meta-frames are tolerated but
///   absent in v1 (pie loads at boot).
/// * `POST /v1/models/load` → SSE: `{"event":"model_ready"}` + `[DONE]`.
/// * `POST /v1/inferlet` → routes through chat-completions for the
///   only registered name (`chat-apc`); dispatch surfaces the raw
///   SSE `data:` bytes per frame to the consumer.
///
/// Error model ( — one code space across channels): an HTTP
/// non-2xx whose body is an OpenAI-shape `{"error":{code,message}}`
/// envelope surfaces as `HTTPEngineError.api(status, code, message)`;
/// bodies that don't parse (empty, or pie's daemon bare anyhow 500
/// text) fall back to `HTTPEngineError.http(status, body)`. In-stream
/// `{"event":"error","code","message"}` meta-frames surface as
/// `HTTPEngineError.stream(code, message)` thrown into the async
/// stream. All three carry the same canonical `code`. Network/JSON
/// failures propagate as-is.
public final class HTTPEngineClient: EngineClient, @unchecked Sendable {

  // MARK: - Config

  /// Async resolver for the engine's loopback root. Resolved lazily
  /// per request because the pie daemon's listener port is only known
  /// after `PieSupervisor` reports `EngineStatus.running(port:_)` over
  /// XPC — the GUI's main scene constructs `HTTPEngineClient` before
  /// that handshake completes. Tests pass a static-URL convenience
  /// (`init(baseURL:)`) that wraps a never-throwing closure.
  public let baseURLProvider: @Sendable () async throws -> URL
  public let session: URLSession
  /// Per-request timeout for unary calls. Streaming calls do not
  /// inherit it — SSE bodies are open-ended by design.
  public let unaryTimeout: TimeInterval

  /// Idle (between-bytes) cap applied to SSE streaming requests. Both
  /// `URLRequest.timeoutInterval` and `URLSessionConfiguration
  /// .timeoutIntervalForRequest` are idle timeouts (reset on each
  /// received byte) defaulting to 60 s, and the *more restrictive* of
  /// the two applies — so leaving either at its default silently caps a
  /// silent stream at 60 s. pie-control v1 sends NO `model_loading`
  /// progress bytes during a load, so a slow load is silent on the
  /// wire; at 60 s it would abort as `.failed`. We therefore lift BOTH
  /// to this value for streaming. Total transfer is still bounded by
  /// `timeoutIntervalForResource` (default 7 days). 24 h ≈ no idle cap.
  static let streamingIdleTimeout: TimeInterval = 86_400

  /// JSON decoder configured for OpenAI's wire shape. `secondsSince1970`
  /// for any future `created` date field; key strategy stays default
  /// since the wire types pin snake-case via explicit `CodingKeys`.
  private let decoder: JSONDecoder
  private let encoder: JSONEncoder

  public init(
    baseURLProvider: @escaping @Sendable () async throws -> URL,
    session: URLSession? = nil,
    unaryTimeout: TimeInterval = 10
  ) {
    self.baseURLProvider = baseURLProvider
    // Default to a session whose per-request idle cap is lifted (see
    // `streamingIdleTimeout`); `.shared` would impose the 60 s default
    // that aborts silent SSE loads. Callers (tests) may inject their own.
    self.session = session ?? HTTPEngineClient.defaultSession
    self.unaryTimeout = unaryTimeout

    let dec = JSONDecoder()
    dec.dateDecodingStrategy = .secondsSince1970
    self.decoder = dec

    let enc = JSONEncoder()
    enc.dateEncodingStrategy = .secondsSince1970
    self.encoder = enc
  }

  /// Static-URL convenience for tests and any caller that already
  /// knows the port (e.g. fixtures that pin `127.0.0.1:<ephemeral>`).
  public convenience init(
    baseURL: URL,
    session: URLSession? = nil,
    unaryTimeout: TimeInterval = 10
  ) {
    self.init(
      baseURLProvider: { baseURL },
      session: session,
      unaryTimeout: unaryTimeout
    )
  }

  /// Shared session for non-injected callers. Process-lifetime singleton
  /// (review F1): `URLSession(configuration:)` retains its delegate and
  /// an internal operation queue until `invalidateAndCancel()`, which
  /// `HTTPEngineClient` has no `deinit` for — allocating a fresh one per
  /// instance leaked one session + queue per harness/probe/test
  /// construction. The session config lifts the per-request idle cap so
  /// a silent SSE stream is not aborted at the 60 s default; the
  /// more-restrictive `unaryTimeout` set per unary request still governs
  /// `health`/`models`.
  static let defaultSession: URLSession = {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = streamingIdleTimeout
    return URLSession(configuration: config)
  }()

  // MARK: - EngineClient: unary

  public func health() async throws -> EngineHealth {
    let req = try await makeRequest("/healthz", method: "GET", timeout: unaryTimeout)
    let (data, response) = try await session.data(for: req)
    try Self.assertOK(response, data: data)
    return try decoder.decode(EngineHealth.self, from: data)
  }

  public func models() async throws -> [ModelInfo] {
    let req = try await makeRequest("/v1/models", method: "GET", timeout: unaryTimeout)
    let (data, response) = try await session.data(for: req)
    try Self.assertOK(response, data: data)
    let wrapper = try decoder.decode(ModelListResponse.self, from: data)
    return wrapper.data
  }

  // MARK: - EngineClient: streaming

  public func loadModel(_ id: String) -> AsyncThrowingStream<LoadEvent, Error> {
    let body: Data
    do {
      body = try encoder.encode(LoadRequestBody(model: id))
    } catch {
      return AsyncThrowingStream { $0.finish(throwing: error) }
    }
    return loadStream(buildRequest: {
      try await self.makeRequest("/v1/models/load", method: "POST", body: body,
                                 timeout: Self.streamingIdleTimeout)
    })
  }

  public func chatCompletion(_ req: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
    let body: Data
    do {
      body = try encoder.encode(req)
    } catch {
      return AsyncThrowingStream { $0.finish(throwing: error) }
    }
    return chatStream(buildRequest: {
      try await self.makeRequest("/v1/chat/completions", method: "POST", body: body,
                                 timeout: Self.streamingIdleTimeout)
    })
  }

  public func dispatchInferlet(_ req: InferletRequest) -> AsyncThrowingStream<Data, Error> {
    let body: Data
    do {
      body = try encoder.encode(req)
    } catch {
      return AsyncThrowingStream { $0.finish(throwing: error) }
    }
    return dispatchStream(buildRequest: {
      try await self.makeRequest("/v1/inferlet", method: "POST", body: body,
                                 timeout: Self.streamingIdleTimeout)
    })
  }

  // MARK: - Stream implementations

  private func loadStream(
    buildRequest: @escaping @Sendable () async throws -> URLRequest
  ) -> AsyncThrowingStream<LoadEvent, Error> {
    let session = self.session
    let decoder = self.decoder
    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let request = try await buildRequest()
          let (bytes, response) = try await session.bytes(for: request)
          try await Self.assertOK(response, bytes: bytes)
          for try await frame in HTTPEngineClient.sseFrames(from: bytes) {
            if frame.isDone { break }
            try Task.checkCancellation()
            let meta = try decoder.decode(MetaFrame.self, from: frame.dataBytes)
            switch meta.event {
            case "model_ready":
              continuation.yield(.ready)
            case "model_loading":
              continuation.yield(.loading(
                loadedBytes: meta.loaded_bytes ?? 0,
                totalBytes: meta.total_bytes ?? 0,
                etaSeconds: meta.eta_s
              ))
            case "error":
              throw HTTPEngineError.stream(
                code: meta.code ?? "unknown_error",
                message: meta.message ?? "")
            default:
              // Tolerate unknown meta-events: a future engine extension
              // shouldn't kill the load stream.
              continue
            }
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private func chatStream(
    buildRequest: @escaping @Sendable () async throws -> URLRequest
  ) -> AsyncThrowingStream<ChatEvent, Error> {
    let session = self.session
    let decoder = self.decoder
    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let request = try await buildRequest()
          let (bytes, response) = try await session.bytes(for: request)
          try await Self.assertOK(response, bytes: bytes)
          var emittedFinish = false
          for try await frame in HTTPEngineClient.sseFrames(from: bytes) {
            if frame.isDone { break }
            try Task.checkCancellation()
            // Disambiguate meta-frame vs OpenAI chunk by peeking `event`.
            if let event = frame.peekEvent() {
              switch event {
              case "model_ready":
                continuation.yield(.modelReady)
              case "model_loading":
                // Strict decode: silently dropping a malformed
                // `model_loading` frame would stall the GUI's
                // progress indicator with no diagnostic. Mirrors
                // `loadStream`'s strict path so a schema drift
                // (e.g. `loaded_bytes` renamed) surfaces uniformly
                // across both endpoints. Review v1 F2.
                let meta = try decoder.decode(MetaFrame.self, from: frame.dataBytes)
                continuation.yield(.modelLoading(
                  loadedBytes: meta.loaded_bytes ?? 0,
                  totalBytes: meta.total_bytes ?? 0,
                  etaSeconds: meta.eta_s
                ))
              case "error":
                let meta = try decoder.decode(MetaFrame.self, from: frame.dataBytes)
                throw HTTPEngineError.stream(
                  code: meta.code ?? "unknown_error",
                  message: meta.message ?? "")
              default:
                continue
              }
              continue
            }
            // OpenAI `chat.completion.chunk`.
            let chunk = try decoder.decode(ChatCompletionChunk.self, from: frame.dataBytes)
            guard let choice = chunk.choices.first else { continue }
            if let delta = choice.delta {
              // Reasoning frames carry `reasoning_content` and no
              // `content`; route them to their own channel so thinking
              // text never lands in the visible answer.
              if let reasoning = delta.reasoning_content, !reasoning.isEmpty {
                continuation.yield(.reasoningDelta(reasoning))
              }
              if delta.content != nil || delta.role != nil {
                continuation.yield(.delta(
                  role: delta.role,
                  content: delta.content ?? ""
                ))
              }
            }
            if let reason = choice.finish_reason {
              continuation.yield(.finish(reason: Self.parseFinishReason(reason)))
              emittedFinish = true
            }
          }
          // Contract per `EngineClient.swift`: streams end with
          // exactly one `.finish`. If the engine truncated (clean
          // close without a `finish_reason` chunk) or emitted only
          // `[DONE]`, synthesize a terminal frame so downstream
          // cleanup anchored on `.finish` still fires. Mirrors the
          // `.cancelled` synthesis pattern below. Review v1 F4.
          if !emittedFinish {
            continuation.yield(.finish(reason: .other("missing_finish_reason")))
          }
          continuation.finish()
        } catch is CancellationError {
          continuation.yield(.finish(reason: .cancelled))
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private func dispatchStream(
    buildRequest: @escaping @Sendable () async throws -> URLRequest
  ) -> AsyncThrowingStream<Data, Error> {
    let session = self.session
    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let request = try await buildRequest()
          let (bytes, response) = try await session.bytes(for: request)
          try await Self.assertOK(response, bytes: bytes)
          for try await frame in HTTPEngineClient.sseFrames(from: bytes) {
            if frame.isDone { break }
            try Task.checkCancellation()
            continuation.yield(frame.dataBytes)
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  // MARK: - Request building

  /// Build a `URLRequest` for either the unary or streaming surface.
  /// `URLRequest.timeoutInterval` is an idle timeout — URLSession
  /// terminates the request when no bytes arrive in the window. That's
  /// the right behavior for `health`/`models` (which pass the short
  /// `unaryTimeout` and must complete promptly), but disastrous for
  /// SSE: chat completions can sit silent for >10s during preprompt
  /// processing, and a model load can stall silently during mmap/warmup
  /// (pie-control v1 sends no `model_loading` progress bytes).
  ///
  /// Passing `timeout: nil` does NOT disable the idle cap: an unset
  /// `URLRequest.timeoutInterval` defaults to 60 s, and the session's
  /// `timeoutIntervalForRequest` default is also 60 s — the more
  /// restrictive applies, so a silent stream would abort at 60 s
  /// (``). Streaming callers therefore pass
  /// `timeout: streamingIdleTimeout` explicitly AND the default session
  /// lifts `timeoutIntervalForRequest` to the same value; both sides
  /// must be lifted for the cap to actually clear. Review v1 F1 / .
  private func makeRequest(_ path: String, method: String, body: Data? = nil, timeout: TimeInterval? = nil) async throws -> URLRequest {
    let baseURL = try await baseURLProvider()
    let url = baseURL.appendingPathComponent(path.trimmingCharacters(in: .init(charactersIn: "/")))
    var req = URLRequest(url: url)
    req.httpMethod = method
    if let timeout {
      req.timeoutInterval = timeout
    }
    if let body {
      req.httpBody = body
      req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    return req
  }

  /// Build the right `HTTPEngineError` for a non-2xx response body.
  /// An OpenAI-shape `{"error":{code,message}}` envelope surfaces as
  /// `.api` so the canonical code is preserved — parity
  /// with the SSE `.stream` channel, so a fault is traceable end-to-end
  /// by the same code space. Anything else (empty bodies, pie's daemon
  /// bare anyhow 500 text) falls back to `.http`; the absence of a code
  /// is itself the "engine-internal, not inferlet-coded" signal.
  private static func httpError(status: Int, body: Data) -> HTTPEngineError {
    if let env = try? JSONDecoder().decode(APIErrorEnvelope.self, from: body),
       env.error.code != nil || env.error.message != nil {
      return .api(
        status: status,
        code: env.error.code ?? "",
        message: env.error.message ?? "")
    }
    return .http(status: status, body: body)
  }

  /// Unary guard: `data` is the fully-buffered response body.
  private static func assertOK(_ response: URLResponse, data: Data?) throws {
    guard let http = response as? HTTPURLResponse else {
      throw HTTPEngineError.nonHTTPResponse
    }
    guard (200..<300).contains(http.statusCode) else {
      throw httpError(status: http.statusCode, body: data ?? Data())
    }
  }

  /// Streaming guard: on a non-2xx the error body lives unread in
  /// `bytes` (the SSE stream never opened). Drain it so a pre-stream
  /// chat-turn failure carries the inferlet's `{error:{code,message}}`
  /// envelope instead of being flattened to a bare status — root cause: the old `assertOK(_, data: nil)` discarded it.
  private static func assertOK(
    _ response: URLResponse,
    bytes: URLSession.AsyncBytes
  ) async throws {
    guard let http = response as? HTTPURLResponse else {
      throw HTTPEngineError.nonHTTPResponse
    }
    guard (200..<300).contains(http.statusCode) else {
      var body = Data()
      for try await byte in bytes { body.append(byte) }
      throw httpError(status: http.statusCode, body: body)
    }
  }

  private static func parseFinishReason(_ raw: String) -> ChatEvent.FinishReason {
    switch raw {
    case "stop":   return .stop
    case "length": return .length
    default:       return .other(raw)
    }
  }

  // MARK: - SSE frame reader

  /// One SSE frame (joined `data:` lines plus terminator detection).
  /// Comment lines (`:`), `event:`/`id:`/`retry:` fields are ignored —
  /// pie-control's wire uses the `data:` channel exclusively, with the
  /// frame's discriminator carried inside the JSON payload as a
  /// top-level `event` key.
  internal struct SSEFrame {
    let data: String

    /// `data: [DONE]` terminator per OpenAI's SSE schema (and
    /// `pie-control` mirrors it). Whitespace-trimmed because some
    /// emitters add a trailing space the spec allows.
    var isDone: Bool {
      data.trimmingCharacters(in: .whitespaces) == "[DONE]"
    }

    /// Frame payload as UTF-8 bytes for `JSONDecoder.decode`.
    var dataBytes: Data { Data(data.utf8) }

    /// Cheap peek at the top-level `event` key without paying for
    /// `Codable`. Returns nil if the JSON has no `event` field
    /// (i.e. an OpenAI content chunk).
    func peekEvent() -> String? {
      guard
        let obj = try? JSONSerialization.jsonObject(with: dataBytes) as? [String: Any],
        let event = obj["event"] as? String
      else { return nil }
      return event
    }
  }

  /// Convert any async line stream into discrete SSE frames. Per
  /// RFC 8895 / EventSource: lines starting with `data:` accumulate
  /// (joined by `\n` if multiple); the frame dispatches on the next
  /// blank line. Anything else is metadata we don't use. Generic so
  /// unit tests can drive the parser with a synthetic `AsyncStream`
  /// without standing up a real `URLSession`.
  internal static func sseFrames<S: AsyncSequence & Sendable>(
    from lines: S
  ) -> AsyncThrowingStream<SSEFrame, Error> where S.Element == String {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          var dataLines: [String] = []
          for try await line in lines {
            if line.isEmpty {
              if !dataLines.isEmpty {
                continuation.yield(SSEFrame(data: dataLines.joined(separator: "\n")))
                dataLines.removeAll(keepingCapacity: true)
              }
              continue
            }
            if line.hasPrefix("data:") {
              let after = line.index(line.startIndex, offsetBy: 5)
              var payload = line[after...]
              if payload.first == " " { payload = payload.dropFirst() }
              dataLines.append(String(payload))
            }
            // Ignore `event:` / `id:` / `:`-comments / `retry:` — pie
            // control doesn't use them, and the design pins the event
            // discriminator inside the JSON body.
          }
          if !dataLines.isEmpty {
            continuation.yield(SSEFrame(data: dataLines.joined(separator: "\n")))
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// Streaming-path entry point: byte-level reader that preserves the
  /// SSE blank-line frame boundary. We can't reuse
  /// `URLSession.AsyncBytes.lines` here — `AsyncLineSequence` collapses
  /// empty lines, which destroys SSE's framing (each frame terminates
  /// on a `\n\n` boundary). Hand-rolling the line buffer keeps the
  /// blank-line signal intact.
  internal static func sseFrames(
    from bytes: URLSession.AsyncBytes
  ) -> AsyncThrowingStream<SSEFrame, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          var lineBuf: [UInt8] = []
          var dataLines: [String] = []
          func dispatchFrameIfReady() {
            if !dataLines.isEmpty {
              continuation.yield(SSEFrame(data: dataLines.joined(separator: "\n")))
              dataLines.removeAll(keepingCapacity: true)
            }
          }
          func consume(_ line: String) {
            if line.isEmpty {
              dispatchFrameIfReady()
              return
            }
            if line.hasPrefix("data:") {
              let after = line.index(line.startIndex, offsetBy: 5)
              var payload = line[after...]
              if payload.first == " " { payload = payload.dropFirst() }
              dataLines.append(String(payload))
            }
            // Ignore `event:` / `id:` / `:`-comments / `retry:`.
          }
          for try await byte in bytes {
            if byte == 0x0A { // \n
              let line = String(decoding: lineBuf, as: UTF8.self)
              lineBuf.removeAll(keepingCapacity: true)
              consume(line)
            } else if byte == 0x0D { // \r — strip so CRLF collapses to LF
              continue
            } else {
              lineBuf.append(byte)
            }
          }
          // Flush trailing data without a closing blank line.
          if !lineBuf.isEmpty {
            consume(String(decoding: lineBuf, as: UTF8.self))
          }
          dispatchFrameIfReady()
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}

// MARK: - Wire types (internal to HTTPEngineClient)

/// `GET /v1/models` envelope. pie-control returns
/// `{"object":"list","data":[...]}` (OpenAI shape); the protocol
/// surface returns `[ModelInfo]` so callers don't see the envelope.
private struct ModelListResponse: Decodable {
  let object: String
  let data: [ModelInfo]
}

/// Body of `POST /v1/models/load`. Single-field carrier so the
/// `encoder.encode(LoadRequestBody)` call produces `{"model":"…"}`
/// without a positional-arg `[String: String]` literal.
private struct LoadRequestBody: Encodable {
  let model: String
}

/// OpenAI-shape error envelope: `{"error":{"type","code","message","param"}}`.
/// The chat-apc inferlet emits this on every 4xx/5xx HTTP body
/// (`Inferlets/chat-apc/src/sse.rs::json_error`). Only `code`/`message`
/// are decoded — the canonical fields the GUI surfaces; `type`/`param`
/// are advisory and ignored.
private struct APIErrorEnvelope: Decodable {
  struct Payload: Decodable {
    let code: String?
    let message: String?
  }
  let error: Payload
}

/// SSE meta-frame schema. `event` is required; `code`/`message` are
/// present on `error`; `loaded_bytes`/`total_bytes`/`eta_s` are present
/// on `model_loading` (currently unused by pie-control v1 but tolerated
/// so the demux is forward-compatible).
private struct MetaFrame: Decodable {
  let event: String
  let code: String?
  let message: String?
  let loaded_bytes: UInt64?
  let total_bytes: UInt64?
  let eta_s: Double?
}

/// `chat.completion.chunk` body per OpenAI's streaming schema. Only
/// fields the GUI actually consumes are decoded; `id` / `object` /
/// `created` / `model` are dropped at the JSON layer since `Decodable`
/// ignores unknown keys by default.
private struct ChatCompletionChunk: Decodable {
  let choices: [ChunkChoice]
}

private struct ChunkChoice: Decodable {
  let delta: ChunkDelta?
  let finish_reason: String?
}

private struct ChunkDelta: Decodable {
  let role: ChatMessage.Role?
  let content: String?
  /// OpenAI `reasoning_content` delta — the model's thinking-block text
  /// on chat-apc reasoning frames. Present only on reasoning chunks
  /// (which carry no `content`); decoded so the GUI can surface it on a
  /// separate channel instead of dropping it.
  let reasoning_content: String?
}

// MARK: - Errors

/// Failure modes specific to the HTTP transport. Stream errors are
/// thrown into the `AsyncThrowingStream` produced by the streaming
/// methods; unary errors are thrown directly from `health`/`models`.
public enum HTTPEngineError: Error, Equatable, Sendable {
  /// Engine returned a non-2xx status whose body carried an
  /// OpenAI-shape `{"error":{code,message}}` envelope. Surfaces the
  /// canonical `code`/`message` so a pre-stream HTTP
  /// fault is traceable by the same code space the SSE `.stream` frame
  /// uses. `code` is `""` when the envelope omitted it.
  case api(status: Int, code: String, message: String)
  /// Engine returned a non-2xx status whose body did NOT parse as an
  /// error envelope — an empty body or pie's daemon bare anyhow 500
  /// text. The absence of a code is the "engine-internal, not
  /// inferlet-coded" signal; `body` is the raw bytes for diagnostics.
  case http(status: Int, body: Data)
  /// `URLResponse` was not an `HTTPURLResponse` — typically a
  /// configuration bug rather than a network failure.
  case nonHTTPResponse
  /// Engine emitted an `{"event":"error",…}` meta-frame mid-stream.
  /// Surfaces the original `code`/`message` so the GUI can render
  /// the engine's diagnostic text rather than a generic transport
  /// failure.
  case stream(code: String, message: String)
  /// The `baseURLProvider` reported the engine has no loopback URL
  /// yet (e.g. `PieSupervisor` is still in `.starting`). Surface this
  /// as a distinct case so views can render "engine not ready" rather
  /// than a generic network failure.
  case engineNotReady(detail: String)
}

extension HTTPEngineError: LocalizedError, CustomStringConvertible {
  public var errorDescription: String? { description }

  public var description: String {
    switch self {
    case let .api(status, code, message):
      if code.isEmpty {
        return "Engine error (HTTP \(status)): \(message)"
      }
      return "Engine error (\(code)): \(message)"
    case let .http(status, body):
      let bodyText = String(decoding: body, as: UTF8.self)
      if bodyText.isEmpty {
        return "Engine returned HTTP \(status)"
      }
      return "Engine returned HTTP \(status): \(bodyText)"
    case .nonHTTPResponse:
      return "Engine returned a non-HTTP response"
    case let .stream(code, message):
      if code.isEmpty {
        return "Engine stream error: \(message)"
      }
      return "Engine stream error (\(code)): \(message)"
    case let .engineNotReady(detail):
      return detail.isEmpty ? "Engine not ready" : "Engine not ready: \(detail)"
    }
  }
}
