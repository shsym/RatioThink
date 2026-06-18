import XCTest
import SwiftData

@testable import RatioThinkCore

/// Best-of-N (#690) client-side contract: the new `awaiting_selection` stream
/// terminal decodes, a `best-of-n` profile resolves its config, and the round
/// metadata round-trips.
final class BestOfNTests: XCTestCase {

  // MARK: awaiting_selection decode (ToTStream)

  func test_awaitingSelection_decodes_level_and_candidates() throws {
    let json = """
    {"event":"awaiting_selection","level":2,"candidates":[\
    {"id":"bon-n1","branch_index":0,"snapshot_name":"bon/r/2/0"},\
    {"id":"bon-n2","branch_index":1,"snapshot_name":"bon/r/2/1"}]}
    """
    let event = try decodeToTFrame(Data(json.utf8))
    guard case let .awaitingSelection(level, candidates) = event else {
      return XCTFail("expected .awaitingSelection, got \(String(describing: event))")
    }
    XCTAssertEqual(level, 2)
    XCTAssertEqual(candidates.count, 2)
    XCTAssertEqual(candidates[0].id, "bon-n1")
    XCTAssertEqual(candidates[0].branchIndex, 0)
    XCTAssertEqual(candidates[1].snapshotName, "bon/r/2/1")
  }

