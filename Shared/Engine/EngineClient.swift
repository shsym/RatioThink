import Foundation

/// Wire types + protocol the GUI talks to. v1 has two implementations:
/// `MockEngineClient` (this phase) drives the UI offline; Phase 6 swaps
/// in `HTTPEngineClient` that hits the real pie engine on loopback. The
/// surface here is intentionally narrower than the underlying HTTP API
/// (no `n`, no `logprobs`, no tool_calls) — we add fields only when a
/// view actually needs them, so the mock stays small and the HTTP client
/// has nothing speculative to serialize.
///
/// Codable scope:
/// - **Request bodies** (`ChatRequest`, `InferletRequest`) and
///   **non-streaming responses** (`EngineHealth`, `ModelInfo`) are
///   `Codable` and target the OpenAI-flat wire shape the engine
///   exposes. Phase 6's `HTTPEngineClient` encodes/decodes these
///   types directly — see the custom `encode(to:)` / `init(from:)`
///   on `ChatRequest` that flattens `ChatSampling` onto the top
///   level, and on `InferletRequest` that embeds `input` as an
///   inline JSON sub-tree rather than a base64 blob.
/// - **Streaming events** (`ChatEvent`) are
///   decoder-output types, NOT direct Codable mirrors of the wire.
///   Their on-the-wire counterparts are OpenAI-style SSE frames
///   (`data: {...}\n\n`) parsed by a separate frame decoder in
///   Phase 6 (`OpenAIStreamDecoder → AsyncThrowingStream<ChatEvent>`).
///   `ChatEvent.finish(reason: .cancelled)` is **client-synthesized**:
///   the engine never emits `"cancelled"` as a `finish_reason`; the
///   client constructs it when the consumer task is cancelled so
///   downstream UI doesn't have to special-case "stream ended with
///   no terminal frame."
///
/// Other conformances:
/// - `Sendable` so `AsyncThrowingStream<Event, Error>` values cross
///   actor boundaries without `@unchecked` escape hatches; SwiftUI
///   views on the main actor consume streams produced off-main.
/// - `Equatable` so tests can assert exact event ordering without
///   hand-rolled comparison helpers.

// MARK: - Health

/// Response shape of GET /healthz (design doc §HTTP API):
/// `{"status":"ok","model":"<id>","uptime_s":…}`. `loadedModel` is
/// optional because the engine starts up with no model resident — the
/// healthz handler reports `"model": null` until the engine boots with a
/// model registered. Modeling that as `String?` keeps
/// the GUI from string-matching `"none"`/`""` sentinels.
public struct EngineHealth: Codable, Equatable, Sendable {
  public enum Status: String, Codable, Sendable {
    case ok
    case degraded
  }

  public let status: Status
  public let loadedModel: String?
  /// Optional because pie-control's `/healthz` in v1 returns the
  /// minimal `{"status":"ok"}` shape — no `uptime_s` field. The GUI
  /// doesn't render uptime today, so we tolerate it being absent
  /// rather than fail the whole health probe.
  public let uptimeSeconds: Double?

  public init(status: Status, loadedModel: String? = nil, uptimeSeconds: Double? = nil) {
    self.status = status
    self.loadedModel = loadedModel
    self.uptimeSeconds = uptimeSeconds
  }

  private enum CodingKeys: String, CodingKey {
    case status
    case loadedModel = "model"
    case uptimeSeconds = "uptime_s"
  }
}

// MARK: - Models

