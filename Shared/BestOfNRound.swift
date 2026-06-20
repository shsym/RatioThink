import Foundation

/// Selection metadata for one Best-of-N interactive round (#690), persisted in
/// `Message.bestOfN`. The N candidates themselves live in the shared `ToTTree`
/// snapshot (`Message.tot`); this adds only the state the tree model does not
/// hold: the round `level`, the pickable candidates (id + snapshot name to
/// resume from), and which candidate the user chose (nil until picked).
public struct BestOfNRound: Equatable, Sendable, Codable {
  public var level: Int
  /// The candidates the user may pick — those whose KV the engine saved, in
  /// the engine's `awaiting_selection` order.
  public var candidates: [ToTSelectionCandidate]
  /// The picked candidate's node id, or nil while the round is still awaiting
  /// a choice.
  public var chosenID: String?
  /// The think-more guidance the user typed on the PREVIOUS round that spawned
  /// this one (#736 Bug C). Persisted on the round so it survives the think-more
  /// transition by construction — the prior design held it only in transient
  /// `@State` that was cleared on commit, so it vanished from the UI. nil for a
  /// first round (no preceding guidance). Optional ⇒ existing persisted rounds
  /// decode with `inboundComment == nil`.
  public var inboundComment: String?

  public init(level: Int, candidates: [ToTSelectionCandidate], chosenID: String? = nil,
              inboundComment: String? = nil) {
    self.level = level
    self.candidates = candidates
    self.chosenID = chosenID
    self.inboundComment = inboundComment
  }

  /// The chosen candidate, if the user has picked one.
  public var chosen: ToTSelectionCandidate? {
    guard let chosenID else { return nil }
    return candidates.first { $0.id == chosenID }
  }

  /// True once a pick has been made (the round is resolved; unpicked collapse).
  public var hasChoice: Bool { chosenID != nil }

  /// Snapshot names of the candidates NOT chosen — posted to the next round so
  /// the engine drops them (deterministic free).
  public func unpickedSnapshotNames(excluding id: String) -> [String] {
    candidates.filter { $0.id != id }.map(\.snapshotName)
  }

  /// The id of the LIVE Best-of-N round in a chat — the one row that shows the
  /// interactive controls (pick / think-more / use-this). A round is live ONLY
  /// while it is the TRAILING turn (nothing committed after it) AND still
  /// awaiting a final answer (`content` empty). This is the single source of the
  /// liveness rule (#708): a round the user picked-then-abandoned (moved on with
  /// a new turn) is no longer trailing, and a committed round (think-more /
  /// use-this set `content`) is no longer empty — both fall out of
  /// live-candidacy and render as read-only history. Keying on "trailing" rather
  /// than "the last content-empty round" is what closes the pick-then-abandon
  /// hole, where an empty-but-superseded round used to stay falsely live.
  public static func liveRoundID(in messages: [Message]) -> UUID? {
    guard let last = messages.sorted(by: Message.transcriptPrecedes).last,
          last.bestOfN != nil, last.content.isEmpty else { return nil }
    return last.id
  }

  /// Candidate snapshot names of every UNCOMMITTED Best-of-N round among
  /// `messages` — a round whose message has no committed content but carries a
  /// decodable pick set. These are the snapshots a no-next-round terminal
  /// (abandon, profile swap, chat delete) must release so they don't orphan on
  /// the engine. The single source of the "what to release" predicate (#690).
  public static func uncommittedCandidateSnapshotNames(in messages: [Message]) -> [String] {
    messages.flatMap { message -> [String] in
      guard message.content.isEmpty,
            let data = message.bestOfN,
            let round = try? JSONDecoder().decode(BestOfNRound.self, from: data)
      else { return [] }
      return round.candidates.map(\.snapshotName)
    }
  }
}
