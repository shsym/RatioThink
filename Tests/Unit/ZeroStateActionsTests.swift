import XCTest
import SwiftData
@testable import RatioThink

/// Headless coverage for the zero-state affordance wiring: the shared
/// chat-creation path the col-3 "Start Chat" CTA and the chat-list New Chat
/// button both call. GUI navigation is covered in S285_ZeroStateGUITests;
/// this pins the deterministic logic. (The former endpoint port allocator is
/// gone — the local API is the engine's single endpoint, #422.)
@MainActor
final class ZeroStateActionsTests: XCTestCase {
  func test_chatCreation_persists_chat_and_returns_id() throws {
    let container = try RatioThinkModelContainer.makeInMemory()
    let context = ModelContext(container)
    let status = PersistenceStatus()

    let id = ChatCreation.create(
      in: context,
      persistenceStatus: status,
      contextLabel: "test"
    )
    let newID = try XCTUnwrap(id, "create must return the new chat id")

    let fetched = try context.fetch(FetchDescriptor<Chat>())
    XCTAssertEqual(fetched.count, 1, "create must persist exactly one chat")
    XCTAssertEqual(fetched.first?.id, newID)
    XCTAssertNil(status.lastError, "a successful create must not report a persistence error")
  }

  /// #460-AC3: a new chat INHERITS the active profile + concrete model from
  /// the chat the user was already in, so "New Chat" preserves the
  /// profile/model context instead of resetting to the bare default.
  func test_chatCreation_inherits_profile_and_model() throws {
    let container = try RatioThinkModelContainer.makeInMemory()
    let context = ModelContext(container)
    let status = PersistenceStatus()

    let id = try XCTUnwrap(ChatCreation.create(
      in: context,
      persistenceStatus: status,
      contextLabel: "test",
      profileID: "fast-think",
      modelID: "org/Repo/Concrete-Q8.gguf"
    ))

    let chat = try XCTUnwrap(context.fetch(FetchDescriptor<Chat>()).first { $0.id == id })
    XCTAssertEqual(chat.profileID, "fast-think", "new chat must inherit the active profile")
    XCTAssertEqual(chat.modelID, "org/Repo/Concrete-Q8.gguf", "new chat must inherit the concrete model")
  }

  /// The zero-state CTA has no source chat → the creation defaults apply
  /// (bare profile, no pinned model — the chat follows the profile default).
  func test_chatCreation_defaults_when_no_source_chat() throws {
    let container = try RatioThinkModelContainer.makeInMemory()
    let context = ModelContext(container)
    let status = PersistenceStatus()

    let id = try XCTUnwrap(ChatCreation.create(
      in: context,
      persistenceStatus: status,
      contextLabel: "test"
    ))
    let chat = try XCTUnwrap(context.fetch(FetchDescriptor<Chat>()).first { $0.id == id })
    XCTAssertEqual(chat.profileID, "chat")
    XCTAssertNil(chat.modelID, "with no source chat the new chat is unpinned (follows profile default)")
  }

  /// #460: the pinned model survives a relaunch — `Chat.modelID` is a
  /// persisted column, so a chat written with a model reads it back.
  func test_chat_model_pin_round_trips_through_the_store() throws {
    let container = try RatioThinkModelContainer.makeInMemory()
    let context = ModelContext(container)
    let chat = Chat(profileID: "chat", modelID: "org/Repo/Pinned-Q8.gguf")
    context.insert(chat)
    try context.save()

    let reloaded = try XCTUnwrap(context.fetch(FetchDescriptor<Chat>()).first { $0.id == chat.id })
    XCTAssertEqual(reloaded.modelID, "org/Repo/Pinned-Q8.gguf")
  }
}