/// One entry of the OpenAI-shaped /v1/models listing. v1 surfaces just
/// the fields the chat UI renders (id + ownedBy + created). `Date` for
/// `created` because OpenAI uses seconds-since-epoch and `Date` already
/// has a Codable bridge — `XPCPayloadConfig` pins ISO8601 only on the
/// XPC wire; HTTP responses use `secondsSince1970` configured on the
/// HTTP client's decoder in Phase 6.
public struct ModelInfo: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public let ownedBy: String
  /// Optional because pie-control's `/v1/models` listing in v1 omits
  /// `created` — the inferlet has no boot-timestamp source it can
  /// authoritatively quote. The chat UI sorts by `id` for now;
  /// `created` returns when pie surfaces a registration timestamp.
  public let created: Date?
  /// The effective per-request `max_tokens` ceiling the launched engine
  /// will accept for this model (#474): chat-apc reports the runtime's
  /// `max-output-tokens` — the memory-aware scheduler `default_token_limit`
  /// (#438) capped by raw KV capacity. The App clamps its profile
  /// `max_tokens` down to this before sending so a memory-squeezed launch
  /// never trips the engine's clean 400. Optional so a pre-#474 engine
  /// (no field) decodes to `nil` = "ceiling unknown, do not clamp".
  public let maxOutputTokens: Int?

  public init(id: String, ownedBy: String, created: Date? = nil, maxOutputTokens: Int? = nil) {
    self.id = id
    self.ownedBy = ownedBy
    self.created = created
    self.maxOutputTokens = maxOutputTokens
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case ownedBy = "owned_by"
    case created
    case maxOutputTokens = "max_output_tokens"
  }
}

// MARK: - Chat request shape

/// One transcript turn. Role is closed-set in v1 (system/user/assistant)
/// — tool/function roles arrive with the agent loop in v2. `content` is
/// a single string because the v1 chat UI is text-only; multimodal turns
/// (image parts, tool-call cards) get a new associated-value enum in v2
/// rather than a fragile any-Codable bag here.
public struct ChatMessage: Codable, Equatable, Sendable {
  public enum Role: String, Codable, Sendable {
    case system
    case user
    case assistant
  }

  public let role: Role
  public let content: String

  public init(role: Role, content: String) {
    self.role = role
    self.content = content
  }
}

/// Sampling parameters passed inline with each chat request. Snake-case
/// JSON to match OpenAI's body shape so Phase 6 can encode this struct
/// directly. The trio (temperature/top_p/max_tokens) is what the v1
/// `𝑇 params` popover edits — anything beyond that lives in
/// `Profile.inferletArgs` and rides under `inferlet_args` on the wire.
public struct ChatSampling: Codable, Equatable, Sendable {
  public let temperature: Double
  public let topP: Double
  public let maxTokens: Int

  // #434: default raised 2048 → 4096 so a reasoning model has room to
  // think AND answer before hitting the cap. The honest truncation notice
  // (`TurnNotice`) covers the residual; the composer's "Max tokens" slider
  // (64…8192) lets a user push higher. Profile/serve-config defaults are a
  // separate concern and stay at their own value.
  public init(temperature: Double = 0.7, topP: Double = 0.9, maxTokens: Int = 4096) {
    self.temperature = temperature
    self.topP = topP
    self.maxTokens = maxTokens
  }

  private enum CodingKeys: String, CodingKey {
    case temperature
    case topP = "top_p"
    case maxTokens = "max_tokens"
  }
}

/// Wire shape of the chat-apc `speculation` extension (#418). Unlike
/// `ChatSampling` (flattened onto the top level), this rides as a nested
/// `"speculation": {…}` object — matching the inferlet's `SpecRequest`
/// schema. Snake-case keys; `nil` knobs are *omitted* so the inferlet
/// applies its own defaults (leader 1 / draft 3). The request omits the
/// whole object when there is no speculation (byte-identical normal
/// decode); `ChatSendController.makeRequest` attaches it only for a
/// profile whose speculation is enabled.
public struct ChatSpeculation: Codable, Equatable, Sendable {
  public let enabled: Bool
  public let leaderLen: Int?
  public let draftLen: Int?
  /// Stable chat/request-thread id used by chat-apc to keep Cacheback
  /// n-gram state local to one conversation.
  public let threadID: String?
  /// Selected profile id. Included in the inferlet sidecar key so a
  /// profile switch forks the learned n-gram table even when the model id
  /// is unchanged.
  public let profileID: String?

  public init(
    enabled: Bool,
    leaderLen: Int? = nil,
    draftLen: Int? = nil,
    threadID: String? = nil,
    profileID: String? = nil
  ) {
    self.enabled = enabled
    self.leaderLen = leaderLen
    self.draftLen = draftLen
    self.threadID = threadID
    self.profileID = profileID
  }

