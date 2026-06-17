import Foundation

/// Pure, value-type accumulator for a live tree-of-thought search (#413).
///
/// A controller folds the [`ToTEvent`] stream into this struct (`apply`)
/// and the SwiftUI tree view renders from it; keeping it pure means the
/// whole live-search behavior — nodes appearing, scores landing, a level
/// pruning to its beam, the terminal selection — is unit-tested with no
/// engine, no actor, and no view.
///
/// Nodes are stored flat in arrival order (the wire streams them flat);
/// the view assembles the hierarchy via [`children(of:)`], exactly as the
/// non-streaming server does from `parent_id`. The synthetic `"root"`
/// prefix is never streamed, so the visible roots are the depth-1 nodes
/// ([`rootChildren`]).
///
/// `Codable` so a completed search persists into `Message.tot` and a
/// reloaded transcript re-renders the tree (beam highlighting included).
/// The on-disk shape is an app-internal store format, not a wire contract;
/// the renderer tolerates a decode failure (treats it as no tree).
public struct ToTTree: Equatable, Sendable, Codable {

  /// Where a node sits relative to its level's beam selection. `String`
  /// raw value so it round-trips stably through the persisted snapshot.
  public enum BeamState: String, Equatable, Sendable, Codable {
    /// Its level has not been pruned yet (still streaming / scoring).
    case pending
    /// Kept by the beam — survived as the next frontier.
    case kept
    /// Generated but pruned (did not make the top-`beam_width`).
    case pruned
  }

  /// Overall search lifecycle, mirroring the stream's terminal contract.
  public enum Status: Equatable, Sendable, Codable {
    /// No `tree_start` yet.
    case idle
    /// `tree_start` seen; nodes/levels streaming.
    case searching
    /// `tree_complete` seen — terminal success.
    case complete
    /// The stream threw (an `error` frame or a transport failure).
    case failed(String)
  }

  /// Live presentation phase of a node as the stream folds in (#413). Distinct
  /// from the wire `ToTNodeStatus` (the authoritative ok/error/incomplete on
  /// `nodeComplete`): this tracks where the node is in the generate → score →
  /// finalize lifecycle so the row can show "Scoring…" during the value-scorer
  /// gap. A persisted (finished) tree decodes every node as `.complete`.
  public enum LivePhase: String, Equatable, Sendable, Codable {
    /// Streaming its content (after `nodeStart`, during `nodeDelta`).
    case generating
    /// Content done; the value scorer is generating (after `nodeScoring`,
    /// before `nodeComplete`).
    case scoring
    /// Reconciled by `nodeComplete` — authoritative score/status landed.
    case complete
  }

  /// One node in the live tree: the wire node plus its beam state.
  public struct Node: Equatable, Sendable, Identifiable, Codable {
    public let id: String
    public let parentID: String?
    public let depth: Int
    public let branchIndex: Int?
    public var content: String
    /// The node's demuxed `<think>` reasoning trace (#413/#437), separated
    /// from `content` (the answer) by the engine. Empty for a non-reasoning
    /// model or a `thinking:false` search.
    public var reasoning: String
    public var score: Int?
    public var status: ToTNodeStatus
    public var error: String?
    public var scoreError: String?
    public var beam: BeamState
    /// Live generate → score → finalize phase (#413). Not a wire field; set by
    /// `apply` from the `nodeStart`/`nodeScoring`/`nodeComplete` events.
    public var livePhase: LivePhase

    init(_ n: ToTNode, beam: BeamState = .pending, livePhase: LivePhase = .complete) {
      self.id = n.id
      self.parentID = n.parentID
      self.depth = n.depth
      self.branchIndex = n.branchIndex
      self.content = n.content
      self.reasoning = n.reasoning
      self.score = n.score
      self.status = n.status
      self.error = n.error
      self.scoreError = n.scoreError
      self.beam = beam
      self.livePhase = livePhase
    }

    enum CodingKeys: String, CodingKey {
      case id, parentID, depth, branchIndex, content, reasoning
      case score, status, error, scoreError, beam, livePhase
    }

