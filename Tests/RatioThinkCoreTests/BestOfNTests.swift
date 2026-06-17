import XCTest

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
    """
    let profile = try Profile.parse(toml: toml)
    let config = try XCTUnwrap(profile.bestOfN)
    XCTAssertEqual(config.n, 4)
    XCTAssertEqual(config.maxTokensPerCandidate, 320)
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
    XCTAssertEqual(config.n, 5)
    XCTAssertEqual(config.maxTokensPerCandidate, 256)
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
