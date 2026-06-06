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
}
