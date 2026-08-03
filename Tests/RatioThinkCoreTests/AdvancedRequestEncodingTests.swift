import XCTest
import SwiftData

@testable import RatioThinkCore

/// The advanced-profile dispatch bodies must actually put on the wire every
/// property they declare.
///
/// This exists because they did not. `ToTRequestInput` and `BestOfNRequestInput`
/// each declared `let boundary: ChatCacheDirective?` and each populated it at
/// its call site — but their explicit `CodingKeys` enums omitted `boundary`.
/// Declaring `CodingKeys` suppresses synthesis for anything absent, so Swift
/// silently encoded a body with no `boundary` key. It compiled, it type-checked,
/// and the property was read nowhere else, so nothing failed: ToT and Best-of-N
/// dispatches simply carried no conversation identity, and cross-mode KV reuse
/// could never hit.
///
/// A type-level test cannot catch this — the bug IS the type-level agreement
/// being bypassed. Only encoding and reading the JSON back does.
@available(macOS 14, *)
final class AdvancedRequestEncodingTests: XCTestCase {

  private func encodedKeys<T: Encodable>(_ value: T) throws -> [String: Any] {
    let data = try JSONEncoder().encode(value)
    let obj = try JSONSerialization.jsonObject(with: data)
    return try XCTUnwrap(obj as? [String: Any], "body must encode to a JSON object")
  }

  private var directive: ChatCacheDirective {
    ChatCacheDirective(key: "0F1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9", turn: 4)
  }

  func testToTRequestCarriesTheBoundaryDirective() throws {
    let json = try encodedKeys(
      ToTRequestInput(
        model: "qwen",
        boundary: directive,
        messages: [ChatMessage(role: .user, content: "hi")],
        breadth: 2,
        depth: 1,
        beamWidth: 1,
        maxTokensPerNode: 256,
        temperature: 0.7,
        topP: 1.0
      )
    )
    let boundary = try XCTUnwrap(
      json["boundary"] as? [String: Any],
      "ToT dispatch dropped `boundary`; chat -> ToT -> chat cannot reuse KV without it"
    )
    XCTAssertEqual(boundary["key"] as? String, directive.key)
    XCTAssertEqual(boundary["turn"] as? Int, 4)
    XCTAssertEqual(boundary["compat"] as? String, ChatCacheDirective.compatVersion)

    // The snake_case remapping must survive alongside it — adding a case to
    // CodingKeys is exactly the edit that could disturb the others.
    XCTAssertNotNil(json["beam_width"], "beam_width missing")
    XCTAssertNotNil(json["max_tokens_per_node"], "max_tokens_per_node missing")
    XCTAssertNotNil(json["top_p"], "top_p missing")
  }

  func testBestOfNRequestCarriesTheBoundaryDirective() throws {
    let json = try encodedKeys(
      BestOfNRequestInput(
        model: "qwen",
        boundary: directive,
        roundID: "ROUND-1",
        messages: [ChatMessage(role: .user, content: "hi")],
        n: 3,
        maxTokensPerCandidate: 256,
        thinking: false,
        temperature: 0.7,
        topP: 1.0,
        resumeFrom: nil,
        pickedText: nil,
        selectedComment: nil,
        unpicked: nil,
        level: nil
      )
    )
    let boundary = try XCTUnwrap(
      json["boundary"] as? [String: Any],
      "Best-of-N dispatch dropped `boundary`; the milestone-C commit needs it"
    )
    XCTAssertEqual(boundary["key"] as? String, directive.key)
    XCTAssertNotNil(json["max_tokens_per_candidate"], "max_tokens_per_candidate missing")
    XCTAssertNotNil(json["top_p"], "top_p missing")
    // The authorization scope. Without it the guest refuses to mint snapshots,
    // so a round that omits it cannot be resumed, released or committed.
    XCTAssertEqual(json["round_id"] as? String, "ROUND-1")
  }

  /// Round 1 leaves the resume fields nil and the server reads their absence as
  /// "fresh round" — so `boundary` being present must not drag them in.
  func testAbsentResumeFieldsStayAbsent() throws {
    let json = try encodedKeys(
      BestOfNRequestInput(
        model: "qwen",
        boundary: directive,
        roundID: "ROUND-1",
        messages: [],
        n: 3,
        maxTokensPerCandidate: 256,
        thinking: false,
        temperature: 0.7,
        topP: 1.0,
        resumeFrom: nil,
        pickedText: nil,
        selectedComment: nil,
        unpicked: nil,
        level: nil
      )
    )
    for absent in ["resume_from", "picked_text", "selected_comment", "unpicked", "level"] {
      XCTAssertNil(json[absent], "\(absent) must be omitted on a fresh round")
    }
  }

