import Foundation
import SwiftData

/// Persistent message row inside a `Chat`. Streaming-token writes
/// land on `content` incrementally — see `MessageStreamWriter` for
/// the batched-flush policy (every 250 ms, plus a final flush on
/// `model_ready` / `finish`).
///
/// `role` is stored as the wire-shape raw string (`"user"` /
/// `"assistant"` / `"system"`) so `Message` rows decode straight from
/// any JSON export without needing a custom transformable; the
/// `roleEnum` computed property recovers a `ChatMessage.Role`.
///
/// `meta` is an opaque JSON blob reserved for engine-shaped extras
/// (finish reason, model id, token-usage triple, tool-call frames in
/// v2). Nullable — non-streaming inserts leave it nil.
@available(macOS 14, *)
@Model
public final class Message {
  @Attribute(.unique) public var id: UUID
  /// Back-reference to the owning chat. Optional because SwiftData
  /// represents the inverse of a to-many cascade-delete with a
  /// nullable to-one (the owning side enforces deletion). Setting
  /// this to nil orphans the message; the GUI never does that —
  /// inserts go through `Chat.messages.append`.
  public var chat: Chat?
  /// Raw `ChatMessage.Role.rawValue` (`"user"`, `"assistant"`,
  /// `"system"`). Stored as string so the row decodes straight from
  /// any JSON export without a custom transformer.
  public var role: String
  public var content: String
  /// Model thinking-block text (OpenAI `reasoning_content`; Qwen
  /// `<think>…</think>`), kept OUT of `content` so it never renders in
  /// the visible answer and is never replayed into request history.
  /// Streams in alongside `content` via `MessageStreamWriter` and is
  /// shown in a collapsible "Thinking" section. Empty for turns with no
  /// reasoning and for non-thinking models.
  ///
  /// Non-optional `String` carrying an **inline (declaration-site)
  /// default**. The `= ""` here is what makes the column migratable:
  /// it gives the stored property a schema-level default so SwiftData
  /// lightweight migration can backfill existing rows when an older
  /// on-disk `chats.sqlite` (written before this column existed) is
  /// reopened with the current schema. An init-parameter default alone
  /// is NOT enough — without this inline default, opening a pre-existing
  /// store throws, and `RatioThinkModelContainer.openWithFallback` would
  /// silently drop to an empty in-memory store, making the user's chat
  /// history appear gone (the on-disk data is intact, just unopened).
  public var reasoning: String = ""
  /// Token count populated by the engine on finish; 0 while a
  /// streaming turn is in flight.
  public var tokens: Int
  public var ts: Date
  /// Opaque JSON blob for engine-shape extras (finish reason, usage,
  /// model id, future tool-call frames). Nil for plain
  /// non-streaming inserts.
  public var meta: Data?
  /// Serialized `ToTTree` snapshot for a tree-of-thought turn (#413),
  /// written as the search streams (one snapshot per level + terminal)
  /// and rendered as a collapsible live tree-search section — the
  /// structured analogue of `reasoning`'s "Thinking" section. Nil for
  /// ordinary chat turns.
  ///
  /// Optional (nullable column) so SwiftData lightweight migration adds
  /// it to a pre-existing `chats.sqlite` without a migration plan, and an
  /// older export decodes without it. The `= nil` declaration-site
  /// default mirrors `reasoning`'s migratability fix.
  public var tot: Data? = nil

  public init(
    id: UUID = UUID(),
    chat: Chat? = nil,
    role: String,
    content: String = "",
    reasoning: String = "",
    tokens: Int = 0,
    ts: Date = Date(),
    meta: Data? = nil,
    tot: Data? = nil
  ) {
    self.id = id
    self.chat = chat
    self.role = role
    self.content = content
    self.reasoning = reasoning
    self.tokens = tokens
    self.ts = ts
    self.meta = meta
    self.tot = tot
  }
}

@available(macOS 14, *)
public extension Message {
  /// Engine `finish_reason` decoded from the opaque `meta` blob (the
  /// `finish_reason` key written by `ChatSendController.finishMeta`), or
  /// `nil` while a turn is still streaming and for plain non-streaming
  /// inserts. Centralizes the decode so the renderer (`TurnNotice`) and the
  /// send pipeline (`ChatSendController`) agree on one parse. (#434)
  var finishReason: String? {
    guard let meta,
          let object = try? JSONSerialization.jsonObject(with: meta) as? [String: Any] else {
      return nil
    }
    return object["finish_reason"] as? String
  }

  /// Engine-reported per-response generation throughput decoded from
  /// `meta.generation_performance`. Nil for historical rows, cancelled /
  /// failed rows that deliberately omit metrics, and corrupt/future blobs.
  var generationPerformance: GenerationMetrics? {
    guard let meta else { return nil }
    return try? JSONDecoder().decode(MessageMeta.self, from: meta).generationPerformance
  }

  /// THE transcript ordering — timestamp, with the stable `id` breaking
  /// ties. One definition shared by the renderer (`TranscriptView`), the
  /// request builder (`ChatSendController.makeRequest`), and the retry
  /// truncation (`ChatRetryPlan`), so "everything after this turn" means
  /// the same set of rows the user sees and the engine would replay. (#513)
  static func transcriptPrecedes(_ lhs: Message, _ rhs: Message) -> Bool {
    if lhs.ts == rhs.ts { return lhs.id.uuidString < rhs.id.uuidString }
    return lhs.ts < rhs.ts
  }
}

struct MessageMeta: Codable, Equatable {
  var finishReason: String?
  var generationPerformance: GenerationMetrics?

  init(finishReason: String? = nil, generationPerformance: GenerationMetrics? = nil) {
    self.finishReason = finishReason
    self.generationPerformance = generationPerformance
  }

  private enum CodingKeys: String, CodingKey {
    case finishReason = "finish_reason"
    case generationPerformance = "generation_performance"
  }
}
