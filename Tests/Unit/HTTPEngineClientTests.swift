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

  func test_chatCompletion_demuxes_usage_meta_frame() async throws {
    // #711: the engine-true context meter rides a trailing `event:"usage"`
    // meta-frame between the terminal chunk and `[DONE]`. It must demux to
    // a `.usage` event (off the `.delta`/`.finish` content path) carrying
    // the occupancy + window.
    FakeSSEURLProtocol.handler = { _ in
      .sse(chunks: [
        "data: {\"event\":\"model_ready\"}\n\n",
        #"data: {"choices":[{"index":0,"delta":{"role":"assistant","content":"hi"}}]}"# + "\n\n",
        #"data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"# + "\n\n",
        #"data: {"event":"usage","prompt_tokens":40,"completion_tokens":8,"total_tokens":48,"context_window":4096}"# + "\n\n",
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
      .delta(role: .assistant, content: "hi"),
      .finish(reason: .stop),
      .usage(used: 48, window: 4096),
    ])
  }

  func test_chatCompletion_usage_frame_without_window_yields_nil_window() async throws {
    // The engine omits `context_window` when it could not measure the KV
    // budget; the meter must surface `window: nil` (indeterminate) rather
    // than defaulting to a wrong denominator.
    FakeSSEURLProtocol.handler = { _ in
      .sse(chunks: [
        "data: {\"event\":\"model_ready\"}\n\n",
        #"data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"# + "\n\n",
        #"data: {"event":"usage","prompt_tokens":10,"completion_tokens":2,"total_tokens":12}"# + "\n\n",
        "data: [DONE]\n\n",
      ])
    }
    let req = ChatRequest(model: "m1", messages: [ChatMessage(role: .user, content: "hi")])
    var events: [ChatEvent] = []
    for try await ev in makeClient().chatCompletion(req) {
      events.append(ev)
    }
    XCTAssertEqual(events.last, .usage(used: 12, window: nil))
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

  func test_chatCompletion_decodesGenerationMetricsMetaFrame() async throws {
    FakeSSEURLProtocol.handler = { _ in
      .sse(chunks: [
        #"data: {"event":"model_ready"}"# + "\n\n",
        #"data: {"choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}"# + "\n\n",
        #"data: {"choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}"# + "\n\n",
        #"data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"# + "\n\n",
        #"data: {"event":"generation_metrics","output_tokens":12,"elapsed_s":0.5,"tokens_per_sec":24.0}"# + "\n\n",
        "data: [DONE]\n\n",
      ])
    }
    var events: [ChatEvent] = []
    for try await event in makeClient().chatCompletion(ChatRequest(model: "m", messages: [])) {
      events.append(event)
    }

    let expected = GenerationMetrics(outputTokens: 12, elapsedSeconds: 0.5, tokensPerSecond: 24.0)
    XCTAssertTrue(events.contains(.generationMetrics(expected)), "events=\(events)")
  }

  func test_chatCompletion_malformedGenerationMetricsAfterFinishThrows() async {
    FakeSSEURLProtocol.handler = { _ in
      .sse(chunks: [
        #"data: {"choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}"# + "\n\n",
        #"data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"# + "\n\n",
        #"data: {"event":"generation_metrics","output_tokens":12,"elapsed_s":0.5}"# + "\n\n",
        "data: [DONE]\n\n",
      ])
    }
    var events: [ChatEvent] = []
    do {
      for try await event in makeClient().chatCompletion(ChatRequest(model: "m", messages: [])) {
        events.append(event)
      }
      XCTFail("expected malformed generation_metrics to throw")
    } catch {
      XCTAssertEqual(events.last, .finish(reason: .stop))
      XCTAssertFalse(
        events.contains(.generationMetrics(GenerationMetrics(
          outputTokens: 12,
          elapsedSeconds: 0.5,
          tokensPerSecond: 0
        ))),
        "malformed metrics must not be zero-filled: events=\(events)"
      )
      XCTAssertTrue(error is DecodingError, "expected strict frame decode error, got \(error)")
    }
  }

  func test_chatCompletion_terminal_spec_metrics_frame_decodes_to_event() async throws {
    // chat-apc #418/#621: a "Repeat Boost" turn closes with a terminal
    // `spec_metrics` frame AFTER the finish chunk and before `[DONE]`. It
    // must surface as a `.specMetrics` event (previously dropped by the
    // demux `default`), and the accept ratio derives from the draft counts.
    FakeSSEURLProtocol.handler = { _ in
      .sse(chunks: [
        #"data: {"choices":[{"index":0,"delta":{"role":"assistant","content":"hi"}}]}"# + "\n\n",
        #"data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"# + "\n\n",
        #"data: {"event":"spec_metrics","enabled":true,"generated_tokens":40,"decode_steps":18,"proposed_draft_tokens":30,"accepted_draft_tokens":24,"rejected_draft_tokens":6,"avg_tokens_per_step":2.222,"decode_tokens_per_sec":85.5,"leader_len":1,"draft_len":4}"# + "\n\n",
        "data: [DONE]\n\n",
      ])
    }
    var events: [ChatEvent] = []
    for try await ev in makeClient().chatCompletion(
      ChatRequest(model: "m1", messages: [ChatMessage(role: .user, content: "x")])
    ) { events.append(ev) }

    // The metrics frame rides AFTER finish.
    XCTAssertEqual(events.count, 3)
    XCTAssertEqual(events[1], .finish(reason: .stop))
    guard case let .specMetrics(metrics) = events[2] else {
      return XCTFail("expected terminal .specMetrics, got \(String(describing: events.last))")
    }
    XCTAssertTrue(metrics.enabled)
    XCTAssertNil(metrics.fallbackReason)
    XCTAssertEqual(metrics.proposedDraftTokens, 30)
    XCTAssertEqual(metrics.acceptedDraftTokens, 24)
    XCTAssertEqual(metrics.acceptRatio, 0.8)
    XCTAssertEqual(metrics.avgTokensPerStep, 2.222, accuracy: 1e-6)
  }

  func test_chatCompletion_inactive_spec_metrics_frame_carries_fallback_reason() async throws {
    // Speculation requested but not engaged (non-greedy): `enabled:false`,
    // zero proposals → `acceptRatio == nil` (not a misleading 0%).
    FakeSSEURLProtocol.handler = { _ in
      .sse(chunks: [
        #"data: {"choices":[{"index":0,"delta":{"content":"x"},"finish_reason":"stop"}]}"# + "\n\n",
        #"data: {"event":"spec_metrics","enabled":false,"fallback_reason":"non_greedy_sampling","generated_tokens":5,"decode_steps":5,"proposed_draft_tokens":0,"accepted_draft_tokens":0,"rejected_draft_tokens":0,"avg_tokens_per_step":1.0,"decode_tokens_per_sec":12.0,"leader_len":0,"draft_len":0}"# + "\n\n",
        "data: [DONE]\n\n",
      ])
    }
    var metrics: SpecMetrics?
    for try await ev in makeClient().chatCompletion(
      ChatRequest(model: "m1", messages: [ChatMessage(role: .user, content: "x")])
    ) { if case let .specMetrics(m) = ev { metrics = m } }
    XCTAssertEqual(metrics?.enabled, false)
    XCTAssertEqual(metrics?.fallbackReason, "non_greedy_sampling")
    XCTAssertNil(metrics?.acceptRatio)
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
      inferlet: "tree-of-thought",
      input: Data(#"{"model":"m","messages":[{"role":"user","content":"hi"}],"breadth":1,"depth":1,"beam_width":1,"max_tokens_per_node":16}"#.utf8)
    )
    var frames: [String] = []
    for try await frame in makeClient().dispatchInferlet(req) {
      frames.append(String(decoding: frame, as: UTF8.self))
    }
    XCTAssertEqual(frames, [#"{"frame":1}"#, #"{"frame":2}"#])
  }

  /// #703 transport decision: a `stream: false` CONTROL dispatch takes the
  /// UNARY path — the inferlet's plain `application/json` ack (no `data:`
  /// framing) is buffered whole and yielded as the stream's single frame. The
  /// old SSE-only path would strip it (no `data:` lines) and surface zero
  /// frames, hiding the release accounting.
  func test_dispatchInferlet_unary_control_yields_unframed_json_body() async throws {
    FakeSSEURLProtocol.handler = { _ in
      .json(
        status: 200,
        body: #"{"object":"best_of_n.release","requested":3,"released":2,"absent":1}"#)
    }
    let req = InferletRequest(
      inferlet: "best-of-n",
      input: Data(#"{"release":["a","b","c"]}"#.utf8),
      messages: nil,
      stream: false)
    var frames: [Data] = []
    for try await frame in makeClient().dispatchInferlet(req) {
      frames.append(frame)
    }
    XCTAssertEqual(frames.count, 1, "unary control returns exactly one buffered frame")
    let ack = try JSONDecoder().decode(BestOfNReleaseAck.self, from: try XCTUnwrap(frames.first))
    XCTAssertEqual(ack, BestOfNReleaseAck(requested: 3, released: 2, absent: 1))
  }

  /// The unary control path surfaces a non-2xx as an error (via `assertOK`)
  /// rather than yielding a frame — the release must not silently "succeed" on
  /// an HTTP failure.
  func test_dispatchInferlet_unary_control_non_2xx_throws() async {
    FakeSSEURLProtocol.handler = { _ in
      .json(status: 500, body: #"{"error":{"code":"boom","message":"nope"}}"#)
    }
    let req = InferletRequest(
      inferlet: "best-of-n",
      input: Data(#"{"release":["a"]}"#.utf8),
      messages: nil,
      stream: false)
    do {
      for try await _ in makeClient().dispatchInferlet(req) {}
      XCTFail("expected a non-2xx unary control response to throw")
    } catch {
      // expected
    }
  }

  // MARK: - Connection-lost retry (stale keep-alive reuse)

  /// `URLSession` pools HTTP/1.1 keep-alive connections; a reused one the
  /// engine has closed fails the request with
  /// `URLError.networkConnectionLost` BEFORE any byte arrives. URLSession
  /// auto-retries idempotent GETs but not POSTs, so the streaming dispatch
  /// must retry once itself. First attempt fails at connect; the retry on
  /// a fresh connection succeeds and the full stream is delivered.
  func test_dispatchInferlet_retries_once_on_connection_lost_then_succeeds() async throws {
    let calls = CallCounter()
    FakeSSEURLProtocol.handler = { _ in
      calls.increment() == 1
        ? .failure(.networkConnectionLost)
        : .sse(chunks: [
            "data: {\"frame\":1}\n\n",
            "data: {\"frame\":2}\n\n",
            "data: [DONE]\n\n",
          ])
    }
    let req = InferletRequest(
      inferlet: "tree-of-thought",
      input: Data(#"{"model":"m","messages":[{"role":"user","content":"hi"}],"breadth":1,"depth":1,"beam_width":1,"max_tokens_per_node":16}"#.utf8)
    )
    var frames: [String] = []
    for try await frame in makeClient().dispatchInferlet(req) {
      frames.append(String(decoding: frame, as: UTF8.self))
    }
    XCTAssertEqual(frames, [#"{"frame":1}"#, #"{"frame":2}"#])
    XCTAssertEqual(calls.value, 2, "expected exactly one retry after the connection-lost failure")
  }

  /// The retry is bounded to ONE: a connection-lost on both attempts must
  /// surface the error to the caller, not loop. Guards against turning a
  /// transient remedy into an infinite retry.
  func test_dispatchInferlet_connection_lost_twice_propagates_after_one_retry() async {
    let calls = CallCounter()
    FakeSSEURLProtocol.handler = { _ in
      calls.increment()
      return .failure(.networkConnectionLost)
    }
    let req = InferletRequest(
      inferlet: "chat-apc",
      input: Data(#"{"messages":[{"role":"user","content":"hi"}]}"#.utf8)
    )
    do {
      for try await _ in makeClient().dispatchInferlet(req) {}
      XCTFail("expected the connection-lost error to propagate")
    } catch let error as URLError {
      XCTAssertEqual(error.code, .networkConnectionLost)
    } catch {
      XCTFail("unexpected error type: \(error)")
    }
    XCTAssertEqual(calls.value, 2, "expected exactly two attempts (initial + one retry)")
  }

  /// The same retry covers the production chat path — `chatCompletion`
  /// and `dispatchInferlet` share the connect helper, so a user's chat
  /// send survives a stale pooled connection instead of failing.
  func test_chatCompletion_retries_once_on_connection_lost_then_succeeds() async throws {
    let calls = CallCounter()
    FakeSSEURLProtocol.handler = { _ in
      calls.increment() == 1
        ? .failure(.networkConnectionLost)
        : .sse(chunks: [
            "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n",
            "data: {\"choices\":[{\"finish_reason\":\"stop\"}]}\n\n",
            "data: [DONE]\n\n",
          ])
    }
    let req = ChatRequest(model: "m", messages: [], stream: true)
    var content = ""
    var sawFinish = false
    for try await ev in makeClient().chatCompletion(req) {
      switch ev {
      case let .delta(_, c): content += c
      case .finish: sawFinish = true
      default: break
      }
    }
    XCTAssertEqual(content, "hi")
    XCTAssertTrue(sawFinish)
    XCTAssertEqual(calls.value, 2, "expected exactly one retry after the connection-lost failure")
  }

  /// The retry is scoped to `URLError.networkConnectionLost` ONLY. A
  /// non-2xx HTTP response surfaces as `HTTPEngineError` (not a
  /// `URLError`), so it must NOT be retried — re-sending a request the
  /// server actively rejected is wrong. Asserts a single attempt.
  /// Mutation guard: broadening the retry `catch` to a bare `catch {}`
  /// makes this retry the 503 and the attempt count jumps to 2 → fails.
  func test_dispatchInferlet_non2xx_is_not_retried() async {
    let calls = CallCounter()
    FakeSSEURLProtocol.handler = { _ in
      calls.increment()
      return .text(status: 503, body: "in-flight-crash", headers: ["Retry-After": "1"])
    }
    let req = InferletRequest(
      inferlet: "chat-apc",
      input: Data(#"{"messages":[{"role":"user","content":"hi"}]}"#.utf8)
    )
    do {
      for try await _ in makeClient().dispatchInferlet(req) {}
      XCTFail("expected the 503 to surface as an error")
    } catch is HTTPEngineError {
      // expected — non-2xx maps to HTTPEngineError, not URLError
    } catch {
      XCTFail("expected HTTPEngineError, got \(type(of: error)): \(error)")
    }
    XCTAssertEqual(calls.value, 1, "a non-2xx response must not be retried")
  }

  /// Only a CONNECT-time connection-lost retries. A `networkConnectionLost`
  /// raised AFTER the 200 response head has been accepted (so `openStream`
  /// has already returned and the consumer is iterating frames) is a
  /// mid-stream drop — re-running a partially consumed stream could
  /// duplicate side effects, so it must surface to the caller, not retry.
  ///
  /// Determinism: the stub emits the 200 head FIRST, which is what resolves
  /// `URLSession.bytes(for:)`; the failure is delivered afterward, so it can
  /// only land mid-iteration — never at connect. `calls.value == 1` is
  /// therefore exact (a retry would re-invoke the handler → 2). Whether the
  /// single buffered frame surfaces before the failure is an incidental
  /// URLSession race, so the frame payload is intentionally not asserted.
  func test_dispatchInferlet_midstream_connection_lost_is_not_retried() async {
    let calls = CallCounter()
    FakeSSEURLProtocol.handler = { _ in
      calls.increment()
      return .sseThenFailure(chunks: ["data: {\"frame\":1}\n\n"],
                             code: .networkConnectionLost)
    }
    let req = InferletRequest(
      inferlet: "chat-apc",
      input: Data(#"{"messages":[{"role":"user","content":"hi"}]}"#.utf8)
    )
    do {
      for try await _ in makeClient().dispatchInferlet(req) {}
      XCTFail("expected the mid-stream connection-lost to surface")
    } catch let error as URLError {
      XCTAssertEqual(error.code, .networkConnectionLost)
    } catch {
      XCTFail("unexpected error type: \(error)")
    }
    XCTAssertEqual(calls.value, 1, "a mid-stream drop must not be retried")
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

  func test_dispatchInferlet_streaming_generation_posts_to_chatCompletions() async throws {
    let captured = RequestCapture()
    FakeSSEURLProtocol.handler = { req in
      captured.set(req)
      return .sse(chunks: ["data: {\"event\":\"tree_start\",\"id\":\"t\",\"model\":\"m\",\"breadth\":1,\"depth\":1,\"beam_width\":1}\n\n", "data: [DONE]\n\n"])
    }
    let req = InferletRequest(
      inferlet: "tree-of-thought",
      input: Data(#"{"model":"m","messages":[{"role":"user","content":"hi"}],"breadth":1,"depth":1,"beam_width":1,"max_tokens_per_node":16}"#.utf8),
      stream: true
    )
    for try await _ in makeClient().dispatchInferlet(req) {}
    let request = try XCTUnwrap(captured.request)
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.url?.path, "/v1/chat/completions")
    let bodyData = try XCTUnwrap(captured.body())
    let top = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
    XCTAssertEqual(top["inferlet"] as? String, "tree-of-thought")
    XCTAssertEqual(top["stream"] as? Bool, true)
    let input = try XCTUnwrap(top["input"] as? [String: Any])
    XCTAssertEqual(input["model"] as? String, "m")
  }

  func test_dispatchInferlet_bestOfN_release_control_posts_to_chatCompletions() async throws {
    let captured = RequestCapture()
    FakeSSEURLProtocol.handler = { req in
      captured.set(req)
      return .json(status: 200, body: #"{"requested":1,"released":1,"absent":0}"#)
    }
    let req = InferletRequest(
      inferlet: "best-of-n",
      input: Data(#"{"release":["bon/r0/1/0"]}"#.utf8),
      stream: false
    )
    var frames: [Data] = []
    for try await frame in makeClient().dispatchInferlet(req) { frames.append(frame) }
    XCTAssertEqual(frames.count, 1)
    XCTAssertEqual(try XCTUnwrap(captured.request).url?.path, "/v1/chat/completions")
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
    var captured: URLRequest?
    FakeSSEURLProtocol.handler = { request in
      captured = request
      return .sse(chunks: ["data: {\"event\":\"model_ready\"}\n\n", "data: [DONE]\n\n"])
    }
    let req = InferletRequest(
      inferlet: "tree-of-thought",
      input: Data(#"{"model":"m","messages":[{"role":"user","content":"hi"}],"breadth":1,"depth":1,"beam_width":1,"max_tokens_per_node":16}"#.utf8)
    )
    for try await _ in makeClient().dispatchInferlet(req) {}
    XCTAssertEqual(captured?.timeoutInterval, HTTPEngineClient.streamingIdleTimeout,
                   "streaming inferlet dispatch must carry the lifted idle timeout, not the 60s default")
    XCTAssertEqual(captured?.url?.path, "/v1/chat/completions",
                   "generative profile dispatch must use the public chat-completions route")
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
    /// Transport-level failure (no HTTP response) — models a stale
    /// keep-alive reuse surfacing as `URLError(code)` from
    /// `URLSession.bytes(for:)`, before any byte arrives.
    case failure(URLError.Code)
    /// Open a 200 SSE stream, emit `chunks`, then fail the task with
    /// `URLError(code)` AFTER streaming has begun — models a mid-stream
    /// connection drop (which must NOT be retried; only connect-time
    /// failures retry).
    case sseThenFailure(chunks: [String], code: URLError.Code)
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

    case .failure(let code):
      client?.urlProtocol(self, didFailWithError: URLError(code))

    case .sseThenFailure(let chunks, let code):
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "text/event-stream"]
      )!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      let client = self.client
      let proto = self
      Task {
        for chunk in chunks {
          if proto.cancelled { break }
          client?.urlProtocol(proto, didLoad: Data(chunk.utf8))
        }
        // Fail the in-flight task AFTER the stream opened and delivered
        // bytes — the consumer is past `openStream`/`bytes(for:)` and
        // iterating frames, so the retry path can no longer fire.
        client?.urlProtocol(proto, didFailWithError: URLError(code))
      }
    }
  }

  override func stopLoading() {
    cancelled = true
  }
}

// MARK: - Call counter helper

/// Thread-safe attempt counter for handlers that must vary their
/// response by attempt number (e.g. fail the first connect, succeed the
/// retry). `URLProtocol.handler` is invoked once per intercepted request.
private final class CallCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  /// Increment and return the new (1-based) count.
  @discardableResult
  func increment() -> Int {
    lock.lock(); defer { lock.unlock() }
    count += 1
    return count
  }

  var value: Int {
    lock.lock(); defer { lock.unlock() }
    return count
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

  var request: URLRequest? {
    lock.lock(); defer { lock.unlock() }
    return _request
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