  private enum CodingKeys: String, CodingKey {
    case enabled
    case leaderLen = "leader_len"
    case draftLen = "draft_len"
    case threadID = "thread_id"
    case profileID = "profile_id"
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(enabled, forKey: .enabled)
    try c.encodeIfPresent(leaderLen, forKey: .leaderLen)
    try c.encodeIfPresent(draftLen, forKey: .draftLen)
    try c.encodeIfPresent(threadID, forKey: .threadID)
    try c.encodeIfPresent(profileID, forKey: .profileID)
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.enabled = try c.decode(Bool.self, forKey: .enabled)
    self.leaderLen = try c.decodeIfPresent(Int.self, forKey: .leaderLen)
    self.draftLen = try c.decodeIfPresent(Int.self, forKey: .draftLen)
    self.threadID = try c.decodeIfPresent(String.self, forKey: .threadID)
    self.profileID = try c.decodeIfPresent(String.self, forKey: .profileID)
  }
}

/// #522 cross-request KV prefix-cache directive. Rides as a nested
/// `"cache": {…}` object matching the inferlet's `CacheDirective` schema.
/// Carries the local thread key (the chat id), the expected turn boundary,
/// a compatibility/version marker the App bumps to force misses on schema
/// or template drift, and the reuse policy. The inferlet content-addresses
/// snapshots, so this directive scopes/attributes them per chat and gates
/// reuse — it does not, by itself, make any unsafe reuse possible.
public struct ChatCacheDirective: Codable, Equatable, Sendable {
  /// Schema/template compatibility marker. Bump to invalidate every
  /// snapshot the App previously caused to be saved.
  public static let compatVersion = "1"

  public let key: String
  public let turn: Int
  public let compat: String
  public let policy: String
  /// Optional #524 retention budget. Values must come from #517's
  /// authoritative pie `model_status` counters; nil means "do not ask the
  /// inferlet to evict on this request" rather than estimating.
  public let retention: ChatCacheRetentionDirective?

  public init(key: String,
              turn: Int,
              compat: String = ChatCacheDirective.compatVersion,
              policy: String = "auto",
              retention: ChatCacheRetentionDirective? = nil) {
    self.key = key
    self.turn = turn
    self.compat = compat
    self.policy = policy
    self.retention = retention
  }
}

/// #524 APC retention budget passed through the chat-apc `cache.retention`
/// object. The App only constructs this from runtime/inferlet-backed
/// `KVUsageSnapshot` data; the inferlet treats absent/invalid accounting as
/// a safe no-eviction diagnostic.
public struct ChatCacheRetentionDirective: Codable, Equatable, Sendable {
  public let kvPagesUsed: Int
  public let kvPagesTotal: Int
  public let softPercent: Int
  public let evictPercent: Int
  public let hardPercent: Int

  public init(kvPagesUsed: Int,
              kvPagesTotal: Int,
              softPercent: Int = 70,
              evictPercent: Int = 80,
              hardPercent: Int = 95) {
    self.kvPagesUsed = kvPagesUsed
    self.kvPagesTotal = kvPagesTotal
    self.softPercent = softPercent
    self.evictPercent = evictPercent
    self.hardPercent = hardPercent
  }

  private enum CodingKeys: String, CodingKey {
    case kvPagesUsed = "kv_pages_used"
    case kvPagesTotal = "kv_pages_total"
    case softPercent = "soft_percent"
    case evictPercent = "evict_percent"
    case hardPercent = "hard_percent"
  }
}

/// Wire shape of the OpenAI `response_format` field (#572). Rides as a
/// nested `"response_format": {"type": "json_object"}` object, matching
/// chat-apc's `ResponseFormat` schema. The request omits the whole object
/// when there is no constraint (byte-identical normal decode);
/// `ChatSendController.makeRequest` attaches it only for a profile whose
/// `[constraint]` requests JSON. v1 only encodes `json_object`.
public struct ChatResponseFormat: Codable, Equatable, Sendable {
  public let kind: String

