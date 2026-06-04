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

  public init(
    id: UUID = UUID(),
    chat: Chat? = nil,
    role: String,
    content: String = "",
    reasoning: String = "",
    tokens: Int = 0,
    ts: Date = Date(),
    meta: Data? = nil
  ) {
    self.id = id
    self.chat = chat
    self.role = role
    self.content = content
    self.reasoning = reasoning
    self.tokens = tokens
    self.ts = ts
    self.meta = meta
  }
}
