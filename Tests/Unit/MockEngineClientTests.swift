import XCTest
@testable import RatioThink

final class MockEngineClientTests: XCTestCase {

  /// Sleep seam that records every requested duration but completes
  /// instantly. Lets us assert that the mock asked for `loadSteps`
  /// load-interval sleeps + `cannedTokens.count` chat-interval sleeps
  /// without spending real time on it.
  private final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var durations: [Duration] = []

    func sleep(_ d: Duration) async throws {
      lock.lock()
      durations.append(d)
      lock.unlock()
    }

    var recorded: [Duration] {
      lock.lock()
      defer { lock.unlock() }
      return durations
    }
  }

  private func makeClient(
    config: MockEngineClient.Config = MockEngineClient.Config(),
    recorder: SleepRecorder = SleepRecorder()
  ) -> (MockEngineClient, SleepRecorder) {
    let client = MockEngineClient(config: config, sleep: { try await recorder.sleep($0) })
    return (client, recorder)
  }

  // MARK: - health / models

  func test_health_returns_configured_value() async throws {
    let canned = EngineHealth(status: .ok, loadedModel: "m1", uptimeSeconds: 42)
    let (client, _) = makeClient(config: MockEngineClient.Config(health: canned))
    let health = try await client.health()
    XCTAssertEqual(health, canned)
  }

  func test_models_returns_configured_listing() async throws {
    let canned = [
      ModelInfo(id: "a", ownedBy: "pie", created: Date(timeIntervalSince1970: 0)),
      ModelInfo(id: "b", ownedBy: "pie", created: Date(timeIntervalSince1970: 1)),
    ]
    let (client, _) = makeClient(config: MockEngineClient.Config(models: canned))
    let listing = try await client.models()
    XCTAssertEqual(listing, canned)
  }

  // MARK: - chatCompletion event ordering

  func test_chatCompletion_emits_loading_prefix_then_deltas_then_finish() async throws {
    let cfg = MockEngineClient.Config(
      loadStepInterval: .microseconds(1),
      chatStepInterval: .microseconds(1),
      loadSteps: 2,
      totalBytes: 1_000,
      simulateChatLoad: true,
      cannedTokens: ["hello", " ", "world"]
    )
    let (client, _) = makeClient(config: cfg)
    let req = ChatRequest(
      model: "m1",
      messages: [ChatMessage(role: .user, content: "hi")]
    )
    var events: [ChatEvent] = []
    for try await event in client.chatCompletion(req) {
      events.append(event)
    }

    // Expect: 2 modelLoading + 1 modelReady + 3 delta + 1 finish = 7.
    XCTAssertEqual(events.count, 7, "got \(events)")

    // Meta prefix:
    guard case .modelLoading = events[0] else {
      return XCTFail("events[0] should be .modelLoading, got \(events[0])")
    }
    guard case .modelLoading = events[1] else {
      return XCTFail("events[1] should be .modelLoading, got \(events[1])")
    }
    XCTAssertEqual(events[2], .modelReady)

    // Deltas: first carries role, rest are role-less.
    XCTAssertEqual(events[3], .delta(role: .assistant, content: "hello"))
    XCTAssertEqual(events[4], .delta(role: nil, content: " "))
    XCTAssertEqual(events[5], .delta(role: nil, content: "world"))

    // Terminal finish frame.
    XCTAssertEqual(events[6], .finish(reason: .stop))
  }

  func test_chatCompletion_skips_load_prefix_when_disabled() async throws {
    let cfg = MockEngineClient.Config(
      chatStepInterval: .microseconds(1),
      simulateChatLoad: false,
      cannedTokens: ["a", "b"]
    )
    let (client, _) = makeClient(config: cfg)
    let req = ChatRequest(model: "m1", messages: [ChatMessage(role: .user, content: "x")])
    var events: [ChatEvent] = []
    for try await event in client.chatCompletion(req) {
      events.append(event)
    }
    XCTAssertEqual(events, [
      .delta(role: .assistant, content: "a"),
      .delta(role: nil, content: "b"),
      .finish(reason: .stop),
    ])
  }

  func test_chatCompletion_consumer_break_stops_stream() async throws {
    // `break`-ing out of the consumer loop deinits the AsyncThrowingStream
    // iterator, which fires the mock's `onTermination` and cancels its
    // producer Task — exercises the "consumer dropped the stream"
    // teardown path without depending on wall-clock cancellation timing.
    let cfg = MockEngineClient.Config(
      chatStepInterval: .microseconds(1),
      simulateChatLoad: false,
      cannedTokens: Array(repeating: "x", count: 50)
    )
    let (client, _) = makeClient(config: cfg)
    var collected: [ChatEvent] = []
    for try await event in client.chatCompletion(
      ChatRequest(model: "m1", messages: [ChatMessage(role: .user, content: "x")])
    ) {
      collected.append(event)
      if collected.count == 2 { break }
    }
    XCTAssertEqual(collected.count, 2)
  }

  func test_chatCompletion_cancelled_sleeper_emits_cancelled_finish() async throws {
    // Inject a sleeper that throws CancellationError on the third call
    // so the mock's `catch is CancellationError` branch runs and
    // synthesizes a `.finish(reason: .cancelled)` terminal frame.
    final class Counter: @unchecked Sendable {
      private let lock = NSLock()
      private var n = 0
      func tickAndShouldCancel(threshold: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        n += 1
        return n >= threshold
      }
    }
    let counter = Counter()
    let cfg = MockEngineClient.Config(
      simulateChatLoad: false,
      cannedTokens: ["a", "b", "c", "d", "e"]
    )
    let client = MockEngineClient(config: cfg, sleep: { _ in
      if counter.tickAndShouldCancel(threshold: 3) {
        throw CancellationError()
      }
    })
    var events: [ChatEvent] = []
    for try await event in client.chatCompletion(
      ChatRequest(model: "m1", messages: [ChatMessage(role: .user, content: "x")])
    ) {
      events.append(event)
    }
    // Two deltas yielded before the third sleep throws, then the
    // catch-branch synthesizes a cancelled finish.
    XCTAssertEqual(events.count, 3)
    XCTAssertEqual(events.last, .finish(reason: .cancelled))
  }

  func test_chatCompletion_respects_configured_intervals() async throws {
    let recorder = SleepRecorder()
    let cfg = MockEngineClient.Config(
      loadStepInterval: .milliseconds(11),
      chatStepInterval: .milliseconds(22),
      loadSteps: 2,
      simulateChatLoad: true,
      cannedTokens: ["a", "b", "c"]
    )
    let (client, _) = makeClient(config: cfg, recorder: recorder)
    for try await _ in client.chatCompletion(
      ChatRequest(model: "m1", messages: [ChatMessage(role: .user, content: "x")])
    ) {}
    let sleeps = recorder.recorded
    XCTAssertEqual(sleeps.count, 2 + 3, "expected 2 load + 3 chat sleeps, got \(sleeps)")
    XCTAssertEqual(sleeps.prefix(2).map { $0 }, [.milliseconds(11), .milliseconds(11)])
    XCTAssertEqual(sleeps.suffix(3).map { $0 },
                   [.milliseconds(22), .milliseconds(22), .milliseconds(22)])
  }

  // MARK: - dispatchInferlet

  func test_dispatchInferlet_echoes_input_twice() async throws {
    let (client, _) = makeClient(config: MockEngineClient.Config(
      chatStepInterval: .microseconds(1)
    ))
    let payload = Data("hello".utf8)
    let req = InferletRequest(inferlet: "echo", input: payload)
    var frames: [Data] = []
    for try await frame in client.dispatchInferlet(req) {
      frames.append(frame)
    }
    XCTAssertEqual(frames, [payload, payload])
  }

  // MARK: - Codable wire shapes (structural)

  /// `ChatRequest` must encode OpenAI-flat: `temperature` / `top_p` /
  /// `max_tokens` at the top level of the JSON body, with NO
  /// `sampling` envelope. Substring matching would not catch a
  /// regression that put the sampling fields back inside a nested
  /// object, so the assertion is structural.
  func test_chatRequest_encodes_openai_flat_with_no_sampling_envelope() throws {
    let req = ChatRequest(
      model: "m1",
      messages: [ChatMessage(role: .user, content: "hi")],
      sampling: ChatSampling(temperature: 0.5, topP: 0.8, maxTokens: 64),
      stream: true
    )
    let data = try JSONEncoder().encode(req)
    let top = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any],
      "ChatRequest must encode as a top-level JSON object"
    )

    XCTAssertNil(top["sampling"], "ChatRequest must not emit a `sampling` envelope")

    XCTAssertEqual(top["model"] as? String, "m1")
    XCTAssertEqual(top["stream"] as? Bool, true)
    XCTAssertEqual(top["temperature"] as? Double, 0.5)
    XCTAssertEqual(top["top_p"] as? Double, 0.8)
    XCTAssertEqual(top["max_tokens"] as? Int, 64)

    let messages = try XCTUnwrap(top["messages"] as? [[String: Any]])
    XCTAssertEqual(messages.count, 1)
    XCTAssertEqual(messages[0]["role"] as? String, "user")
    XCTAssertEqual(messages[0]["content"] as? String, "hi")

    let allowed: Set<String> = [
      "model", "messages", "stream", "temperature", "top_p", "max_tokens",
    ]
    XCTAssertEqual(Set(top.keys), allowed,
                   "unexpected top-level keys: \(Set(top.keys).subtracting(allowed))")
  }

  func test_chatRequest_codable_round_trip_preserves_equality() throws {
    let original = ChatRequest(
      model: "m1",
      messages: [
        ChatMessage(role: .system, content: "sys"),
        ChatMessage(role: .user, content: "u1"),
      ],
      sampling: ChatSampling(temperature: 0.25, topP: 0.95, maxTokens: 128),
      stream: false
    )
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(ChatRequest.self, from: data)
    XCTAssertEqual(decoded, original)
  }

  /// `InferletRequest.input` must land on the wire as an inline JSON
  /// sub-tree (`"input": {...}`), never as a base64 string.
  func test_inferletRequest_encodes_input_as_inline_json() throws {
    let inputJSON = Data(#"{"x":1,"y":[true,"z"]}"#.utf8)
    let req = InferletRequest(inferlet: "echo", input: inputJSON, stream: true)
    let data = try JSONEncoder().encode(req)
    let top = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

    XCTAssertEqual(top["inferlet"] as? String, "echo")
    XCTAssertEqual(top["stream"] as? Bool, true)
    XCTAssertNil(top["messages"], "nil messages must not appear on the wire")

    let input = try XCTUnwrap(
      top["input"] as? [String: Any],
      "`input` must be an inline JSON object, not a base64 string"
    )
    XCTAssertEqual(input["x"] as? Int, 1)
    let y = try XCTUnwrap(input["y"] as? [Any])
    XCTAssertEqual(y[0] as? Bool, true)
    XCTAssertEqual(y[1] as? String, "z")
  }

  func test_inferletRequest_codable_round_trip_preserves_payload() throws {
    let inputJSON = Data(#"{"k":[1,2.5,null,false]}"#.utf8)
    let req = InferletRequest(
      inferlet: "demo",
      input: inputJSON,
      messages: [ChatMessage(role: .user, content: "hi")],
      stream: true
    )
    let data = try JSONEncoder().encode(req)
    let decoded = try JSONDecoder().decode(InferletRequest.self, from: data)

    XCTAssertEqual(decoded.inferlet, "demo")
    XCTAssertEqual(decoded.stream, true)
    XCTAssertEqual(decoded.messages, [ChatMessage(role: .user, content: "hi")])

    // input bytes get re-serialized through JSONValue; compare by
    // re-parsing both sides so whitespace differences don't matter.
    let originalParsed = try JSONSerialization.jsonObject(with: inputJSON) as? [String: Any]
    let decodedParsed  = try JSONSerialization.jsonObject(with: decoded.input) as? [String: Any]
    XCTAssertEqual(originalParsed?["k"] as? [NSNumber],
                   decodedParsed?["k"] as? [NSNumber])
  }

  func test_inferletRequest_invalid_input_json_throws() {
    let req = InferletRequest(inferlet: "x", input: Data("not-json{".utf8))
    XCTAssertThrowsError(try JSONEncoder().encode(req)) { error in
      guard case EncodingError.invalidValue = error else {
        return XCTFail("expected EncodingError.invalidValue, got \(error)")
      }
    }
  }

  func test_engineHealth_decodes_snake_case_payload() throws {
    let json = #"{"status":"ok","model":"qwen3-0.6b","uptime_s":3.5}"#
    let decoded = try JSONDecoder().decode(EngineHealth.self, from: Data(json.utf8))
    XCTAssertEqual(decoded, EngineHealth(
      status: .ok,
      loadedModel: "qwen3-0.6b",
      uptimeSeconds: 3.5
    ))
  }

  func test_engineHealth_encodes_snake_case_payload() throws {
    let health = EngineHealth(status: .ok, loadedModel: "m1", uptimeSeconds: 7.5)
    let data = try JSONEncoder().encode(health)
    let top = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(top["status"] as? String, "ok")
    XCTAssertEqual(top["model"] as? String, "m1")
    XCTAssertEqual(top["uptime_s"] as? Double, 7.5)
    XCTAssertNil(top["loadedModel"], "must not leak Swift-side key onto wire")
    XCTAssertNil(top["uptimeSeconds"])
  }

  func test_modelInfo_decodes_openai_shape() throws {
    let json = #"{"id":"m1","owned_by":"pie","created":1700000000}"#
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    let decoded = try decoder.decode(ModelInfo.self, from: Data(json.utf8))
    XCTAssertEqual(decoded.id, "m1")
    XCTAssertEqual(decoded.ownedBy, "pie")
    XCTAssertEqual(decoded.created, Date(timeIntervalSince1970: 1_700_000_000))
  }
}