  public init(kind: String = "json_object") {
    self.kind = kind
  }

  private enum CodingKeys: String, CodingKey {
    case kind = "type"
  }

  /// The single supported constrained mode.
  public static let jsonObject = ChatResponseFormat(kind: "json_object")
}

/// Body of POST /v1/chat/completions. `stream` is required on the wire
/// (engine has different code paths for streaming vs non-streaming); we
/// expose it but `EngineClient.chatCompletion` only models the streaming
/// path — a future non-streaming overload can call the same endpoint
/// with `stream: false`.
///
/// `ChatSampling` exists as an ergonomic Swift-side grouping (one
/// struct to pass between toolbar popover ↔ view model ↔ request
/// builder), but the wire shape is OpenAI-flat: `temperature`,
/// `top_p`, `max_tokens` sit at the top level of the JSON body next
/// to `model`/`messages`/`stream`. The custom `encode(to:)` /
/// `init(from:)` below maintain that asymmetry so Phase 6's
/// `HTTPEngineClient` can pass a `ChatRequest` straight to its
/// `JSONEncoder` with no DTO layer.
public struct ChatRequest: Codable, Equatable, Sendable {
  public let model: String
  public let messages: [ChatMessage]
  public let sampling: ChatSampling
  public let stream: Bool
  /// Optional chat-apc speculation extension. `nil` → no `speculation`
  /// key on the wire (normal decode). Nested-encoded (not flattened).
  public let speculation: ChatSpeculation?
  /// #522 prefix-cache directive. `nil` → no `cache` key on the wire
  /// (reuse disabled, byte-identical to pre-#522). Nested-encoded.
  public let cache: ChatCacheDirective?
  /// Optional OpenAI `response_format` (#572). `nil` → no key on the wire
  /// (unconstrained). `.jsonObject` → JSON-grammar-constrained decoding.
  public let responseFormat: ChatResponseFormat?

  public init(model: String,
              messages: [ChatMessage],
              sampling: ChatSampling = ChatSampling(),
              stream: Bool = true,
              speculation: ChatSpeculation? = nil,
              cache: ChatCacheDirective? = nil,
              responseFormat: ChatResponseFormat? = nil) {
    self.model = model
    self.messages = messages
    self.sampling = sampling
    self.stream = stream
    self.speculation = speculation
    self.cache = cache
    self.responseFormat = responseFormat
  }

  /// Flat wire keys for sampling. No `sampling` envelope — OpenAI's
  /// /v1/chat/completions accepts `temperature` / `top_p` /
  /// `max_tokens` at the top level. `speculation` is the one nested
  /// object (chat-apc extension). Any field added here must also
  /// be touched in both `encode(to:)` and `init(from:)`.
  private enum CodingKeys: String, CodingKey {
    case model
    case messages
    case stream
    case temperature
    case topP = "top_p"
    case maxTokens = "max_tokens"
    case speculation
    case cache
    case responseFormat = "response_format"
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(model, forKey: .model)
    try c.encode(messages, forKey: .messages)
    try c.encode(stream, forKey: .stream)
    try c.encode(sampling.temperature, forKey: .temperature)
    try c.encode(sampling.topP, forKey: .topP)
    try c.encode(sampling.maxTokens, forKey: .maxTokens)
    try c.encodeIfPresent(speculation, forKey: .speculation)
    try c.encodeIfPresent(cache, forKey: .cache)
    try c.encodeIfPresent(responseFormat, forKey: .responseFormat)
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.model = try c.decode(String.self, forKey: .model)
    self.messages = try c.decode([ChatMessage].self, forKey: .messages)
    self.stream = try c.decode(Bool.self, forKey: .stream)
    self.sampling = ChatSampling(
      temperature: try c.decode(Double.self, forKey: .temperature),
      topP: try c.decode(Double.self, forKey: .topP),
      maxTokens: try c.decode(Int.self, forKey: .maxTokens)
    )
    self.speculation = try c.decodeIfPresent(ChatSpeculation.self, forKey: .speculation)
    self.cache = try c.decodeIfPresent(ChatCacheDirective.self, forKey: .cache)
    self.responseFormat = try c.decodeIfPresent(ChatResponseFormat.self, forKey: .responseFormat)
  }
}

