import Foundation

/// Decoder-output types for the tree-of-thought **streaming** wire format
/// (#413), plus the adapter that lifts the raw SSE `data:` frames
/// `EngineClient.dispatchInferlet` yields into typed events.
///
/// Mirrors the chat streaming split in `EngineClient.swift`: these are
/// NOT direct Codable mirrors of a request body — they are the parsed
/// output of the server's SSE frames (`Inferlets/chat-apc/src/tot/stream.rs`),
/// each `data: {json}\n\n` with a top-level `event` discriminator. The
/// terminal `error` frame surfaces as a thrown `ToTStreamError.stream`
/// (the same shape chat uses for its `{event:"error"}` meta-frame), so a
/// consumer handles success and failure through the one async channel.
///
/// A `tree-of-thought` stream is exactly:
///
///   `treeStart` → (`nodeComplete`* then `levelPruned`) per level →
///   one terminal `treeComplete` (an ok leaf was selected) | thrown
///   `ToTStreamError` (the `error` frame — a total failure, no ok leaf;
///   F1) → end.
///
/// A `treeComplete` whose `selectedNodeID` is nil is ALSO a total failure
/// (the server emits the `error` frame for it now, but the consumer treats
/// a null selection as failure defensively — `ChatSendController`).
///
/// `nodeComplete` carries the **flat** node — the client assembles the
/// hierarchy from `parentID`, exactly as the non-streaming server does.

// MARK: - Node

/// Lifecycle of a streamed tree node — byte-identical to the server's
/// `NodeStatus` wire strings. Closed set: a drift would be a wire-format
/// change and should surface as a decode failure, not silently coerce.
/// `Codable` (not just `Decodable`) so it round-trips through the
/// persisted `ToTTree` snapshot (`Message.tot`).
public enum ToTNodeStatus: String, Codable, Equatable, Sendable {
  /// The synthetic conversation-prefix root (never appears on a
  /// `node_complete` frame — generated nodes are `ok`/`error`/`incomplete`).
  case root
  /// A successfully generated, scored candidate (a non-empty answer).
  case ok
  /// Generation — or the fork/refine-flush preceding it — failed.
  case error
  /// The node reasoned but produced no usable answer — it ran out of
  /// reasoning budget mid-`<think>`, or closed the block with nothing after
  /// it (#434). Its `reasoning` is preserved; like `error` it is kept out of
  /// the beam and never selected.
  case incomplete
}

/// One node as it arrives on a `node_complete` frame. Flat: no
/// `children` (the wire deliberately omits them; the tree is assembled
/// client-side from `parentID`). `score` is the 1–10 value rating or nil;
/// `error`/`scoreError` carry the per-node generation / scoring-infra
/// diagnostics when present.
public struct ToTNode: Decodable, Equatable, Sendable, Identifiable {
  public let id: String
  public let parentID: String?
  public let depth: Int
  public let branchIndex: Int?
  public let content: String
  /// The demuxed `<think>` reasoning trace (#413/#437). Omitted from the
  /// wire when empty (non-reasoning model / `thinking:false`), so decode
  /// defaults it to `""`.
  public let reasoning: String
  public let score: Int?
  public let status: ToTNodeStatus
  public let error: String?
  public let scoreError: String?

  public init(
    id: String,
    parentID: String?,
    depth: Int,
    branchIndex: Int?,
    content: String,
    reasoning: String = "",
    score: Int?,
    status: ToTNodeStatus,
    error: String? = nil,
    scoreError: String? = nil
  ) {
    self.id = id
    self.parentID = parentID
    self.depth = depth
    self.branchIndex = branchIndex
    self.content = content
    self.reasoning = reasoning
    self.score = score
    self.status = status
    self.error = error
    self.scoreError = scoreError
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case parentID = "parent_id"
    case depth
    case branchIndex = "branch_index"
    case content
    case reasoning
    case score
    case status
    case error
    case scoreError = "score_error"
  }