    // Custom decode so a ToTTree persisted before `reasoning` existed still
    // loads (the field defaults to empty) instead of failing the whole tree
    // — the renderer treats a decode failure as no tree, so a required new
    // key would silently drop a reloaded search. Encode stays synthesized.
    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      self.id = try c.decode(String.self, forKey: .id)
      self.parentID = try c.decodeIfPresent(String.self, forKey: .parentID)
      self.depth = try c.decode(Int.self, forKey: .depth)
      self.branchIndex = try c.decodeIfPresent(Int.self, forKey: .branchIndex)
      self.content = try c.decode(String.self, forKey: .content)
      self.reasoning = try c.decodeIfPresent(String.self, forKey: .reasoning) ?? ""
      self.score = try c.decodeIfPresent(Int.self, forKey: .score)
      self.status = try c.decode(ToTNodeStatus.self, forKey: .status)
      self.error = try c.decodeIfPresent(String.self, forKey: .error)
      self.scoreError = try c.decodeIfPresent(String.self, forKey: .scoreError)
      self.beam = try c.decode(BeamState.self, forKey: .beam)
      // A tree persisted before livePhase existed is a FINISHED search, so its
      // nodes are all `.complete` — default accordingly instead of failing the
      // whole tree decode (the renderer treats a decode failure as no tree).
      self.livePhase = try c.decodeIfPresent(LivePhase.self, forKey: .livePhase) ?? .complete
    }
  }

  public private(set) var id: String?
  public private(set) var model: String?
  public private(set) var breadth: Int?
  public private(set) var depth: Int?
  public private(set) var beamWidth: Int?
  public private(set) var nodes: [Node]
  /// Levels whose `level_pruned` has been applied (beam resolved).
  public private(set) var prunedLevels: Set<Int>
  public private(set) var selectedNodeID: String?
  public private(set) var finalAnswer: String?
  public private(set) var status: Status

  public init() {
    self.nodes = []
    self.prunedLevels = []
    self.status = .idle
  }

  /// Fold one stream event into the tree.
  public mutating func apply(_ event: ToTEvent) {
    switch event {
    case let .treeStart(id, model, breadth, depth, beamWidth):
      self.id = id
      self.model = model
      self.breadth = breadth
      self.depth = depth
      self.beamWidth = beamWidth
      self.status = .searching

    case let .nodeStart(id, parentID, depth, branchIndex):
      // #413 token stream: create a provisional node so its deltas have a
      // home and it renders (filling live) before `nodeComplete` finalizes
      // it. Provisional status is `.ok` with empty text + no score; the
      // terminal `nodeComplete` replaces it with the authoritative node.
      if !nodes.contains(where: { $0.id == id }) {
        let provisional = ToTNode(
          id: id, parentID: parentID, depth: depth, branchIndex: branchIndex,
          content: "", reasoning: "", score: nil, status: .ok)
        nodes.append(Node(provisional, livePhase: .generating))
      }

    case let .nodeDelta(id, channel, text):
      // Append the streamed chunk to the live node's reasoning or answer,
      // routed purely by id. Since #650 sibling branches decode concurrently,
      // so different nodes' deltas interleave on the stream — but a node's own
      // start always precedes its own deltas (its branch emits them in order),
      // so a delta with no node yet (dropped here) only ever means a truly
      // malformed stream; nodeComplete backfills the authoritative node anyway.
      guard let idx = nodes.firstIndex(where: { $0.id == id }) else { return }
      switch channel {
      case .reasoning: nodes[idx].reasoning += text
      case .answer: nodes[idx].content += text
      }

    case let .nodeScoring(id):
      // Content finished; the value scorer is now generating. Flip the live
      // node to `.scoring` so the row shows a transient "Scoring…" indicator
      // until `nodeComplete` reconciles the authoritative score. A scoring
      // frame for an unknown id (truly malformed) is ignored — nodeComplete
      // backfills the node regardless.
      guard let idx = nodes.firstIndex(where: { $0.id == id }) else { return }
      nodes[idx].livePhase = .scoring

    case let .nodeComplete(wire):
      let node = Node(wire)
      // A node id is unique per response; replace on the off chance the
      // same id streams twice (and to reconcile a provisional node + its
      // streamed deltas to the authoritative final) rather than duplicate.
      if let idx = nodes.firstIndex(where: { $0.id == node.id }) {
        nodes[idx] = node
      } else {
        nodes.append(node)
      }

    case let .levelPruned(level, kept):
      let keptIDs = Set(kept)
      for i in nodes.indices where nodes[i].depth == level {
        nodes[i].beam = keptIDs.contains(nodes[i].id) ? .kept : .pruned
      }
      prunedLevels.insert(level)

    case let .finalDelta(text):
      // #523 Part A: accumulate the streamed synthesized answer live; the
      // terminal `treeComplete` overwrites it with the authoritative full
      // text (so a dropped/again-set value can't diverge).
      self.finalAnswer = (self.finalAnswer ?? "") + text

    case let .treeComplete(selectedNodeID, finalAnswer):
      self.selectedNodeID = selectedNodeID
      self.finalAnswer = finalAnswer
      self.status = .complete

    case .generationMetrics:
      // Metrics live on Message.meta, not inside the persisted tree snapshot.
      break

    case .awaitingSelection:
      // Best-of-N (#690): the round finished generating; the user now picks.
      // The pickable set + level live on `Message.bestOfN` (captured by the
      // send controller), not in this shared tree snapshot — here we only mark
      // the search done so the streaming UI settles out of `.searching`.
      self.status = .complete
    }
  }

  /// Mark the search failed (the stream threw). Idempotent terminal.
  public mutating func fail(_ message: String) {
    // Any accumulated `finalDelta` text is optimistic synthesis output, not
    // an authoritative final answer. Once the terminal state is failed, do
    // not persist that partial text in `finalAnswer`.
    self.finalAnswer = nil
    self.status = .failed(message)
  }

  // MARK: - Rendering helpers

  /// Children of `parentID`, ordered by `(branchIndex, id)` for stable
  /// display — the same order the non-streaming server assembles.
  public func children(of parentID: String) -> [Node] {
    nodes
      .filter { $0.parentID == parentID }
      .sorted { lhs, rhs in
        let l = lhs.branchIndex ?? 0
        let r = rhs.branchIndex ?? 0
        return l == r ? lhs.id < rhs.id : l < r
      }
  }

  /// The visible tree roots: depth-1 nodes (children of the synthetic,
  /// never-streamed `"root"` prefix).
  public var rootChildren: [Node] {
    children(of: "root")
  }

  /// The node the search selected as its final answer, if any.
  public var selectedNode: Node? {
    guard let selectedNodeID else { return nil }
    return nodes.first { $0.id == selectedNodeID }
  }
}