/// Body of an inferlet dispatch envelope. Generative profile-backed dispatches
/// (Tree of Thought / Best of N) are sent via POST /v1/chat/completions; retained
/// internal/control dispatches (for example Best-of-N snapshot release) still use
/// POST /v1/inferlet. The design doc requires `input` to land on the
/// wire as an **inline JSON sub-tree** (`"input": {...}`), not a
/// base64 string — but the dispatcher can't know inferlet-specific
/// schemas, so we accept opaque `Data` and require it to be valid
/// UTF-8 JSON. `encode(to:)` parses the bytes through `JSONValue`
/// (see below) and emits the parsed tree under the `input` key;
/// `init(from:)` reverses that, re-serializing the sub-tree so
/// callers get back the same `Data` shape they handed in.
///
/// Encoding an `InferletRequest` whose `input` is not valid JSON
/// throws `EncodingError` — fail closed rather than ship a payload
/// the engine will reject. `messages` is the optional chat-sugar
/// surface from the design doc; pass nil for inferlets that have
/// their own input shape entirely.
public struct InferletRequest: Codable, Equatable, Sendable {
  public let inferlet: String
  public let input: Data
  public let messages: [ChatMessage]?
  public let stream: Bool

  public init(inferlet: String,
              input: Data,
              messages: [ChatMessage]? = nil,
              stream: Bool = true) {
    self.inferlet = inferlet
    self.input = input
    self.messages = messages
    self.stream = stream
  }

  private enum CodingKeys: String, CodingKey {
    case inferlet
    case input
    case messages
    case stream
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(inferlet, forKey: .inferlet)
    try c.encode(stream, forKey: .stream)
    if let messages {
      try c.encode(messages, forKey: .messages)
    }
    let parsed: JSONValue
    do {
      parsed = try JSONDecoder().decode(JSONValue.self, from: input)
    } catch {
      throw EncodingError.invalidValue(
        input,
        EncodingError.Context(
          codingPath: encoder.codingPath + [CodingKeys.input],
          debugDescription: "InferletRequest.input must be valid UTF-8 JSON; got \(error)"
        )
      )
    }
    try c.encode(parsed, forKey: .input)
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.inferlet = try c.decode(String.self, forKey: .inferlet)
    self.stream = try c.decode(Bool.self, forKey: .stream)
    self.messages = try c.decodeIfPresent([ChatMessage].self, forKey: .messages)
    let parsed = try c.decode(JSONValue.self, forKey: .input)
    self.input = try JSONEncoder().encode(parsed)
  }
}

/// Lossless intermediate JSON tree for round-tripping arbitrary
/// JSON sub-trees through `Codable`. Used by `InferletRequest` so
/// its `input: Data` field can be parsed once and re-emitted as
/// inline JSON inside a larger encoded body. `internal` because
/// it's an implementation detail — callers work with `Data`.
///
/// `.number` collapses int/double into a single `Double` slot
/// because JSON itself has only one number type; the encoder
/// re-emits integral values as integers (no trailing `.0`) so the
/// wire shape matches what a hand-written client would produce.
/// `.bool` is matched ahead of `.number` so JSON `true`/`false`
/// doesn't decode as the numeric `1`/`0`.
internal enum JSONValue: Codable, Equatable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() { self = .null; return }
    // `Bool` must be tried before `Double` — Foundation's JSONDecoder
    // is strict about types, so `true`/`false` won't match Double,
    // but the order documents intent.
    if let b = try? c.decode(Bool.self)         { self = .bool(b);   return }
    if let d = try? c.decode(Double.self)       { self = .number(d); return }
    if let s = try? c.decode(String.self)       { self = .string(s); return }
    if let a = try? c.decode([JSONValue].self)  { self = .array(a);  return }
    if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
    throw DecodingError.dataCorruptedError(
      in: c,
      debugDescription: "JSONValue could not decode underlying value"
    )
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .null:           try c.encodeNil()
    case .bool(let b):    try c.encode(b)
    case .number(let n):
      // Preserve integer shape on the wire. JSON has one number
      // type, but `{"x":1}` should not round-trip to `{"x":1.0}`.
      if n.truncatingRemainder(dividingBy: 1) == 0,
         abs(n) < Double(Int64.max) {
        try c.encode(Int64(n))
      } else {
        try c.encode(n)
      }
    case .string(let s):  try c.encode(s)
    case .array(let a):   try c.encode(a)
    case .object(let o):  try c.encode(o)
    }
  }
}