  /// A nil directive must omit the key rather than encode `null`: gen-core's
  /// `BoundaryDirective` defaults to reuse-enabled, and an explicit null would
  /// have to be tolerated by the decoder.
  func testNilBoundaryIsOmittedNotNull() throws {
    let json = try encodedKeys(
      ToTRequestInput(
        model: "qwen",
        boundary: nil,
        messages: [],
        breadth: 2,
        depth: 1,
        beamWidth: 1,
        maxTokensPerNode: 256,
        temperature: 0.7,
        topP: 1.0
      )
    )
    XCTAssertNil(json["boundary"], "a nil directive must be omitted, not encoded as null")
  }
}

/// The §6.2 commit body, and the ordering invariant that makes it correct.
@available(macOS 14, *)
final class BestOfNCommitEncodingTests: XCTestCase {

  private func chatWithRound(answerCommitted: Bool) throws -> (Chat, ModelContext, BestOfNRound) {
    let container = try RatioThinkModelContainer.makeInMemory()
    let context = ModelContext(container)
    let chat = Chat()
    context.insert(chat)
    chat.messages.append(Message(role: "user", content: "pick one",
                                 ts: Date(timeIntervalSinceReferenceDate: 1)))
    let assistant = Message(role: "assistant",
                            content: answerCommitted ? "candidate A" : "",
                            ts: Date(timeIntervalSinceReferenceDate: 2))
    let round = BestOfNRound(
      level: 2,
      candidates: [
        ToTSelectionCandidate(id: "bon-n1", branchIndex: 0, snapshotName: "bon/aa/2/0/bb"),
        ToTSelectionCandidate(id: "bon-n2", branchIndex: 1, snapshotName: "bon/aa/2/1/cc"),
      ],
      chosenID: "bon-n1",
      roundID: "ROUND-1")
    assistant.bestOfN = try JSONEncoder().encode(round)
    chat.messages.append(assistant)
    try context.save()
    return (chat, context, round)
  }

  private var options: ChatSendRequestOptions {
    ChatSendRequestOptions(
      modelID: "qwen",
      sampling: ChatSampling(temperature: 0.7, topP: 0.95, maxTokens: 256),
      systemPromptOverride: "Be concise.")
  }

  private func body(_ prepared: ChatSendController.PreparedBestOfNCommit) throws -> [String: Any] {
    try XCTUnwrap(
      JSONSerialization.jsonObject(with: prepared.dispatchRequest.input) as? [String: Any])
  }

