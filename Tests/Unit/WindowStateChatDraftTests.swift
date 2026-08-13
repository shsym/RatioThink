import XCTest
@testable import RatioThink

@MainActor
final class WindowStateChatDraftTests: XCTestCase {
  func test_beginChatDraft_routesWithoutSelectingPersistedItem() {
    let state = WindowState()
    let previousID = UUID()
    state.selectedSection = .search
    state.selectedItemID = previousID

    state.beginChatDraft(profileID: "json-think", modelID: "model.gguf")

    XCTAssertEqual(state.selectedSection, .chats)
    XCTAssertNil(state.selectedItemID)
    XCTAssertEqual(state.pendingChatDraft?.profileID, "json-think")
    XCTAssertEqual(state.pendingChatDraft?.modelID, "model.gguf")
  }

  func test_abandonChatDraft_dropsTransientChat() {
    let state = WindowState()
    state.beginChatDraft(profileID: "chat")

    state.abandonChatDraft()

    XCTAssertNil(state.pendingChatDraft)
    XCTAssertNil(state.selectedItemID)
  }

  func test_commitChatDraft_selectsOnlyMatchingDraft() {
    let state = WindowState()
    state.beginChatDraft(profileID: "chat")
    let draftID = try! XCTUnwrap(state.pendingChatDraft?.id)

    state.commitChatDraft(UUID())
    XCTAssertNotNil(state.pendingChatDraft)
    XCTAssertNil(state.selectedItemID)

    state.commitChatDraft(draftID)
    XCTAssertNil(state.pendingChatDraft)
    XCTAssertEqual(state.selectedItemID, draftID)
    XCTAssertEqual(state.selectedSection, .chats)
  }
}
