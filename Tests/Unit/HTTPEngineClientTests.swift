import XCTest
@testable import RatioThink

/// Unit coverage for `HTTPEngineClient`. Uses a `URLProtocol` subclass
/// to intercept every `URLSession` request so tests run with zero
/// real-network exposure and full control over chunk timing for SSE
/// streams. The engine binary is not started for these tests — that
/// lives in `Scenarios/S6` (real-stack integration).
final class HTTPEngineClientTests: XCTestCase {

  // MARK: - Test plumbing

  /// Per-test handler the protocol stub consults. `setUp` resets it so
  /// stray state can't leak between cases. Stored on the protocol
  /// class itself (not a per-instance) because `URLProtocol` is
  /// instantiated by `URLSession` — we don't own the lifecycle.
  override func setUp() {
    super.setUp()
    FakeSSEURLProtocol.reset()
  }

  override func tearDown() {
    FakeSSEURLProtocol.reset()
    super.tearDown()
  }

  /// Build a client whose `URLSession` routes every request through
  /// `FakeSSEURLProtocol`. `baseURL` is a sentinel — the protocol stub
  /// ignores it and serves whatever the per-test handler emits.
  private func makeClient() -> HTTPEngineClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [FakeSSEURLProtocol.self]
    let session = URLSession(configuration: config)
    return HTTPEngineClient(
      baseURL: URL(string: "http://127.0.0.1:54321")!,
      session: session,
      unaryTimeout: 5
    )
  }

  // MARK: - health()

  func test_health_decodes_pie_control_minimal_shape() async throws {
    FakeSSEURLProtocol.handler = { _ in
      .json(status: 200, body: #"{"status":"ok"}"#)
    }
    let health = try await makeClient().health()
    XCTAssertEqual(health.status, .ok)
    XCTAssertNil(health.loadedModel, "pie-control v1 omits `model`")
    XCTAssertNil(health.uptimeSeconds, "pie-control v1 omits `uptime_s`")
  }

  func test_health_decodes_full_shape_when_engine_supplies_it() async throws {
    FakeSSEURLProtocol.handler = { _ in
      .json(
        status: 200,
        body: #"{"status":"ok","model":"qwen3-0.6b","uptime_s":42.5}"#
      )
    }
    let health = try await makeClient().health()
    XCTAssertEqual(health.status, .ok)
    XCTAssertEqual(health.loadedModel, "qwen3-0.6b")
    XCTAssertEqual(health.uptimeSeconds, 42.5)
  }

  func test_health_non_2xx_with_envelope_throws_api_error() async {
    // Engine returned an OpenAI-shape {"error":{code,message}} envelope.
    // The canonical `code` must be surfaced rather than
    // buried in raw body bytes, reaching parity with the SSE `.stream`
    // channel so a fault is traceable end-to-end by the same code space.
    FakeSSEURLProtocol.handler = { _ in
      .json(status: 500, body: #"{"error":{"code":"server_error","message":"boom"}}"#)
    }
    do {
      _ = try await makeClient().health()
      XCTFail("expected throw")
    } catch let HTTPEngineError.api(status, code, message) {
      XCTAssertEqual(status, 500)
      XCTAssertEqual(code, "server_error")
      XCTAssertEqual(message, "boom")
    } catch {
      XCTFail("unexpected: \(error)")
    }
  }

  func test_health_non_2xx_without_envelope_falls_back_to_http() async {
    // Bodies that don't parse as an error envelope (e.g. pie's daemon
    // bare anyhow 500 text) fall back to `.http` with the raw bytes.
    // Absence of a code is itself the "engine-internal, not
    // inferlet-coded" signal ( map-at-boundary).
    FakeSSEURLProtocol.handler = { _ in
      .json(status: 500, body: "internal server error")
    }
    do {
      _ = try await makeClient().health()
      XCTFail("expected throw")
    } catch let HTTPEngineError.http(status, body, retryAfter) {
      XCTAssertEqual(status, 500)
      XCTAssertEqual(String(decoding: body, as: UTF8.self), "internal server error")
      XCTAssertNil(retryAfter, "no Retry-After header was sent")
    } catch {
      XCTFail("unexpected: \(error)")
    }
  }

  // MARK: - FaultClass (pie#375 status taxonomy)

  // Pure classification: status + tag body → EngineFaultClass, derived
  // off the error without any network plumbing.

  func test_faultClass_500_isHostSetup_notRetryable() {
    let err = HTTPEngineError.http(status: 500, body: Data("instantiate-failed".utf8), retryAfter: nil)
    XCTAssertEqual(err.faultClass, .hostSetup(tag: "instantiate-failed"))
    XCTAssertFalse(err.isRetryable)
  }

  func test_faultClass_502_isGuestFault_notRetryable() {
    let err = HTTPEngineError.http(status: 502, body: Data("handler-trap".utf8), retryAfter: nil)
    XCTAssertEqual(err.faultClass, .guestFault(tag: "handler-trap"))
    XCTAssertFalse(err.isRetryable)
  }

  func test_faultClass_503_isInFlightCrash_carriesRetryAfter_andRetryable() {
    let err = HTTPEngineError.http(status: 503, body: Data("handler-panic".utf8), retryAfter: 1)
    XCTAssertEqual(err.faultClass, .inFlightCrash(tag: "handler-panic", retryAfter: 1))
    XCTAssertTrue(err.isRetryable)
  }

  func test_faultClass_nonTaxonomyStatus_andOtherCases_areNil() {
    // A non-FaultClass status (e.g. 404) is not part of the engine-fault
    // axis, and neither are the inferlet-coded `.api`/`.stream` cases.
    XCTAssertNil(HTTPEngineError.http(status: 404, body: Data("nope".utf8), retryAfter: nil).faultClass)
    XCTAssertNil(HTTPEngineError.api(status: 400, code: "invalid_request", message: "bad").faultClass)
    XCTAssertNil(HTTPEngineError.stream(code: "x", message: "y").faultClass)
    XCTAssertFalse(HTTPEngineError.http(status: 404, body: Data(), retryAfter: nil).isRetryable)
  }

  // Rendering: documented tags get plain-language copy; unknown tags
  // fall back to a status-class line that still preserves the raw tag.

  func test_description_knownTags_arePlainLanguage() {
    func desc(_ status: Int, _ tag: String) -> String {
      HTTPEngineError.http(status: status, body: Data(tag.utf8), retryAfter: nil).description
    }
    XCTAssertEqual(desc(503, "handler-panic"), "The engine restarted while answering. Try again in a moment.")
    XCTAssertEqual(desc(502, "handler-trap"), "The engine crashed while answering the request.")
    XCTAssertEqual(desc(500, "instantiate-failed"), "The engine could not start the inferlet.")
    XCTAssertEqual(desc(502, "outparam-never-set"), "The engine returned no response.")
    // No longer the opaque pre-FaultClass shape.
    XCTAssertFalse(desc(503, "handler-panic").contains("HTTP 503"))
  }

  func test_description_unknownTag_keepsStatusClassAndRawTag() {
    let err = HTTPEngineError.http(status: 500, body: Data("some-novel-internal-fault".utf8), retryAfter: nil)
    XCTAssertEqual(err.description, "The engine could not start (some-novel-internal-fault).")
    // An unknown 503 still reads as retry-soon (handler-panic is the only
    // 503 tag, so the class copy covers any future 503 tag too).
    let unknown503 = HTTPEngineError.http(status: 503, body: Data("future-tag".utf8), retryAfter: 2)
    XCTAssertEqual(unknown503.description, "The engine restarted while answering. Try again in a moment.")
  }

  func test_description_nonTaxonomyStatus_keepsLegacyShape() {
    // Outside 500/502/503 the pre-FaultClass rendering is retained.
    XCTAssertEqual(
      HTTPEngineError.http(status: 418, body: Data("teapot".utf8), retryAfter: nil).description,
      "Engine returned HTTP 418: teapot")
    XCTAssertEqual(
      HTTPEngineError.http(status: 418, body: Data(), retryAfter: nil).description,
      "Engine returned HTTP 418")
  }

  // Boundary plumbing: the Retry-After header is parsed off the real
  // HTTPURLResponse in assertOK and carried into the error — proven on
  // BOTH the unary and the streaming guard.

  func test_unary_503_parsesRetryAfter_intoFaultClass() async {
    FakeSSEURLProtocol.handler = { _ in
      .text(status: 503, body: "handler-panic", headers: ["Retry-After": "1"])
    }
    do {
      _ = try await makeClient().health()
      XCTFail("expected throw")
    } catch let error as HTTPEngineError {
      XCTAssertEqual(error.faultClass, .inFlightCrash(tag: "handler-panic", retryAfter: 1))
      XCTAssertTrue(error.isRetryable)
    } catch {
      XCTFail("unexpected: \(error)")
    }
  }

  func test_streaming_chat_503_parsesRetryAfter_intoFaultClass() async {
    // The in-flight-crash 503 surfaces on the chat path's pre-stream
    // guard (assertOK(_:bytes:)), the actual handler-panic site.
    FakeSSEURLProtocol.handler = { _ in
      .text(status: 503, body: "handler-panic", headers: ["Retry-After": "1"])
    }
    do {
      for try await _ in makeClient().chatCompletion(.init(model: "m", messages: [], stream: true)) {}
      XCTFail("expected throw")
    } catch let error as HTTPEngineError {
      XCTAssertEqual(error.faultClass, .inFlightCrash(tag: "handler-panic", retryAfter: 1))
    } catch {
      XCTFail("unexpected: \(error)")
    }
  }

  // MARK: - models()

  func test_models_unwraps_data_envelope() async throws {
    FakeSSEURLProtocol.handler = { _ in
      .json(status: 200, body: """
        {"object":"list","data":[
          {"id":"qwen3-0.6b","object":"model","owned_by":"pie"},
          {"id":"qwen3-7b","object":"model","owned_by":"pie","created":1700000000}
        ]}
        """)
    }
    let models = try await makeClient().models()
    XCTAssertEqual(models.count, 2)
    XCTAssertEqual(models[0].id, "qwen3-0.6b")
    XCTAssertEqual(models[0].ownedBy, "pie")
    XCTAssertNil(models[0].created, "pie-control omits `created` in v1")
    XCTAssertEqual(models[1].created, Date(timeIntervalSince1970: 1_700_000_000))
  }


  // MARK: - chatCompletion SSE

  func test_chatCompletion_demuxes_meta_prefix_then_deltas_then_finish() async throws {
    FakeSSEURLProtocol.handler = { _ in
      .sse(chunks: [
        // Meta prefix.
        "data: {\"event\":\"model_ready\"}\n\n",
        // First content chunk carries role.
        #"data: {"id":"c1","object":"chat.completion.chunk","created":1,"model":"m1","choices":[{"index":0,"delta":{"role":"assistant","content":"hello"}}]}"# + "\n\n",
        // Subsequent chunks: content only.
        #"data: {"id":"c1","object":"chat.completion.chunk","created":1,"model":"m1","choices":[{"index":0,"delta":{"content":" world"}}]}"# + "\n\n",
        // Terminal chunk with finish_reason; OpenAI emits an empty delta here.
        #"data: {"id":"c1","object":"chat.completion.chunk","created":1,"model":"m1","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"# + "\n\n",
        "data: [DONE]\n\n",
      ])
    }
    let req = ChatRequest(model: "m1", messages: [ChatMessage(role: .user, content: "hi")])
    var events: [ChatEvent] = []
    for try await ev in makeClient().chatCompletion(req) {
      events.append(ev)
    }
    XCTAssertEqual(events, [
      .modelReady,
      .delta(role: .assistant, content: "hello"),
      .delta(role: nil, content: " world"),
      .finish(reason: .stop),
    ])
  }

  func test_chatCompletion_routes_reasoning_content_to_its_own_channel() async throws {
    // chat-apc wire order for a Qwen thinking turn: model_ready,
    // role chunk, reasoning_content deltas, then visible content, finish.
    // The closing </think> delimiter never appears on either channel —
    // the inferlet keeps it off the wire entirely.
    FakeSSEURLProtocol.handler = { _ in
      .sse(chunks: [
        "data: {\"event\":\"model_ready\"}\n\n",
        #"data: {"choices":[{"index":0,"delta":{"role":"assistant"}}]}"# + "\n\n",
        #"data: {"choices":[{"index":0,"delta":{"reasoning_content":"the user said"}}]}"# + "\n\n",
        #"data: {"choices":[{"index":0,"delta":{"reasoning_content":" hi"}}]}"# + "\n\n",
        #"data: {"choices":[{"index":0,"delta":{"content":"Hello!"}}]}"# + "\n\n",
        #"data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"# + "\n\n",
        "data: [DONE]\n\n",
      ])
    }
    let req = ChatRequest(model: "m1", messages: [ChatMessage(role: .user, content: "hi")])
    var events: [ChatEvent] = []
    for try await ev in makeClient().chatCompletion(req) {
      events.append(ev)
    }
    XCTAssertEqual(events, [
      .modelReady,
      .delta(role: .assistant, content: ""),
      .reasoningDelta("the user said"),
      .reasoningDelta(" hi"),
      .delta(role: nil, content: "Hello!"),
      .finish(reason: .stop),
    ])
    // No reasoning text bled into the visible-content channel.
    let visible = events.compactMap { event -> String? in
      if case let .delta(_, content) = event { return content }
      return nil
    }.joined()
    XCTAssertEqual(visible, "Hello!")
  }

  func test_chatCompletion_unknown_finish_reason_maps_to_other() async throws {
    FakeSSEURLProtocol.handler = { _ in
      .sse(chunks: [
        "data: {\"event\":\"model_ready\"}\n\n",
        #"data: {"choices":[{"index":0,"delta":{"role":"assistant","content":"x"}}]}"# + "\n\n",
        #"data: {"choices":[{"index":0,"delta":{},"finish_reason":"content_filter"}]}"# + "\n\n",
        "data: [DONE]\n\n",
      ])
    }
    var events: [ChatEvent] = []
    for try await ev in makeClient().chatCompletion(
      ChatRequest(model: "m1", messages: [ChatMessage(role: .user, content: "x")])
    ) { events.append(ev) }
    XCTAssertEqual(events.last, .finish(reason: .other("content_filter")))
  }

  func test_chatCompletion_inline_error_frame_surfaces_as_stream_error() async {
    FakeSSEURLProtocol.handler = { _ in
      .sse(chunks: [
        "data: {\"event\":\"model_ready\"}\n\n",
        #"data: {"choices":[{"index":0,"delta":{"role":"assistant","content":"oh"}}]}"# + "\n\n",
        #"data: {"event":"error","code":"decoder_panic","message":"boom"}"# + "\n\n",
        "data: [DONE]\n\n",
      ])
    }
    do {
      for try await _ in makeClient().chatCompletion(
        ChatRequest(model: "m1", messages: [ChatMessage(role: .user, content: "x")])
      ) {}
      XCTFail("expected throw")
    } catch let HTTPEngineError.stream(code, message) {
      XCTAssertEqual(code, "decoder_panic")
      XCTAssertEqual(message, "boom")
    } catch {
      XCTFail("unexpected: \(error)")
    }
  }

  func test_chatCompletion_pre_stream_non_2xx_surfaces_api_error() async {
    //  root cause: a chat turn that fails BEFORE the SSE
    // stream opens (model_not_found 404, invalid_request 400, …) must
    // carry the inferlet's {error:{code,message}} envelope, not be
    // flattened to an opaque HTTP status. Previously the streaming path
    // called assertOK(data: nil), leaving the body unread and discarded.
    FakeSSEURLProtocol.handler = { _ in
      .json(status: 404,
            body: #"{"error":{"type":"not_found_error","code":"model_not_found","message":"Model 'x' not registered"}}"#)
    }
    do {
      for try await _ in makeClient().chatCompletion(
        ChatRequest(model: "x", messages: [ChatMessage(role: .user, content: "hi")])
      ) {}
      XCTFail("expected throw")
    } catch let HTTPEngineError.api(status, code, message) {
      XCTAssertEqual(status, 404)
      XCTAssertEqual(code, "model_not_found")
      XCTAssertEqual(message, "Model 'x' not registered")
    } catch {
      XCTFail("unexpected: \(error)")
    }
  }

  /// Review v1 F1 regression: SSE streaming must NOT inherit
  /// `unaryTimeout`. URLRequest.timeoutInterval is an idle timeout
  /// (URLSession drops the request when no bytes arrive in the
  /// window), so applying the 10 s unary cap to chat completions
  /// would cut the stream during a quiet preprompt-processing
  /// window. We construct a client with `unaryTimeout = 0.2` s and
  /// insert a 0.5 s gap between two content frames — the consumer
  /// must still receive the post-gap frame.
  func test_chatCompletion_does_not_apply_unary_timeout_to_sse() async throws {
    FakeSSEURLProtocol.handler = { _ in
      .sse(chunks: [
        "data: {\"event\":\"model_ready\"}\n\n",
        #"data: {"choices":[{"index":0,"delta":{"role":"assistant","content":"a"}}]}"# + "\n\n",
        // 500 ms gap between this and the next frame — exceeds
        // the 200 ms `unaryTimeout` below.
        #"data: {"choices":[{"index":0,"delta":{"content":"b"}}]}"# + "\n\n",
        #"data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"# + "\n\n",
        "data: [DONE]\n\n",
      ], chunkDelayNanos: 500_000_000)
    }
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [FakeSSEURLProtocol.self]
    let session = URLSession(configuration: config)
    let client = HTTPEngineClient(
      baseURL: URL(string: "http://127.0.0.1:54321")!,
      session: session,
      unaryTimeout: 0.2
    )
    var events: [ChatEvent] = []
    for try await ev in client.chatCompletion(
      ChatRequest(model: "m1", messages: [ChatMessage(role: .user, content: "x")])
    ) {
      events.append(ev)
    }
    // Two deltas + finish + (no synthesized finish needed).
    XCTAssertEqual(events.count, 4)
    XCTAssertEqual(events.first, .modelReady)
    XCTAssertEqual(events.last, .finish(reason: .stop))
  }

  /// Review v1 F2 regression: a `model_loading` frame whose schema
  /// drifted (e.g. `loaded_bytes` flipped from integer to string)
  /// must not be silently swallowed — the GUI progress indicator
  /// would stall with no diagnostic. The chat stream must surface
  /// a decoding error mirroring the strict path in `loadStream`.
  /// Optional-field drift (e.g. snake_case → camelCase renames)
  /// silently decodes to nil because `MetaFrame.loaded_bytes` is
  /// optional, so we exercise the type-mismatch path which is what
  /// `try?` would have swallowed under the previous implementation.
  func test_chatCompletion_drifted_model_loading_frame_surfaces_decoding_error() async {
    FakeSSEURLProtocol.handler = { _ in
      .sse(chunks: [
        // Type drift: `loaded_bytes` arrives as a string. Under
        // the previous `try?` swallow, the chat stream would
        // continue with no event and no diagnostic.
        #"data: {"event":"model_loading","loaded_bytes":"100","total_bytes":1000}"# + "\n\n",
        "data: {\"event\":\"model_ready\"}\n\n",
        "data: [DONE]\n\n",
      ])
    }
    do {
      for try await _ in makeClient().chatCompletion(
        ChatRequest(model: "m1", messages: [ChatMessage(role: .user, content: "x")])
      ) {}
      XCTFail("expected decoding error to propagate")
    } catch is DecodingError {
      // Pass — strict decode surfaced the drift.
    } catch {
      XCTFail("expected DecodingError, got \(error)")
    }
  }

  /// Review v1 F4 regression: per the `EngineClient` contract
  /// streams end with exactly one `.finish`. If the engine
  /// truncates and emits `[DONE]` without a preceding chunk
  /// carrying `finish_reason`, the client must synthesize a
  /// terminal frame so downstream cleanup anchored on `.finish`
  /// still fires.
  func test_chatCompletion_synthesizes_finish_when_engine_omits_finish_reason() async throws {
    FakeSSEURLProtocol.handler = { _ in
      .sse(chunks: [
        "data: {\"event\":\"model_ready\"}\n\n",
        #"data: {"choices":[{"index":0,"delta":{"role":"assistant","content":"hi"}}]}"# + "\n\n",
        // No `finish_reason` chunk — engine closes with bare `[DONE]`.
        "data: [DONE]\n\n",
      ])
    }
    var events: [ChatEvent] = []
    for try await ev in makeClient().chatCompletion(
      ChatRequest(model: "m1", messages: [ChatMessage(role: .user, content: "x")])
    ) { events.append(ev) }
    XCTAssertEqual(events.last, .finish(reason: .other("missing_finish_reason")),
                   "synthesized terminal frame missing; got events=\(events)")
  }

  func test_chatCompletion_consumer_break_cancels_stream() async throws {
    // Stream emits a slow sequence; consumer breaks early. The
    // `onTermination` hook must propagate task cancellation so the
    // network task tears down without leaking.
    FakeSSEURLProtocol.handler = { _ in
      var frames = ["data: {\"event\":\"model_ready\"}\n\n"]
      for _ in 0..<100 {
        frames.append(#"data: {"choices":[{"index":0,"delta":{"content":"x"}}]}"# + "\n\n")
      }
      frames.append("data: [DONE]\n\n")
      return .sse(chunks: frames, chunkDelayNanos: 5_000_000) // 5ms between chunks
    }
    var collected: [ChatEvent] = []
    for try await ev in makeClient().chatCompletion(
      ChatRequest(model: "m1", messages: [ChatMessage(role: .user, content: "x")])
    ) {
      collected.append(ev)
      if collected.count == 3 { break }
    }
    XCTAssertEqual(collected.count, 3)
  }

  // MARK: - dispatchInferlet

  func test_dispatchInferlet_yields_raw_frame_bytes() async throws {
    FakeSSEURLProtocol.handler = { _ in
      .sse(chunks: [
        "data: {\"frame\":1}\n\n",
        "data: {\"frame\":2}\n\n",
        "data: [DONE]\n\n",
      ])
    }
    let req = InferletRequest(
      inferlet: "chat-apc",
      input: Data(#"{"messages":[{"role":"user","content":"hi"}]}"#.utf8)
    )
    var frames: [String] = []
    for try await frame in makeClient().dispatchInferlet(req) {
      frames.append(String(decoding: frame, as: UTF8.self))
    }
    XCTAssertEqual(frames, [#"{"frame":1}"#, #"{"frame":2}"#])
  }

  // MARK: - Request body shape

  func test_chatCompletion_request_body_is_openai_flat() async throws {
    let captured = RequestCapture()
    FakeSSEURLProtocol.handler = { req in
      captured.set(req)
      return .sse(chunks: ["data: [DONE]\n\n"])
    }
    let req = ChatRequest(
      model: "m1",
      messages: [ChatMessage(role: .user, content: "hi")],
      sampling: ChatSampling(temperature: 0.3, topP: 0.85, maxTokens: 32),
      stream: true
    )
    for try await _ in makeClient().chatCompletion(req) {}
    let bodyData = try XCTUnwrap(captured.body())
    let top = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
    XCTAssertNil(top["sampling"], "sampling envelope must not appear on the wire")
    XCTAssertEqual(top["model"] as? String, "m1")
    XCTAssertEqual(top["temperature"] as? Double, 0.3)
    XCTAssertEqual(top["top_p"] as? Double, 0.85)
    XCTAssertEqual(top["max_tokens"] as? Int, 32)
  }

  // MARK: - SSE parser (line-level)

  func test_sse_parser_joins_multiline_data_fields() async throws {
    // Per EventSource spec: multiple `data:` lines in one frame
    // join on newline. pie-control doesn't emit this today but a
    // future inferlet might, and the parser shouldn't silently drop
    // continuation lines.
    let lines = Self.lineStream(from: "data: line1\ndata: line2\n\ndata: solo\n\n")
    var frames: [HTTPEngineClient.SSEFrame] = []
    for try await frame in HTTPEngineClient.sseFrames(from: lines) {
      frames.append(frame)
    }
    XCTAssertEqual(frames.count, 2)
    XCTAssertEqual(frames[0].data, "line1\nline2")
    XCTAssertEqual(frames[1].data, "solo")
  }

  func test_sse_parser_ignores_comment_and_meta_lines() async throws {
    let lines = Self.lineStream(from: ": keepalive\nevent: ignored\ndata: only\n\n")
    var frames: [HTTPEngineClient.SSEFrame] = []
    for try await frame in HTTPEngineClient.sseFrames(from: lines) {
      frames.append(frame)
    }
    XCTAssertEqual(frames.map(\.data), ["only"])
  }

  // MARK: - Helpers

  /// Split a fixture string on `\n` into an `AsyncStream<String>`
  /// shaped like `URLSession.AsyncBytes.lines` would surface them.
  /// Trailing empty token is preserved so the parser sees the
  /// frame-terminating blank line.
  private static func lineStream(from string: String) -> AsyncStream<String> {
    let parts = string.split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    return AsyncStream { continuation in
      for line in parts {
        continuation.yield(line)
      }
      continuation.finish()
    }
  }

  // MARK: - streaming idle-timeout

  ///  regression: a silent SSE stream must NOT be aborted at the
  /// 60 s URLSession idle default. The idle cap is the *more restrictive*
  /// of `URLRequest.timeoutInterval` and the session's
  /// `timeoutIntervalForRequest`, so BOTH must be lifted. A real 60 s
  /// timeout is impractical to exercise, so assert the two wiring points
  /// directly: (a) the default session lifts the per-request idle cap,
  /// and (b) each streaming request carries the lifted timeout while
  /// unary requests keep the short `unaryTimeout`.

  func test_default_session_lifts_request_idle_timeout() {
    // No injected session → the client builds its default session.
    let client = HTTPEngineClient(baseURL: URL(string: "http://127.0.0.1:1")!)
    XCTAssertEqual(
      client.session.configuration.timeoutIntervalForRequest,
      HTTPEngineClient.streamingIdleTimeout,
      "default session must lift the 60s per-request idle cap so a silent SSE load is not aborted")
  }

  func test_chatCompletion_request_carries_streaming_idle_timeout() async throws {
    var captured: TimeInterval?
    FakeSSEURLProtocol.handler = { request in
      captured = request.timeoutInterval
      return .sse(chunks: ["data: {\"event\":\"model_ready\"}\n\n", "data: [DONE]\n\n"])
    }
    for try await _ in makeClient().chatCompletion(
      ChatRequest(model: "m1", messages: [ChatMessage(role: .user, content: "x")])
    ) {}
    XCTAssertEqual(captured, HTTPEngineClient.streamingIdleTimeout,
                   "POST /v1/chat/completions must carry the lifted idle timeout, not the 60s default")
  }

  func test_unary_request_keeps_short_unary_timeout() async throws {
    var captured: TimeInterval?
    FakeSSEURLProtocol.handler = { request in
      captured = request.timeoutInterval
      return .json(status: 200, body: #"{"status":"ok"}"#)
    }
    _ = try await makeClient().health()
    // makeClient() constructs the client with unaryTimeout: 5.
    XCTAssertEqual(captured, 5,
                   "unary GET /healthz must keep the short unaryTimeout, not the streaming idle cap")
  }

  /// Review F6: `dispatchInferlet` is the third streaming endpoint
  /// modified by  (HTTPEngineClient.swift). Without an explicit
  /// regression a future "simplification" that drops the `timeout:`
  /// argument because "the session config already covers it" silently
  /// reintroduces the 60 s idle cap for inferlet streams (the more-
  /// restrictive request leg would default back to 60 s).
  func test_dispatchInferlet_request_carries_streaming_idle_timeout() async throws {
    var captured: TimeInterval?
    FakeSSEURLProtocol.handler = { request in
      captured = request.timeoutInterval
      return .sse(chunks: ["data: {\"event\":\"model_ready\"}\n\n", "data: [DONE]\n\n"])
    }
    let req = InferletRequest(
      inferlet: "chat-apc",
      input: Data(#"{"messages":[{"role":"user","content":"hi"}]}"#.utf8)
    )
    for try await _ in makeClient().dispatchInferlet(req) {}
    XCTAssertEqual(captured, HTTPEngineClient.streamingIdleTimeout,
                   "POST /v1/inferlet must carry the lifted idle timeout, not the 60s default")
  }

  /// Review F1: the default `URLSession` is a process-lifetime singleton
  /// (a fresh `URLSession(configuration:)` per instance leaks the
  /// session + its operation queue since `HTTPEngineClient` has no
  /// `deinit` to invalidate it). Two clients constructed without an
  /// injected session must therefore share the SAME session instance.
  func test_default_session_is_shared_across_instances() {
    let a = HTTPEngineClient(baseURL: URL(string: "http://127.0.0.1:1")!)
    let b = HTTPEngineClient(baseURL: URL(string: "http://127.0.0.1:2")!)
    XCTAssertTrue(a.session === b.session,
                  "default URLSession must be a shared singleton; per-instance allocation would leak")
  }
}

// MARK: - URLProtocol fake

/// In-process stand-in for the engine's HTTP+SSE listener. Registered
/// on the test session's `URLSessionConfiguration.protocolClasses`, so
/// every `URLSession.bytes` / `URLSession.data` call routes here.
final class FakeSSEURLProtocol: URLProtocol {

  enum Stub {
    /// JSON response body (Content-Type: application/json).
    case json(status: Int, body: String)
    /// Plain-text response body with caller-supplied headers — used to
    /// drive pie's `FaultClass` tag bodies + the `503` `Retry-After`
    /// header through the real `assertOK` boundary.
    case text(status: Int, body: String, headers: [String: String])
    /// SSE stream. Chunks land via repeated `didLoad:` calls so
    /// `URLSession.bytes(for:)` surfaces them incrementally.
    case sse(chunks: [String], chunkDelayNanos: UInt64 = 0)
  }

  private static let lock = NSLock()
  private static var _handler: ((URLRequest) -> Stub)?

  /// Per-test handler. The closure is invoked once per intercepted
  /// request and may inspect the body / URL to vary its response.
  static var handler: ((URLRequest) -> Stub)? {
    get { lock.lock(); defer { lock.unlock() }; return _handler }
    set { lock.lock(); _handler = newValue; lock.unlock() }
  }

  static func reset() {
    handler = nil
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  private var cancelled = false

  override func startLoading() {
    guard let handler = Self.handler else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    let stub = handler(request)

    switch stub {
    case .json(let status, let body):
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]
      )!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data(body.utf8))
      client?.urlProtocolDidFinishLoading(self)

    case .text(let status, let body, let headers):
      var headerFields = ["Content-Type": "text/plain"]
      headerFields.merge(headers) { _, new in new }
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: headerFields
      )!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data(body.utf8))
      client?.urlProtocolDidFinishLoading(self)

    case .sse(let chunks, let delayNanos):
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "text/event-stream"]
      )!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      // Emit chunks on a background task so URLSession can pump them
      // through to the consumer iteratively (the consumer is awaiting
      // on `bytes(for:)` and would not progress past the response head
      // if we serialized the entire body before returning here).
      let client = self.client
      let proto = self
      Task {
        for chunk in chunks {
          if proto.cancelled { break }
          if delayNanos > 0 {
            try? await Task.sleep(nanoseconds: delayNanos)
          }
          client?.urlProtocol(proto, didLoad: Data(chunk.utf8))
        }
        client?.urlProtocolDidFinishLoading(proto)
      }
    }
  }

  override func stopLoading() {
    cancelled = true
  }
}

// MARK: - Request capture helper

/// Thread-safe holder for a captured `URLRequest` so the streaming
/// handler closure can stash the request body for the test to assert
/// on after iteration ends.
private final class RequestCapture: @unchecked Sendable {
  private let lock = NSLock()
  private var _request: URLRequest?

  func set(_ req: URLRequest) {
    lock.lock(); _request = req; lock.unlock()
  }

  /// `URLSession` strips the `httpBody` on URLRequest passed to
  /// URLProtocol because the body may be a stream; we recover it
  /// from `httpBodyStream` if needed.
  func body() -> Data? {
    lock.lock(); defer { lock.unlock() }
    guard let req = _request else { return nil }
    if let body = req.httpBody { return body }
    guard let stream = req.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    let bufSize = 4096
    var buffer = [UInt8](repeating: 0, count: bufSize)
    while stream.hasBytesAvailable {
      let n = stream.read(&buffer, maxLength: bufSize)
      if n <= 0 { break }
      data.append(buffer, count: n)
    }
    return data
  }
}