// MARK: - Events

/// One SSE frame from POST /v1/chat/completions. Maps 1:1 to the wire
/// schema:
/// - `.modelLoading` / `.modelReady` are the meta-frame prefix (design
///   doc §SSE meta-frame schema). v1 pie binds its model at boot, so
///   `.modelLoading` never arrives in practice; `.modelReady` confirms the
///   engine is serving the model for this turn and is fed to
///   `ModelLoadCenter.reconcileEngineResident` (#469).
/// - `.delta` is OpenAI's `choices[0].delta`. `role` only appears on
///   the first delta of a turn; subsequent deltas carry content alone.
/// - `.reasoningDelta` is OpenAI's `choices[0].delta.reasoning_content`
///   — the model's thinking-block text (Qwen `<think>…</think>`),
///   surfaced on its own channel so it never mixes into the visible
///   answer. The chat-apc inferlet keeps the delimiter tokens off both
///   channels; the GUI renders this in a separate, collapsible section.
/// - `.finish` is a synthetic terminal frame the decoder emits when it
///   sees `finish_reason != nil`. Streams end with exactly one
///   `.finish` followed by completion.
///
/// Speculative-decode metrics carried by the terminal `spec_metrics` SSE
/// frame (chat-apc #418, schema `SpecMetricsReport`). Emitted only when the
/// request opted into the speculation surface, so a normal chat stream
/// never carries one. `enabled` is `false` (with a `fallbackReason`) when
/// drafting was requested but didn't engage (e.g. `non_greedy_sampling`).
///
/// The frame arrives AFTER the terminal `.finish` chunk and before
/// `[DONE]`, so a consumer keyed on `.finish` still sees it before the
/// stream completes.
public struct SpecMetrics: Equatable, Sendable {
  public let enabled: Bool
  public let fallbackReason: String?
  public let generatedTokens: Int
  public let decodeSteps: Int
  public let proposedDraftTokens: Int
  public let acceptedDraftTokens: Int
  public let rejectedDraftTokens: Int
  public let avgTokensPerStep: Double
  public let decodeTokensPerSec: Double
  public let leaderLen: Int
  public let draftLen: Int

  public init(
    enabled: Bool,
    fallbackReason: String? = nil,
    generatedTokens: Int,
    decodeSteps: Int,
    proposedDraftTokens: Int,
    acceptedDraftTokens: Int,
    rejectedDraftTokens: Int,
    avgTokensPerStep: Double,
    decodeTokensPerSec: Double,
    leaderLen: Int,
    draftLen: Int
  ) {
    self.enabled = enabled
    self.fallbackReason = fallbackReason
    self.generatedTokens = generatedTokens
    self.decodeSteps = decodeSteps
    self.proposedDraftTokens = proposedDraftTokens
    self.acceptedDraftTokens = acceptedDraftTokens
    self.rejectedDraftTokens = rejectedDraftTokens
    self.avgTokensPerStep = avgTokensPerStep
    self.decodeTokensPerSec = decodeTokensPerSec
    self.leaderLen = leaderLen
    self.draftLen = draftLen
  }

  /// Fraction of proposed draft tokens the verifier accepted (`0…1`), or
  /// `nil` when nothing was proposed — drafting requested but inactive, so
  /// there's no ratio to report (avoids a `0/0` that reads as "0% accept").
  public var acceptRatio: Double? {
    proposedDraftTokens > 0
      ? Double(acceptedDraftTokens) / Double(proposedDraftTokens)
      : nil
  }
}