  /// THE ordering invariant. The guest appends `assistant(answer)` itself, so a
  /// history that already contains the answer names a boundary with it twice —
  /// one the next chat turn never asks for. An assistant row with empty content
  /// is excluded from request history, which is exactly why the commit must be
  /// prepared BEFORE the answer is written locally.
  @MainActor
  func testCommitMessagesExcludeTheAcceptedAnswer() throws {
    let (chat, _, round) = try chatWithRound(answerCommitted: false)
    let prepared = try XCTUnwrap(
      ChatSendController.prepareBestOfNCommit(
        chat: chat, options: options, round: round, answer: "candidate A"))
    let json = try body(prepared)
    let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
    XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "user"],
                   "the in-flight assistant row must not be in the commit history")
    XCTAssertFalse(
      messages.contains { ($0["content"] as? String) == "candidate A" },
      "the accepted answer must not appear in messages — the guest appends it")
    XCTAssertEqual(json["commit"].flatMap { ($0 as? [String: Any])?["answer"] as? String },
                   "candidate A")
  }

  /// Proof the ordering is load-bearing rather than incidental: prepared AFTER
  /// the answer is written, the same call produces a history that DOES contain
  /// it. The guest would then append it a second time and name a boundary the
  /// next chat turn never asks for.
  @MainActor
  func testPreparingAfterTheCommitWouldDuplicateTheAnswer() throws {
    let (chat, _, round) = try chatWithRound(answerCommitted: true)
    let prepared = try XCTUnwrap(
      ChatSendController.prepareBestOfNCommit(
        chat: chat, options: options, round: round, answer: "candidate A"))
    let messages = try XCTUnwrap(try body(prepared)["messages"] as? [[String: Any]])
    XCTAssertTrue(
      messages.contains { ($0["content"] as? String) == "candidate A" },
      "this is the WRONG order — it is asserted only to show the invariant has teeth")
    XCTAssertEqual(messages.count, 3, "system + user + the already-committed answer")
  }

  /// The system prompt is part of the digested history. If the commit assembled
  /// different options than the round did, it would name a boundary nothing
  /// asks for — silently, with a permanently cold next turn.
  @MainActor
  func testCommitCarriesTheSystemPrompt() throws {
    let (chat, _, round) = try chatWithRound(answerCommitted: false)
    let prepared = try XCTUnwrap(
      ChatSendController.prepareBestOfNCommit(
        chat: chat, options: options, round: round, answer: "candidate A"))
    let messages = try XCTUnwrap(try body(prepared)["messages"] as? [[String: Any]])
    XCTAssertEqual(messages.first?["content"] as? String, "Be concise.")
  }

  @MainActor
  func testCommitCarriesTheScopeSelectionAndReleaseList() throws {
    let (chat, _, round) = try chatWithRound(answerCommitted: false)
    let json = try body(try XCTUnwrap(
      ChatSendController.prepareBestOfNCommit(
        chat: chat, options: options, round: round, answer: "candidate A")))
    XCTAssertEqual(json["round_id"] as? String, "ROUND-1")
    XCTAssertNotNil(json["boundary"], "without it the commit cannot name a conv/ boundary")
    let commit = try XCTUnwrap(json["commit"] as? [String: Any])
    XCTAssertEqual(commit["snapshot_name"] as? String, "bon/aa/2/0/bb",
                   "the CHOSEN candidate, not the first")
    XCTAssertEqual(commit["release"] as? [String], ["bon/aa/2/0/bb", "bon/aa/2/1/cc"],
                   "every name the round minted, including the selected one")
  }

  /// A round persisted before the scope existed cannot authorize its own
  /// deletes, so no commit is prepared and the caller falls back to a plain
  /// release rather than issuing a request the guest would refuse wholesale.
  @MainActor
  func testARoundWithoutAScopePreparesNoCommit() throws {
    let (chat, _, round) = try chatWithRound(answerCommitted: false)
    var unscoped = round
    unscoped.roundID = nil
    XCTAssertNil(ChatSendController.prepareBestOfNCommit(
      chat: chat, options: options, round: unscoped, answer: "candidate A"))
  }

  /// Nothing to commit without a pick.
  @MainActor
  func testAnUnpickedRoundPreparesNoCommit() throws {
    let (chat, _, round) = try chatWithRound(answerCommitted: false)
    var unpicked = round
    unpicked.chosenID = nil
    XCTAssertNil(ChatSendController.prepareBestOfNCommit(
      chat: chat, options: options, round: unpicked, answer: "candidate A"))
  }

  /// A think-more must reuse the round it is continuing, not mint a new scope.
  ///
  /// This is the bug a guest-side gate could never catch: `bon.py` builds its
  /// own requests, so it passed the same `round_id` to both hops and exercised
  /// the guest's contract while silently sidestepping whether the CLIENT can
  /// satisfy it. Minting fresh here made the guest reject every `resume_from`
  /// as belonging to a different round — a hard 400 on every think-more.
  @MainActor
  func testAThinkMoreCarriesTheRoundScope() throws {
    let resume = ChatSendController.BestOfNResume(
      roundID: "ROUND-1",
      pickedName: "bon/aa/1/0/bb",
      pickedText: "candidate A",
      unpicked: ["bon/aa/1/1/cc"],
      level: 2)
    XCTAssertEqual(resume.roundID, "ROUND-1")

    // The request builder must put THAT scope on the wire, not a fresh one.
    let data = try JSONEncoder().encode(
      BestOfNRequestInput(
        model: "qwen",
        boundary: ChatCacheDirective(key: "K", turn: 2),
        roundID: resume.roundID,
        messages: [ChatMessage(role: .user, content: "hi")],
        n: 3,
        maxTokensPerCandidate: 256,
        thinking: false,
        temperature: 0.7,
        topP: 1.0,
        resumeFrom: resume.pickedName,
        pickedText: resume.pickedText,
        selectedComment: nil,
        unpicked: resume.unpicked,
        level: resume.level))
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(json["round_id"] as? String, "ROUND-1",
                   "a resumed round must carry the scope its snapshots were minted under")
    XCTAssertEqual(json["resume_from"] as? String, "bon/aa/1/0/bb")
    XCTAssertEqual(json["level"] as? Int, 2, "level distinguishes steps within one scope")
  }

  /// `boundary_saved: false` means the guest deleted NOTHING, so the caller
  /// must still free the round. A decoder that defaulted this to true would
  /// leak the round's KV on every failed save.
  func testCommitAckDecodesTheLoadBearingField() throws {
    let ack = try XCTUnwrap(try ChatSendController.decodeCommitAck(frames: [
      Data(#"{"object":"best_of_n.commit","model":"qwen","boundary_saved":false,"requested":2,"released":0,"absent":0,"refused":0}"#.utf8)
    ]))
    XCTAssertFalse(ack.boundarySaved)
    XCTAssertEqual(ack.released, 0)
  }

  /// A refusal is always logged: it means the client asked to free something it
  /// could not prove it owned.
  func testARefusalIsAlwaysSurfaced() throws {
    let ack = BestOfNCommitAck(
      boundarySaved: true, requested: 3, released: 2, absent: 0, refused: 1)
    XCTAssertNotNil(ChatSendController.shortCommitLog(ack))
    let clean = BestOfNCommitAck(
      boundarySaved: true, requested: 3, released: 3, absent: 0, refused: 0)
    XCTAssertNil(ChatSendController.shortCommitLog(clean), "a clean commit is silent")
  }
}
