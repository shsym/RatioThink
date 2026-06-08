import Foundation
import SwiftData

/// Persistent chat row. Owns an ordered set of `Message` rows via a
/// cascade-delete relationship — removing a `Chat` removes its
/// messages atomically. Identity is a stable `UUID` (not SwiftData's
/// opaque `persistentModelID`) so the GUI can round-trip a chat
/// selection through `WindowState.selectedItemID: UUID?` without
/// reaching for a `PersistentIdentifier` opaque box.
///
/// `updatedAt` is the source of truth the sidebar sorts on — bumped on
/// new messages and on title edits.
@available(macOS 14, *)
@Model
public final class Chat {
  /// Stable UUID. `@Attribute(.unique)` so a duplicate-id insert
  /// throws at save time rather than silently coexisting alongside
  /// an existing row.
  @Attribute(.unique) public var id: UUID
  public var title: String
  /// `Profile.id` (e.g. `"chat"`). Free-form string — SwiftData
  /// cannot enforce referential integrity against the on-disk TOML
  /// profile store, and the profile catalog rebuilds on the fly
  /// anyway, so a stale id just falls back to defaults at chat-open.
  public var profileID: String
  /// #460: the chat's SELECTED model — the single authority for "what
  /// model is this chat using". `nil` means "follow the active profile's
  /// default" (late-bound); a non-nil value is an explicit, preserved
  /// pin. Persisted per-chat so a profile switch / new chat keeps the
  /// concrete model instead of resetting to a profile default, and so
  /// the toolbar's selection survives navigation + relaunch (mirrors how
  /// `profileID` already travels with the chat). Optional + nil-default
  /// so this is an additive, reversible SwiftData lightweight migration —
  /// older stores decode with `modelID == nil`.
  public var modelID: String?
  public var createdAt: Date
  public var updatedAt: Date
  public var pinned: Bool
  /// Cascade-delete relationship. The inverse keyPath
  /// (`\Message.chat`) is what tells SwiftData this is the owning
  /// side; both sides must agree on the relationship or a save
  /// throws with a Core Data faulting error. `[]` default keeps
  /// freshly-inserted chats valid before any message is appended.
  @Relationship(deleteRule: .cascade, inverse: \Message.chat)
  public var messages: [Message] = []

  public init(
    id: UUID = UUID(),
    title: String = "New Chat",
    profileID: String = "chat",
    modelID: String? = nil,
    createdAt: Date = Date(),
    updatedAt: Date? = nil,
    pinned: Bool = false
  ) {
    self.id = id
    self.title = title
    self.profileID = profileID
    self.modelID = modelID
    self.createdAt = createdAt
    self.updatedAt = updatedAt ?? createdAt
    self.pinned = pinned
  }
}
