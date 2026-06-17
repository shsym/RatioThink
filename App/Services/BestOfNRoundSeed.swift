import Foundation
import SwiftData

/// DEBUG-only deterministic seeder for the Best-of-N interactive-selection GUI
/// test (#690).
///
/// A real Best-of-N round is produced by streaming N candidates from a live pie
/// engine, but a sandboxed XCUITest cannot spawn pie or write `PIE_HOME` (the
/// same constraint #678's `TestModelSeed` works around). So when
/// `PIE_TEST_SEED_BESTOFN=<N>` is set, this inserts ONE persisted chat whose
/// final assistant turn is an **uncommitted Best-of-N round** — empty content
/// (so `liveBestOfNRoundID` makes it the interactive round), a `ToTTree` with N
/// pickable candidate nodes (so `TreeSearchSection` renders the panes), and the
/// matching `BestOfNRound` pick set. The round is built through the exact same
/// `ToTTree.apply` event path the live stream drives, so the seeded tree is
/// byte-identical in shape to a real round — only the content is canned.
///
/// Determinism: fixed candidate text, fixed ids, a single anchor `Date`, no
/// randomness — every run seeds the same round. Safety: runs only when the
/// store is empty, behind `#if DEBUG` at the call site and the isolated
/// `PIE_HOME` every GUI suite uses, so a shipped app never seeds.
@available(macOS 14, *)
enum BestOfNRoundSeed {
  static let envVar = "PIE_TEST_SEED_BESTOFN"

  /// Stable title so the test can open the seeded chat by a fixed row.
  static let chatTitle = "Best of N Round"

  /// The seeded user prompt (the round answers this).
  static let prompt = "Give me one idea for a free Saturday afternoon."

  /// Canned, deliberately DISTINCT candidate answers so the unpicked-collapse is
  /// visually and structurally observable (each is a different stance).
  static let candidateTexts = [
    "Go for a long walk in a nearby park and bring a book to read on a bench.",
    "Cook something ambitious you have never tried, then invite a friend to share it.",
    "Take a day trip to a town one train ride away and wander with no fixed plan.",
  ]

  /// Insert the seeded round when requested and the store is empty. `N` is read
  /// from the env value but clamped to the canned-text count.
  @MainActor
  static func seedIfRequested(into context: ModelContext) {
    guard let raw = ProcessInfo.processInfo.environment[envVar],
          let requested = Int(raw), requested > 0 else { return }
    let existing = (try? context.fetchCount(FetchDescriptor<Chat>())) ?? 0
    guard existing == 0 else {
      NSLog("BestOfNRoundSeed: store already has \(existing) chats — skipping seed")
      return
    }
    let n = min(requested, candidateTexts.count)

    let anchor = Date(timeIntervalSince1970: 1_700_000_000)
    let chat = Chat(title: chatTitle, profileID: "best-of-n", createdAt: anchor, userTitled: true)
    context.insert(chat)

    let user = Message(role: "user", content: prompt, ts: anchor.addingTimeInterval(1))
    chat.messages.append(user)

    let (totData, roundData) = buildRound(n: n)
    let assistant = Message(
      role: "assistant",
      content: "",  // empty → liveBestOfNRoundID picks this as the interactive round
      ts: anchor.addingTimeInterval(2),
      tot: totData,
      bestOfN: roundData)
    chat.messages.append(assistant)
    chat.updatedAt = anchor.addingTimeInterval(2)

    do {
      try context.save()
    } catch {
      NSLog("BestOfNRoundSeed: save failed: \(error)")
    }
  }

  /// Build the round's `ToTTree` (via the live `apply` event path) and the
  /// matching `BestOfNRound`, both encoded for persistence. Candidate node ids
  /// and the round's candidate ids are the SAME strings, so `pickableIDs`
  /// lines up with the rendered nodes.
  @MainActor
  static func buildRound(n: Int) -> (Data?, Data?) {
    var tree = ToTTree()
    tree.apply(.treeStart(id: "bon-seed", model: "seed", breadth: n, depth: 1, beamWidth: 1))
    var candidates: [ToTSelectionCandidate] = []
    var kept: [String] = []
    for idx in 0..<n {
      let id = "bon-n\(idx)"
      tree.apply(.nodeComplete(ToTNode(
        id: id, parentID: "root", depth: 1, branchIndex: idx,
        content: candidateTexts[idx], score: nil, status: .ok)))
      candidates.append(ToTSelectionCandidate(
        id: id, branchIndex: idx, snapshotName: "bon/seed/1/\(idx)"))
      kept.append(id)
    }
    tree.apply(.levelPruned(level: 1, kept: kept))
    tree.apply(.awaitingSelection(level: 1, candidates: candidates))

    let round = BestOfNRound(level: 1, candidates: candidates, chosenID: nil)
    return (try? JSONEncoder().encode(tree), try? JSONEncoder().encode(round))
  }
}
