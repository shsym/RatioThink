import XCTest
import SwiftData
@testable import RatioThinkCore

/// #624 Issue 1 regression guard: a fork of a non-default-profile chat (one
/// carrying speculation, like a Repeat Boost profile) must re-run against THAT
/// profile's speculation, not the default "chat" profile.
///
/// `ChatScaffoldView.sendAssistantTurn` resolves speculation from
/// `chat.profileID` (the persisted, authoritative profile) precisely so the
/// fork's auto-resend `.task` — which can race ahead of the `.onAppear` that
/// seeds the transient toolbar mirror — cannot silently fall back to the
/// default. This test models that resolution end-to-end through
/// `ChatSendController`, asserting the wire request carries the forked
/// profile's speculation.
@available(macOS 14, *)
@MainActor
final class ChatForkResendProfileTests: XCTestCase {
  /// A profile dir with a plain "chat" profile (no speculation) and a
  /// "turbo-spec" profile carrying an enabled `[speculation]` section.
  private func withProfileStore(_ body: (ProfileStore) async throws -> Void) async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("pie-fork-spec-\(UUID().uuidString)", isDirectory: true)
    let dir = root.appendingPathComponent("profiles", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try """
    id = "chat"
    name = "Chat"
    model = "model-A.gguf"
    inferlet = "chat-apc"
    """.write(to: dir.appendingPathComponent("chat.toml"), atomically: true, encoding: .utf8)

    // A non-default profile carrying speculation. Deliberately NOT the
    // "fast-think" slug — `ProfileStore.migrateFastThinkToRepeatBoost` (#628)
    // renames that id on load, which would make `speculation(forProfileID:)`
    // miss it. Any neutral custom id exercises the same fork→profile path.
    try """
    id = "turbo-spec"
    name = "Turbo"
    model = "model-A.gguf"
    inferlet = "chat-apc"

    [speculation]
    enabled = true
    leader_len = 2
    draft_len = 5
    """.write(to: dir.appendingPathComponent("turbo-spec.toml"), atomically: true, encoding: .utf8)

    let store = ProfileStore(directory: dir)
    try store.start()
    defer { store.stop() }
    try await body(store)
  }

  func test_fork_of_fast_think_chat_resends_with_that_profiles_speculation() async throws {
    try await withProfileStore { store in
      // Sanity: the default profile the race would have used carries NO
      // speculation, so losing the forked profile is observable.
      XCTAssertNil(store.speculation(forProfileID: "chat"),
                   "default 'chat' profile must have no speculation for this test to be meaningful")

      let container = try RatioThinkModelContainer.makeInMemory()
      let context = ModelContext(container)
      let chat = Chat(title: "Original", profileID: "turbo-spec")
      context.insert(chat)
      let userTurn = Message(role: "user", content: "hi",
                             ts: Date(timeIntervalSinceReferenceDate: 1))
      context.insert(userTurn)
      chat.messages.append(userTurn)
      try context.save()

      let newID = try XCTUnwrap(ChatFork.fork(
        chat: chat, at: userTurn, newContent: "hi-edited",
        in: context, persistenceStatus: PersistenceStatus(), contextLabel: "test"
      ))
      let forked = try XCTUnwrap(try context.fetch(
        FetchDescriptor<Chat>(predicate: #Predicate { $0.id == newID })
      ).first)
      // The fork must carry the source's non-default profile.
      XCTAssertEqual(forked.profileID, "turbo-spec")

      // Mirror sendAssistantTurn's resolution: speculation from chat.profileID.
      let spec = store.speculation(forProfileID: forked.profileID)
      let engine = CapturingChatEngine()
      let controller = ChatSendController()
      controller.send(
        chat: forked,
        context: context,
        engine: engine,
        modelLoadCenter: ModelLoadCenter(),
        persistenceStatus: PersistenceStatus(),
        options: ChatSendRequestOptions(
          modelID: "model-A.gguf",
          sampling: ChatSampling(temperature: 0.7, topP: 0.9, maxTokens: 128),
          speculation: spec
        )
      )
      try await waitUntil("stream finishes") { !controller.isInFlight }

      let request = try XCTUnwrap(engine.requests.first)
      let wireSpec = try XCTUnwrap(request.speculation,
                                   "resent request must carry the forked profile's speculation")
      XCTAssertTrue(wireSpec.enabled)
      // Enabled speculation forces greedy decoding (#426) regardless of the
      // toolbar sampling — proof the speculation coupling survived the fork.
      XCTAssertEqual(request.sampling.temperature, 0)
    }
  }

  private func waitUntil(
    _ description: String,
    timeout: TimeInterval = 1,
    condition: @MainActor @escaping () -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Timed out waiting for \(description)")
  }
}

private final class CapturingChatEngine: EngineClient, @unchecked Sendable {
  private(set) var requests: [ChatRequest] = []
  func health() async throws -> EngineHealth { EngineHealth(status: .ok) }
  func models() async throws -> [ModelInfo] { [] }
  func chatCompletion(_ req: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
    requests.append(req)
    return AsyncThrowingStream { continuation in
      continuation.yield(.delta(role: .assistant, content: "ok"))
      continuation.yield(.finish(reason: .stop))
      continuation.finish()
    }
  }
  func dispatchInferlet(_ req: InferletRequest) -> AsyncThrowingStream<Data, Error> {
    AsyncThrowingStream { $0.finish() }
  }
}
