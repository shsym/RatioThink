import Foundation
import SwiftData

/// Factory + accessors for the app's single SwiftData store.
///
/// On-disk location: `PieDirs.chatsSQLite()` (i.e. `~/Library/Application
/// Support/RatioThink/chats.sqlite`). The schema is `Chat` + `Message`;
/// SwiftData's lightweight migration handles additive changes (new
/// optional fields, renames via `@Attribute(originalName:)`). For
/// breaking changes the manual JSON export tool in
/// `RatioThinkModelContainer.exportJSON(from:)` dumps every chat + message
/// row to a portable shape callers can re-import on the new schema.
@available(macOS 14, *)
public enum RatioThinkModelContainer {
  /// Schema declaration shared by the on-disk and in-memory factories
  /// so both compile against the same set of models (and drift
  /// between them would fail tests, not silently corrupt the store).
  public static let schema = Schema([Chat.self, Message.self])

  /// Builds the on-disk container at `PieDirs.chatsSQLite()`. Throws
  /// rather than `try!`-ing so `RatioThinkApp.init` (which currently sets up
  /// observable scaffolding) can surface a real error to the user
  /// instead of crashing — the GUI offers "Reveal in Finder" on the
  /// existing-ancestor of the failed path (`PieDirsError` already
  /// surfaces that shape elsewhere).
  public static func makeShared() throws -> ModelContainer {
    let url = try PieDirs.chatsSQLite()
    let config = ModelConfiguration(
      "chats",
      schema: schema,
      url: url,
      cloudKitDatabase: .none
    )
    return try ModelContainer(for: schema, configurations: [config])
  }

  /// In-memory container for tests + SwiftUI previews. Backed by
  /// `/dev/null` semantics (`isStoredInMemoryOnly: true`) so no file
  /// is written and parallel tests cannot alias each other through
  /// the shared `chats.sqlite` path.
  public static func makeInMemory() throws -> ModelContainer {
    let config = ModelConfiguration(
      "chats-memory",
      schema: schema,
      isStoredInMemoryOnly: true
    )
    return try ModelContainer(for: schema, configurations: [config])
  }

  /// Opens the on-disk store via the supplied factory; on failure
  /// records the reason on `status`, then falls back to the in-memory
  /// container. The factory pair is parameterized so tests can
  /// inject a failing `makeShared` and verify the fallback path
  /// ( F3 / F18). `fatalError` only on the unrecoverable case
  /// where even the in-memory factory throws — the SwiftData
  /// runtime is unusable on this OS at that point.
  @MainActor
  public static func openWithFallback(
    status: PersistenceStatus,
    makeShared sharedFactory: () throws -> ModelContainer = { try makeShared() },
    makeInMemory inMemoryFactory: () throws -> ModelContainer = { try makeInMemory() }
  ) -> ModelContainer {
    do {
      return try sharedFactory()
    } catch {
      let reason = PersistenceStatus.formatError(error)
      status.markInMemoryFallback(reason: reason)
      status.report(error, context: "RatioThinkModelContainer.openWithFallback")
      do {
        return try inMemoryFactory()
      } catch {
        fatalError("SwiftData in-memory ModelContainer also failed: \(PersistenceStatus.formatError(error))")
      }
    }
  }

  // MARK: - JSON export (manual breaking-migration tool)

  /// Snapshot of every chat + its messages in a portable JSON shape.
  /// The schema lives entirely here (no SwiftData types) so a future
  /// breaking migration can read this file on the new schema without
  /// any cross-version Codable contract. Field names mirror the
  /// `@Model` columns 1:1 so a hand-written importer is trivial.
  public struct ExportedChat: Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var profileID: String
    /// #460: the chat's pinned selected model (`Chat.modelID`). Optional +
    /// omitted-when-nil so older exports (and chats that follow the profile
    /// default) decode without it.
    public var modelID: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var pinned: Bool
    public var messages: [ExportedMessage]

    public init(
      id: UUID,
      title: String,
      profileID: String,
      modelID: String? = nil,
      createdAt: Date,
      updatedAt: Date,
      pinned: Bool,
      messages: [ExportedMessage]
    ) {
      self.id = id
      self.title = title
      self.profileID = profileID
      self.modelID = modelID
      self.createdAt = createdAt
      self.updatedAt = updatedAt
      self.pinned = pinned
      self.messages = messages
    }
  }

  public struct ExportedMessage: Codable, Equatable, Sendable {
    public var id: UUID
    public var role: String
    public var content: String
    /// Model thinking-block text, kept as a SEPARATE field from
    /// `content` so an exported answer never silently carries the
    /// reasoning. Optional + omitted-when-nil so older exports
    /// (and turns with no reasoning) decode without it.
    public var reasoning: String?
    public var tokens: Int
    public var ts: Date
    public var meta: Data?
    /// Serialized `ToTTree` snapshot for a tree-of-thought turn (#413).
    /// Optional + omitted-when-nil so older exports and ordinary chat
    /// turns decode without it.
    public var tot: Data?

    public init(
      id: UUID,
      role: String,
      content: String,
      reasoning: String? = nil,
      tokens: Int,
      ts: Date,
      meta: Data?,
      tot: Data? = nil
    ) {
      self.id = id
      self.role = role
      self.content = content
      self.reasoning = reasoning
      self.tokens = tokens
      self.ts = ts
      self.meta = meta
      self.tot = tot
    }
  }

  /// Pulls every `Chat` (sorted by `createdAt`) and serializes to a
  /// stable JSON shape suitable for off-line re-import on a breaking
  /// schema. Pretty-printed + ISO-8601 dates so the file is also
  /// human-inspectable.
  ///
  /// `@MainActor` because `ModelContext.fetch` is main-actor
  /// isolated by default; callers run this from a menu action.
  @MainActor
  public static func exportJSON(from context: ModelContext) throws -> Data {
    let descriptor = FetchDescriptor<Chat>(
      sortBy: [SortDescriptor(\.createdAt, order: .forward)]
    )
    let chats = try context.fetch(descriptor)
    let exported = chats.map { chat in
      ExportedChat(
        id: chat.id,
        title: chat.title,
        profileID: chat.profileID,
        modelID: chat.modelID,
        createdAt: chat.createdAt,
        updatedAt: chat.updatedAt,
        pinned: chat.pinned,
        messages: chat.messages
          .sorted { $0.ts < $1.ts }
          .map { ExportedMessage(
            id: $0.id,
            role: $0.role,
            content: $0.content,
            reasoning: $0.reasoning.isEmpty ? nil : $0.reasoning,
            tokens: $0.tokens,
            ts: $0.ts,
            meta: $0.meta,
            tot: $0.tot
          ) }
      )
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(exported)
  }
}