/// `FinishReason` is closed for v1; unknown reasons coming over the
/// wire decode into `.other(String)` so a future engine extension
/// doesn't crash the GUI.
public enum ChatEvent: Equatable, Sendable {
  case modelLoading(loadedBytes: UInt64, totalBytes: UInt64, etaSeconds: Double?)
  case modelReady
  case delta(role: ChatMessage.Role?, content: String)
  case reasoningDelta(String)
  case generationMetrics(GenerationMetrics)
  /// Terminal speculative-decode metrics. See `SpecMetrics`.
  case specMetrics(SpecMetrics)
  case finish(reason: FinishReason)
  /// Engine-true context-token accounting (#711). `used` is the
  /// conversation's occupancy after this turn (committed + working +
  /// buffered tokens, == prompt + completion); `window` is the effective
  /// KV-budget context window in tokens (`budget_pages × tokens_per_page`),
  /// `nil` when the engine could not report a budget. Emitted once per
  /// turn, just before the stream completes, off the OpenAI content path
  /// (a distinct `event:"usage"` meta-frame), so it never perturbs the
  /// `.delta` / `.finish` contract.
  case usage(used: Int, window: Int?)

  public enum FinishReason: Equatable, Sendable {
    case stop
    case length
    case cancelled
    case other(String)
  }
}

public struct GenerationMetrics: Codable, Equatable, Sendable {
  public let outputTokens: Int
  public let elapsedSeconds: Double
  public let tokensPerSecond: Double

  public init(outputTokens: Int, elapsedSeconds: Double, tokensPerSecond: Double) {
    self.outputTokens = outputTokens
    self.elapsedSeconds = elapsedSeconds
    self.tokensPerSecond = tokensPerSecond
  }

  private enum CodingKeys: String, CodingKey {
    case outputTokens = "output_tokens"
    case elapsedSeconds = "elapsed_s"
    case tokensPerSecond = "tokens_per_sec"
  }
}

/// Snapshot of how full a conversation's context is (#711) — the value
/// behind the top-bar meter and the memory-screen estimate. `usedTokens`
/// is the engine-true occupancy after the latest turn; `windowTokens` is
/// the effective KV-budget context window (`nil` when the engine could
/// not report a budget — e.g. the context isn't resident yet).
///
/// `Codable` so it can ride on a `ContextUsageRecord` (the tracker's
/// per-request occupancy record).
public struct ContextUsage: Codable, Equatable, Sendable {
  public var usedTokens: Int
  public var windowTokens: Int?

  public init(usedTokens: Int, windowTokens: Int?) {
    self.usedTokens = usedTokens
    self.windowTokens = windowTokens
  }

  /// 0…1 fill for the progress bar, or `nil` when the window is unknown
  /// or non-positive so the caller renders an indeterminate state rather
  /// than dividing by zero.
  public var fraction: Double? {
    guard let window = windowTokens, window > 0 else { return nil }
    return min(1, max(0, Double(usedTokens) / Double(window)))
  }
}

// MARK: - Protocol

/// What the GUI talks to. Implementations:
/// - `MockEngineClient` (Phase 3): canned data, configurable delays.
/// - `HTTPEngineClient` (Phase 6): hits the pie engine over loopback
///   HTTP. Same surface, real bytes.
///
/// Streaming methods return `AsyncThrowingStream` rather than
/// `AsyncStream` so transport errors (HTTP failure, JSON parse error,
/// engine `error` frame) reach the consumer through the same channel
/// as data — there is no second error callback to forget about.
/// Cancellation: consumers cancel by dropping the iterator or calling
/// `task.cancel()`; the stream's `onTermination` (set by the impl) is
/// where the network/timer teardown happens.
///
/// `Sendable` so the protocol existential can cross actor boundaries —
/// the chat view runs on `@MainActor` but spawns detached tasks to
/// consume streams without blocking the UI.
public protocol EngineClient: Sendable {
  func health() async throws -> EngineHealth
  func models() async throws -> [ModelInfo]
  func chatCompletion(_ req: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error>
  func dispatchInferlet(_ req: InferletRequest) -> AsyncThrowingStream<Data, Error>
}