  // `reasoning` is omitted from the wire when empty, so decode it tolerantly
  // (default `""`); the rest mirror the synthesized decode.
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try c.decode(String.self, forKey: .id)
    self.parentID = try c.decodeIfPresent(String.self, forKey: .parentID)
    self.depth = try c.decode(Int.self, forKey: .depth)
    self.branchIndex = try c.decodeIfPresent(Int.self, forKey: .branchIndex)
    self.content = try c.decode(String.self, forKey: .content)
    self.reasoning = try c.decodeIfPresent(String.self, forKey: .reasoning) ?? ""
    self.score = try c.decodeIfPresent(Int.self, forKey: .score)
    self.status = try c.decode(ToTNodeStatus.self, forKey: .status)
    self.error = try c.decodeIfPresent(String.self, forKey: .error)
    self.scoreError = try c.decodeIfPresent(String.self, forKey: .scoreError)
  }
}

// MARK: - Events

/// One decoded tree-of-thought stream frame. The `error` frame is NOT a
/// case here — it throws `ToTStreamError.stream` into the async stream,
/// matching how chat surfaces its `{event:"error"}` meta-frame.
public enum ToTEvent: Equatable, Sendable {
  /// Opens the stream; echoes the search bounds so the UI can render the
  /// expected shape before nodes arrive.
  case treeStart(id: String, model: String, breadth: Int, depth: Int, beamWidth: Int)
  /// A node is about to generate (#413 token stream): its tree position, so
  /// the client can create + place a provisional node and route the node's
  /// `nodeDelta`s to it before `nodeComplete` finalizes it.
  case nodeStart(id: String, parentID: String?, depth: Int, branchIndex: Int?)
  /// A streamed text chunk for a node, tagged by id + channel (reasoning
  /// while inside `<think>`, then the answer). Appended live to the node.
  case nodeDelta(id: String, channel: ToTDeltaChannel, text: String)
  /// One fully-resolved node (generated + scored, or errored) — the per-node
  /// terminal + authoritative final (the non-stream path emits only these).
  case nodeComplete(ToTNode)
  /// A level's beam selection: the ids kept as the next frontier. Empty
  /// `kept` ⇒ the level produced no survivor and the search stopped.
  case levelPruned(level: Int, kept: [String])
  /// Terminal: the selected best leaf. A non-nil `selectedNodeID` is a
  /// real answer; a nil `selectedNodeID` (and `finalAnswer`) is a TOTAL
  /// failure, not an empty success — the server emits the `error` frame
  /// for it now, and the consumer treats a null selection as failure (F1).
  case treeComplete(selectedNodeID: String?, finalAnswer: String?)
  /// A streamed chunk of the final synthesized answer (#523 Part A). After
  /// the search picks the best leaf, ONE synthesis generation produces the
  /// final answer; its text streams as `finalDelta` chunks before
  /// `treeComplete` (whose `finalAnswer` is the authoritative full text).
  case finalDelta(text: String)
}

/// Which channel a streamed `nodeDelta` chunk fills (#413).
public enum ToTDeltaChannel: String, Equatable, Sendable {
  case reasoning
  case answer
}

/// Failures specific to the tree-of-thought stream.
public enum ToTStreamError: Error, Equatable, Sendable {
  /// The server emitted a terminal `{event:"error",code,message}` frame.
  /// Carries the engine's diagnostic so the UI renders it rather than a
  /// generic transport failure (parity with `HTTPEngineError.stream`).
  case stream(code: String, message: String)
  /// A frame's JSON could not be decoded into a known shape. `payload`
  /// is the raw frame for diagnostics.
  case malformedFrame(payload: String)
}

extension ToTStreamError: LocalizedError {
  /// Surface the engine's own message for a terminal `error` frame so the
  /// failed-turn bubble reads as the engine's diagnostic, not the enum's
  /// debug form (`ChatSendController` renders this via `formatError`).
  public var errorDescription: String? {
    switch self {
    case let .stream(code, message):
      return message.isEmpty ? "Engine stream error (\(code))" : message
    case let .malformedFrame(payload):
      return "Malformed tree-of-thought frame: \(payload)"
    }
  }
}

// MARK: - Decoding

