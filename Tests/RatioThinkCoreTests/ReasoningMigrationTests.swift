import XCTest
import SwiftData
@testable import RatioThinkCore

// Pre-`reasoning` schema: the production `Chat` + `Message` as they
// shipped before the reasoning channel — i.e. `Message` WITHOUT the
// `reasoning` property, everything else identical. Nested in an enum so
// the SwiftData entity names resolve to the simple "Chat"/"Message" (the
// same names the current models use). That name match is what makes the
// reopen an *additive* lightweight migration rather than an entity rename
// — the same convention SwiftData's `VersionedSchema` migrations rely on.
//
// File scope (not nested in the XCTestCase): the `@Model` macro generates
// extensions that cannot reach a type nested under a class's `private`
// member.
enum LegacySchemaV0 {
  @Model final class Chat {
    @Attribute(.unique) var id: UUID
    var title: String
    var profileID: String
    var createdAt: Date
    var updatedAt: Date
    var pinned: Bool
    @Relationship(deleteRule: .cascade, inverse: \Message.chat)
    var messages: [Message] = []

    init(id: UUID, title: String, profileID: String,
         createdAt: Date, updatedAt: Date, pinned: Bool) {
      self.id = id
      self.title = title
      self.profileID = profileID
      self.createdAt = createdAt
      self.updatedAt = updatedAt
      self.pinned = pinned
    }
  }

  @Model final class Message {
    @Attribute(.unique) var id: UUID
    var chat: Chat?
    var role: String
    var content: String
    // NOTE: no `reasoning` — this is the whole point of the fixture.
    var tokens: Int
    var ts: Date
    var meta: Data?

    init(id: UUID, chat: Chat?, role: String, content: String,
         tokens: Int, ts: Date, meta: Data?) {
      self.id = id
      self.chat = chat
      self.role = role
      self.content = content
      self.tokens = tokens
      self.ts = ts
      self.meta = meta
    }
  }
}

/// Real on-disk lightweight-migration guard for the additive
/// `Message.reasoning` column.
///
/// Adding `reasoning` is the app's FIRST additive schema change, so this
/// migration path had never executed. It only works if the stored
/// property carries a declaration-site default (`var reasoning: String =
/// ""`); without it, SwiftData cannot backfill the column on an existing
/// `chats.sqlite`, `ModelContainer` init throws, and
/// `RatioThinkModelContainer.openWithFallback` silently drops to an empty
/// in-memory store — the user's chat history appears gone.
///
/// This test deliberately uses a REAL on-disk store (not `makeInMemory`):
/// it writes a fixture under the pre-`reasoning` schema, then reopens it
/// with the current schema through the production open path and asserts
/// the rows migrate (with `reasoning == ""`) and that the open did NOT
/// fall back to in-memory.
@available(macOS 14, *)
@MainActor
final class ReasoningMigrationTests: XCTestCase {

  func test_addingReasoningColumn_migratesExistingOnDiskStore_withoutFallback() throws {
    let tempHome = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("reasoning-migration-\(UUID().uuidString.prefix(8).lowercased())",
                              isDirectory: true)
    try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempHome) }

    try PieDirs.$homeOverride.withValue(tempHome) {
      // Resolve the SAME on-disk path the production `makeShared` will use.
      let storeURL = try PieDirs.chatsSQLite()

      // 1. Write a fixture store under the pre-`reasoning` schema. Scoped
      //    in a nested function so the legacy `ModelContainer` is fully
      //    released (store closed) before the reopen below.
      func writeLegacyStore() throws {
        let legacySchema = Schema([LegacySchemaV0.Chat.self, LegacySchemaV0.Message.self])
        let legacyConfig = ModelConfiguration(
          "chats", schema: legacySchema, url: storeURL, cloudKitDatabase: .none
        )
        let legacyContainer = try ModelContainer(for: legacySchema, configurations: [legacyConfig])
        let ctx = ModelContext(legacyContainer)
        let chat = LegacySchemaV0.Chat(
          id: UUID(), title: "Legacy", profileID: "chat",
          createdAt: Date(timeIntervalSince1970: 1),
          updatedAt: Date(timeIntervalSince1970: 2),
          pinned: true
        )
        ctx.insert(chat)
        let user = LegacySchemaV0.Message(
          id: UUID(), chat: chat, role: "user", content: "hi",
          tokens: 0, ts: Date(timeIntervalSince1970: 1), meta: nil
        )
        let assistant = LegacySchemaV0.Message(
          id: UUID(), chat: chat, role: "assistant", content: "hello",
          tokens: 3, ts: Date(timeIntervalSince1970: 2), meta: nil
        )
        chat.messages.append(contentsOf: [user, assistant])
        try ctx.save()
      }
      try writeLegacyStore()

      // 2. Reopen through the production path: openWithFallback → makeShared
      //    → ModelContainer(for: currentSchema) at the same URL. This is
      //    where SwiftData runs the lightweight migration.
      let status = PersistenceStatus()
      let container = RatioThinkModelContainer.openWithFallback(status: status)

      // 3. The open must NOT have fallen back to the in-memory store —
      //    that is exactly the data-loss symptom this fix prevents.
      XCTAssertTrue(
        status.storage.isOnDisk,
        "opening a pre-reasoning on-disk store fell back to in-memory — migration failed: \(status.storage)"
      )

      // 4. Existing history survived and the new column was backfilled.
      let ctx = ModelContext(container)
      let chats = try ctx.fetch(FetchDescriptor<Chat>())
      XCTAssertEqual(chats.count, 1, "the existing chat row must survive migration")
      let messages = try ctx.fetch(FetchDescriptor<Message>(sortBy: [SortDescriptor(\.ts)]))
      XCTAssertEqual(messages.count, 2, "both message rows must survive migration")
      XCTAssertEqual(messages.map(\.content), ["hi", "hello"], "message content must be preserved")
      for message in messages {
        XCTAssertEqual(
          message.reasoning, "",
          "lightweight migration must backfill the new reasoning column to \"\""
        )
      }
    }
  }
}
