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
///   one terminal `treeComplete` (success) | thrown `ToTStreamError`
///   (the `error` frame) → end.
///
/// `nodeComplete` carries the **flat** node — the client assembles the
/// hierarchy from `parentID`, exactly as the non-streaming server does.

// MARK: - Node

/// Lifecycle of a streamed tree node — byte-identical to the server's
/// `NodeStatus` wire strings. Closed set: a drift would be a wire-format
/// change and should surface as a decode failure, not silently coerce.
public enum ToTNodeStatus: String, Decodable, Equatable, Sendable {
  /// The synthetic conversation-prefix root (never appears on a
  /// `node_complete` frame — generated nodes are `ok`/`error`).
  case root
  /// A successfully generated, scored candidate.
  case ok
  /// Generation — or the fork/refine-flush preceding it — failed.
  case error
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
    case score
    case status
    case error
    case scoreError = "score_error"
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
  /// One fully-resolved node (generated + scored, or errored).
  case nodeComplete(ToTNode)
  /// A level's beam selection: the ids kept as the next frontier. Empty
  /// `kept` ⇒ the level produced no survivor and the search stopped.
  case levelPruned(level: Int, kept: [String])
  /// Terminal success: the best leaf, or nil/nil when no ok leaf survived.
  case treeComplete(selectedNodeID: String?, finalAnswer: String?)
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
  }
}