/// Decode one SSE `data:` payload into a [`ToTEvent`].
///
/// - Returns `nil` for an unrecognized `event` value — a forward-compat
///   frame a newer engine added must not kill the stream (mirrors the
///   "tolerate unknown meta-events" branches in `HTTPEngineClient`).
/// - Throws `ToTStreamError.stream` for the terminal `error` frame.
/// - Throws `ToTStreamError.malformedFrame` when the bytes are not a
///   decodable frame of the declared shape.
public func decodeToTFrame(_ data: Data) throws -> ToTEvent? {
  let raw: RawToTFrame
  do {
    raw = try JSONDecoder().decode(RawToTFrame.self, from: data)
  } catch {
    throw ToTStreamError.malformedFrame(payload: String(decoding: data, as: UTF8.self))
  }

  switch raw.event {
  case "tree_start":
    guard let id = raw.id, let model = raw.model,
          let breadth = raw.breadth, let depth = raw.depth,
          let beamWidth = raw.beamWidth else {
      throw ToTStreamError.malformedFrame(payload: String(decoding: data, as: UTF8.self))
    }
    return .treeStart(id: id, model: model, breadth: breadth, depth: depth, beamWidth: beamWidth)
  case "node_start":
    guard let id = raw.id, let depth = raw.depth else {
      throw ToTStreamError.malformedFrame(payload: String(decoding: data, as: UTF8.self))
    }
    return .nodeStart(id: id, parentID: raw.parentID, depth: depth, branchIndex: raw.branchIndex)
  case "node_delta":
    guard let id = raw.id, let kind = raw.kind, let text = raw.text else {
      throw ToTStreamError.malformedFrame(payload: String(decoding: data, as: UTF8.self))
    }
    // An unknown channel from a newer engine is dropped (forward-compat),
    // not fatal — mirrors the unknown-event default below.
    guard let channel = ToTDeltaChannel(rawValue: kind) else { return nil }
    return .nodeDelta(id: id, channel: channel, text: text)
  case "node_complete":
    guard let node = raw.node else {
      throw ToTStreamError.malformedFrame(payload: String(decoding: data, as: UTF8.self))
    }
    return .nodeComplete(node)
  case "level_pruned":
    guard let level = raw.level, let kept = raw.kept else {
      throw ToTStreamError.malformedFrame(payload: String(decoding: data, as: UTF8.self))
    }
    return .levelPruned(level: level, kept: kept)
  case "final_delta":
    // #523 Part A: a streamed chunk of the synthesized final answer.
    guard let text = raw.text else {
      throw ToTStreamError.malformedFrame(payload: String(decoding: data, as: UTF8.self))
    }
    return .finalDelta(text: text)
  case "tree_complete":
    // selected_node_id / final_answer are legitimately null; their
    // absence from the optionals is indistinguishable from explicit
    // null, which is the honest "no ok leaf" outcome either way.
    return .treeComplete(selectedNodeID: raw.selectedNodeID, finalAnswer: raw.finalAnswer)
  case "error":
    throw ToTStreamError.stream(code: raw.code ?? "unknown_error", message: raw.message ?? "")
  default:
    return nil
  }
}

/// Lift the raw `data:` frame stream from `dispatchInferlet` into typed
/// `ToTEvent`s. Unknown frames are dropped; the terminal `error` frame is
/// thrown. Cancelling the consumer cancels the underlying frame stream.
public func toTEventStream(
  from frames: AsyncThrowingStream<Data, Error>
) -> AsyncThrowingStream<ToTEvent, Error> {
  AsyncThrowingStream { continuation in
    let task = Task {
      do {
        for try await frame in frames {
          try Task.checkCancellation()
          if let event = try decodeToTFrame(frame) {
            continuation.yield(event)
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

/// Internal flat decode of any tree-of-thought frame. Every event-specific
/// field is optional; `decodeToTFrame` validates presence per `event`.
struct RawToTFrame: Decodable {
  let event: String
  let id: String?
  let model: String?
  let breadth: Int?
  let depth: Int?
  let beamWidth: Int?
  let node: ToTNode?
  let level: Int?
  let kept: [String]?
  let selectedNodeID: String?
  let finalAnswer: String?
  let code: String?
  let message: String?
  // node_start position + node_delta payload (#413 token stream).
  let parentID: String?
  let branchIndex: Int?
  let kind: String?
  let text: String?

  private enum CodingKeys: String, CodingKey {
    case event
    case id
    case model
    case breadth
    case depth
    case beamWidth = "beam_width"
    case node
    case level
    case kept
    case selectedNodeID = "selected_node_id"
    case finalAnswer = "final_answer"
    case code
    case message
    case parentID = "parent_id"
    case branchIndex = "branch_index"
    case kind
    case text
  }
}