  func test_awaitingSelection_absent_candidates_decodes_empty() throws {
    let event = try decodeToTFrame(Data(#"{"event":"awaiting_selection","level":1}"#.utf8))
    guard case let .awaitingSelection(level, candidates) = event else {
      return XCTFail("expected .awaitingSelection")
    }
    XCTAssertEqual(level, 1)
    XCTAssertTrue(candidates.isEmpty)
  }

  func test_awaitingSelection_without_level_is_malformed() {
    XCTAssertThrowsError(try decodeToTFrame(Data(#"{"event":"awaiting_selection"}"#.utf8)))
  }

  // MARK: ToTTree folds the terminal to complete

  func test_tree_awaitingSelection_marks_complete_without_selection() {
    var tree = ToTTree()
    tree.apply(.treeStart(id: "bon-1", model: "m", breadth: 3, depth: 1, beamWidth: 3))
    tree.apply(.nodeComplete(ToTNode(
      id: "bon-n0", parentID: "root", depth: 1, branchIndex: 0,
      content: "A", score: nil, status: .ok)))
    tree.apply(.awaitingSelection(level: 1, candidates: [
      ToTSelectionCandidate(id: "bon-n0", branchIndex: 0, snapshotName: "s0")
    ]))
    XCTAssertEqual(tree.status, .complete)
    // No auto-selected answer — the user is the judge.
    XCTAssertNil(tree.selectedNodeID)
    XCTAssertEqual(tree.rootChildren.count, 1)
  }

  // MARK: Profile.bestOfN

  func test_profile_bestOfN_reads_mode_and_n() throws {
    let toml = """
    id = "best-of-n"
    name = "Best of N"
    model = "m"
    inferlet = "chat-apc"
    [sampling]
    temperature = 0.7
    top_p = 0.9
    max_tokens = 2048
    [inferlet_args]
    mode = "best-of-n"
    n = 4
    max_tokens_per_candidate = 320
    thinking = false
    """
    let profile = try Profile.parse(toml: toml)
    let config = try XCTUnwrap(profile.bestOfN)
    XCTAssertEqual(config.n, 4)
    XCTAssertEqual(config.maxTokensPerCandidate, 320)
    // An explicit `thinking = false` is honored over the ON default (#708).
    XCTAssertFalse(config.thinking)
    // Sampling is sourced from the profile (drives candidate-generation temp).
    XCTAssertEqual(profile.bestOfNRequestSampling.temperature, 0.7)
  }

  func test_non_bestOfN_profile_returns_nil() throws {
    let toml = """
    id = "tree-of-thought"
    name = "Tree of Thought"
    model = "m"
    inferlet = "chat-apc"
    [inferlet_args]
    mode = "tree-of-thought"
    """
    let profile = try Profile.parse(toml: toml)
    XCTAssertNil(profile.bestOfN)
  }

  func test_bestOfN_defaults_apply_when_keys_absent() throws {
    let toml = """
    id = "best-of-n"
    name = "Best of N"
    model = "m"
    inferlet = "chat-apc"
    [inferlet_args]
    mode = "best-of-n"
    """
    let config = try XCTUnwrap(Profile.parse(toml: toml).bestOfN)
    XCTAssertEqual(config.n, 3)  // #708: default N is 3
    XCTAssertEqual(config.maxTokensPerCandidate, 256)
    XCTAssertTrue(config.thinking)  // #708: thinking defaults ON
  }

  // MARK: BestOfNRound metadata

  func test_round_roundtrips_and_resolves_choice() throws {
    let candidates = [
      ToTSelectionCandidate(id: "n0", branchIndex: 0, snapshotName: "s0"),
      ToTSelectionCandidate(id: "n1", branchIndex: 1, snapshotName: "s1"),
      ToTSelectionCandidate(id: "n2", branchIndex: 2, snapshotName: "s2"),
    ]
    var round = BestOfNRound(level: 1, candidates: candidates, chosenID: nil)
    XCTAssertFalse(round.hasChoice)
    XCTAssertNil(round.chosen)

    round.chosenID = "n1"
    let data = try JSONEncoder().encode(round)
    let decoded = try JSONDecoder().decode(BestOfNRound.self, from: data)
    XCTAssertEqual(decoded, round)
    XCTAssertTrue(decoded.hasChoice)
    XCTAssertEqual(decoded.chosen?.snapshotName, "s1")
    // Unpicked = the other two snapshots, dropped next round.
    XCTAssertEqual(decoded.unpickedSnapshotNames(excluding: "n1"), ["s0", "s2"])

    // #708 click-to-reselect: re-picking is just overwriting `chosenID` with a
    // different candidate id (`handleBestOfN(.pick)` is idempotent on re-tap).
    // All snapshots stay alive, so the new choice resolves cleanly and the
    // unpicked set tracks the new pick.
    round.chosenID = "n2"
    XCTAssertTrue(round.hasChoice)
    XCTAssertEqual(round.chosen?.snapshotName, "s2")
    XCTAssertEqual(round.unpickedSnapshotNames(excluding: "n2"), ["s0", "s1"])
  }

  // MARK: Lifecycle release request wire (stop/commit + abandon trigger)

  /// The App-side terminal cleanup fires a `best-of-n` dispatch carrying the
  /// snapshot names under `release`, with NO messages and `stream:false` — the
  /// server then deletes them and frees their KV pages. This proves the commit/
  /// abandon trigger builds the correct release request (the engine-side delete
  /// + accounting is proven by the Rust `release_all` tests and the real smoke).
  @MainActor
  func test_releaseBestOfNSnapshots_dispatches_release_request_with_names_no_messages() async throws {
    let engine = ReleaseCapturingEngine()
    let controller = ChatSendController()
    controller.releaseBestOfNSnapshots(
      engine: engine, modelID: "qwen", snapshotNames: ["bon/r/1/0", "bon/r/1/1"])

    // The release fires on a detached MainActor Task; wait for the dispatch.
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline, engine.lastRequest == nil {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let req = try XCTUnwrap(engine.lastRequest, "release must dispatch a request")
    XCTAssertEqual(req.inferlet, "best-of-n")
    XCTAssertFalse(req.stream, "a release runs no generation — not a stream")
    XCTAssertNil(req.messages, "a release carries no messages")
    let input = try JSONDecoder().decode(ReleaseWire.self, from: req.input)
    XCTAssertEqual(input.model, "qwen")
    XCTAssertEqual(input.release, ["bon/r/1/0", "bon/r/1/1"])
  }

  /// An empty release set must NOT dispatch anything (no wasted request).
  @MainActor
  func test_releaseBestOfNSnapshots_empty_is_a_noop() async throws {
    let engine = ReleaseCapturingEngine()
    ChatSendController().releaseBestOfNSnapshots(engine: engine, modelID: "qwen", snapshotNames: [])
    try await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertNil(engine.lastRequest, "an empty release must not hit the engine")
  }

  /// The delete path has no gate to supply a model id, so it releases with a
  /// nil model — the request must OMIT `model` entirely so the engine resolves
  /// its served (first registered) model.
  @MainActor
  func test_releaseBestOfNSnapshots_nil_model_omits_model_field() async throws {
    let engine = ReleaseCapturingEngine()
    ChatSendController().releaseBestOfNSnapshots(engine: engine, modelID: nil, snapshotNames: ["s0"])
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline, engine.lastRequest == nil {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let req = try XCTUnwrap(engine.lastRequest, "release must dispatch a request")
    let obj = try JSONSerialization.jsonObject(with: req.input) as? [String: Any]
    XCTAssertNil(obj?["model"], "a nil model must be omitted so the engine resolves its served model")
    XCTAssertEqual(obj?["release"] as? [String], ["s0"])
  }

  // MARK: Terminal-cleanup predicate (the set delete / profile-swap / abandon release)

  /// `uncommittedCandidateSnapshotNames` is the single source for "what to
  /// release" on every no-next-round terminal (chat delete F1, profile swap F2,
  /// abandon). It must collect the candidate snapshots of UNCOMMITTED rounds
  /// (empty content + a decodable round) and skip committed rounds (the reply
  /// was kept) and plain messages.
  func test_uncommitted_candidate_snapshot_names_collects_only_uncommitted_rounds() {
    func roundData(_ snaps: [String]) -> Data {
      let cands = snaps.enumerated().map {
        ToTSelectionCandidate(id: "n\($0.offset)", branchIndex: $0.offset, snapshotName: $0.element)
      }
      return try! JSONEncoder().encode(BestOfNRound(level: 1, candidates: cands, chosenID: nil))
    }
    let uncommitted = Message(role: "assistant", content: "", bestOfN: roundData(["s0", "s1"]))
    // Committed: the user chose "Use this", so content is set — its snapshot was
    // already released on commit; it must NOT be collected again here.
    let committed = Message(role: "assistant", content: "the kept reply", bestOfN: roundData(["s2"]))
    let plain = Message(role: "assistant", content: "")  // no round at all
    let user = Message(role: "user", content: "prompt")

    let names = BestOfNRound.uncommittedCandidateSnapshotNames(
      in: [user, uncommitted, committed, plain])
    XCTAssertEqual(names, ["s0", "s1"])
  }

  /// Two uncommitted rounds in one chat (e.g. a think-more chain abandoned
  /// mid-way) release ALL their candidate snapshots.
  func test_uncommitted_candidate_snapshot_names_spans_multiple_rounds() {
    func roundData(_ snaps: [String]) -> Data {
      let cands = snaps.enumerated().map {
        ToTSelectionCandidate(id: "n\($0.offset)", branchIndex: $0.offset, snapshotName: $0.element)
      }
      return try! JSONEncoder().encode(BestOfNRound(level: 1, candidates: cands, chosenID: nil))
    }
    let r1 = Message(role: "assistant", content: "", bestOfN: roundData(["a0", "a1"]))
    let r2 = Message(role: "assistant", content: "", bestOfN: roundData(["b0", "b1"]))
    XCTAssertEqual(
      BestOfNRound.uncommittedCandidateSnapshotNames(in: [r1, r2]),
      ["a0", "a1", "b0", "b1"])
  }

  private struct ReleaseWire: Decodable {
    let model: String
    let release: [String]
  }

  // MARK: liveness rule (#708) — only the trailing, uncommitted round is live

  private func bonRoundData(_ snaps: [String], chosen: String? = nil) -> Data {
    let cands = snaps.enumerated().map {
      ToTSelectionCandidate(id: "n\($0.offset)", branchIndex: $0.offset, snapshotName: $0.element)
    }
    return try! JSONEncoder().encode(BestOfNRound(level: 1, candidates: cands, chosenID: chosen))
  }

  /// The trailing, content-empty Best-of-N round is the one live row.
  func test_liveRoundID_is_the_trailing_uncommitted_round() {
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let user = Message(role: "user", content: "q", ts: base)
    let round = Message(role: "assistant", content: "", ts: base.addingTimeInterval(1),
                        bestOfN: bonRoundData(["s0", "s1"]))
    XCTAssertEqual(BestOfNRound.liveRoundID(in: [user, round]), round.id)
  }

  /// A committed round (think-more / use-this set `content`) is NOT live — it
  /// locks into read-only history even while it is still the trailing turn.
  func test_liveRoundID_nil_when_round_committed() {
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let round = Message(role: "assistant", content: "the kept reply", ts: base,
                        bestOfN: bonRoundData(["s0"], chosen: "n0"))
    XCTAssertNil(BestOfNRound.liveRoundID(in: [round]))
  }

  /// The pick-then-abandon hole: an empty round the user moved past with a NEW
  /// turn is no longer trailing, so it must NOT stay falsely live (the bug the
  /// old "last content-empty round" rule had).
  func test_liveRoundID_nil_for_picked_then_abandoned_round() {
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let round = Message(role: "assistant", content: "", ts: base.addingTimeInterval(1),
                        bestOfN: bonRoundData(["s0"], chosen: "n0"))
    let newTurn = Message(role: "user", content: "another question",
                          ts: base.addingTimeInterval(2))
    XCTAssertNil(BestOfNRound.liveRoundID(in: [round, newTurn]))
  }

  /// Think-more commits the prior round (content set) and appends a new empty
  /// trailing round → liveness moves to the new round, never the committed one.
  func test_liveRoundID_moves_to_the_new_round_after_think_more() {
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let committed = Message(role: "assistant", content: "round 1 pick",
                            ts: base.addingTimeInterval(1), bestOfN: bonRoundData(["a0"], chosen: "n0"))
    let next = Message(role: "assistant", content: "", ts: base.addingTimeInterval(2),
                       bestOfN: bonRoundData(["b0", "b1"]))
    XCTAssertEqual(BestOfNRound.liveRoundID(in: [committed, next]), next.id)
  }

  /// No Best-of-N round at all → no live row.
  func test_liveRoundID_nil_without_any_bestOfN_round() {
    XCTAssertNil(BestOfNRound.liveRoundID(in: [Message(role: "assistant", content: "plain")]))
  }

  // MARK: collapse-to-chosen in finalized history (#708)

  /// The LIVE (interactive) round renders every candidate, pickable.
  func test_visibleCandidateIDs_live_round_shows_all() {
    XCTAssertEqual(
      BestOfNRound.visibleCandidateIDs(["a", "b", "c"], isInteractive: true, chosenID: "b"),
      ["a", "b", "c"])
  }

  /// A FINALIZED read-only round WITH a choice collapses to the chosen candidate
  /// alone — locked history reads as a single answer, not a candidate list.
  func test_visibleCandidateIDs_finalized_with_choice_shows_only_chosen() {
    XCTAssertEqual(
      BestOfNRound.visibleCandidateIDs(["a", "b", "c"], isInteractive: false, chosenID: "b"),
      ["b"])
  }

  /// A finalized round with NO choice (pure abandon) keeps every candidate —
  /// show what happened, don't blank it.
  func test_visibleCandidateIDs_abandoned_round_shows_all() {
    XCTAssertEqual(
      BestOfNRound.visibleCandidateIDs(["a", "b", "c"], isInteractive: false, chosenID: nil),
      ["a", "b", "c"])
  }

  // MARK: selection-flash regression (#708) — option presentation from frame 1

  /// The selection-flash bug: a Best-of-N turn streams its candidates into
  /// `assistant.tot` but only set `assistant.bestOfN` at `awaiting_selection`,
  /// AFTER generation. While `bestOfN` was nil the round rendered through the
  /// tree-of-thought branch, where a `kept` beam node draws a GREEN checkmark —
  /// which flipped to a hollow Best-of-N option glyph the instant
  /// `awaiting_selection` set `bestOfN` (the green-then-unselected flash).
  ///
  /// Root-cause guard: the turn must carry `bestOfN` (option presentation) from
  /// the FIRST frame, with no chosen candidate, all the way through the
  /// `node_complete` / `level_pruned` window (where the ToT branch would have
  /// drawn the green `kept` checkmarks) — never only at `awaiting_selection`.
  /// Static snapshot tests render the final state only and missed this; this
  /// drives the streaming transition.
  @MainActor
  func test_round_renders_as_bestOfN_throughout_generation_never_kept_beam() async throws {
    let container = try RatioThinkModelContainer.makeInMemory()
    let context = ModelContext(container)
    let chat = Chat()
    context.insert(chat)
    chat.messages.append(Message(role: "user", content: "hi", ts: Date(timeIntervalSinceReferenceDate: 1)))
    try context.save()

    let engine = ManualInferletEngine()
    let controller = ChatSendController()
    controller.sendBestOfN(
      chat: chat,
      context: context,
      engine: engine,
      config: BestOfNProfileConfig(n: 3),
      persistenceStatus: PersistenceStatus(),
      options: ChatSendRequestOptions(modelID: "m"))

    func assistant() -> Message? { chat.messages.first { $0.role == "assistant" } }
    func round() -> BestOfNRound? {
      assistant()?.bestOfN.flatMap { try? JSONDecoder().decode(BestOfNRound.self, from: $0) }
    }
    func nodeCount() -> Int {
      (assistant()?.tot.flatMap { try? JSONDecoder().decode(ToTTree.self, from: $0) })?.nodes.count ?? 0
    }

    // The assistant turn is created at round start.
    try await waitUntil("assistant turn inserted") { assistant() != nil }

    // INVARIANT 1 — before any candidate streams, the turn is ALREADY a
    // Best-of-N round (option presentation), with no choice. Pre-fix this is
    // nil, so MessageBubble would take the ToT (green-beam) branch.
    let early = try XCTUnwrap(round(), "turn must carry bestOfN from round start, not only at awaiting_selection")
    XCTAssertTrue(early.candidates.isEmpty, "no pickable candidates before awaiting_selection")
    XCTAssertNil(early.chosenID, "nothing chosen before the user picks")

    // Stream the candidates and the `level_pruned` that marks them `kept` — the
    // exact window the ToT branch would render as green checkmarks.
    engine.emit(#"{"event":"tree_start","id":"bon","model":"m","breadth":3,"depth":1,"beam_width":3}"#)
    engine.emit(#"{"event":"node_complete","node":{"id":"n0","parent_id":"root","depth":1,"branch_index":0,"content":"A","status":"ok"}}"#)
    engine.emit(#"{"event":"node_complete","node":{"id":"n1","parent_id":"root","depth":1,"branch_index":1,"content":"B","status":"ok"}}"#)
    engine.emit(#"{"event":"level_pruned","level":1,"kept":["n0","n1"]}"#)
    try await waitUntil("candidates streamed") { nodeCount() >= 2 }

    // INVARIANT 2 — mid-generation (post `level_pruned`, pre `awaiting_selection`)
    // the turn is STILL Best-of-N with no chosen candidate. The view therefore
    // shows neutral option glyphs — never a green kept/chosen indicator.
    let mid = try XCTUnwrap(round(), "turn must stay in Best-of-N mode during generation")
    XCTAssertNil(mid.chosenID, "no candidate may be chosen before the user picks")

    // Finalize → candidates become pickable.
    engine.emit(#"{"event":"awaiting_selection","level":1,"candidates":[{"id":"n0","branch_index":0,"snapshot_name":"s0"},{"id":"n1","branch_index":1,"snapshot_name":"s1"}]}"#)
    engine.finish()
    try await waitUntil("round resolved") { !controller.isInFlight }

    let final = try XCTUnwrap(round())
    XCTAssertEqual(final.candidates.map(\.id), ["n0", "n1"], "awaiting_selection populates the pick set")
    XCTAssertNil(final.chosenID, "still no choice until the user picks")
  }

  /// Polls `condition` on the main actor until true or the timeout elapses.
  @MainActor
  private func waitUntil(
    _ description: String, timeout: TimeInterval = 3,
    _ condition: () -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail("timed out waiting for: \(description)")
  }
}

/// `EngineClient` whose Best-of-N dispatch stream is driven frame-by-frame from
/// the test, so a test can inspect controller/message state at any point of the
/// generation → `awaiting_selection` transition (#708 flash regression).
private final class ManualInferletEngine: EngineClient, @unchecked Sendable {
  private var continuation: AsyncThrowingStream<Data, Error>.Continuation?

  func health() async throws -> EngineHealth { EngineHealth(status: .ok) }
  func models() async throws -> [ModelInfo] { [] }
  func chatCompletion(_ req: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
    AsyncThrowingStream { $0.finish() }
  }
  func dispatchInferlet(_ req: InferletRequest) -> AsyncThrowingStream<Data, Error> {
    AsyncThrowingStream { self.continuation = $0 }
  }

  /// Yield one raw JSON event frame (the wire shape `toTEventStream` parses).
  func emit(_ json: String) { continuation?.yield(Data(json.utf8)) }
  func finish() { continuation?.finish() }
}

/// Minimal `EngineClient` that records the last dispatched `InferletRequest` so
/// a test can assert the release wire. Replies with an empty stream.
private final class ReleaseCapturingEngine: EngineClient, @unchecked Sendable {
  private(set) var lastRequest: InferletRequest?

  func health() async throws -> EngineHealth { EngineHealth(status: .ok) }
  func models() async throws -> [ModelInfo] { [] }
  func chatCompletion(_ req: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
    AsyncThrowingStream { $0.finish() }
  }
  func dispatchInferlet(_ req: InferletRequest) -> AsyncThrowingStream<Data, Error> {
    lastRequest = req
    return AsyncThrowingStream { $0.finish() }
  }
}
