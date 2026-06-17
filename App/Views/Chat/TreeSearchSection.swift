import SwiftUI

/// Best-of-N selection affordance (#690) layered onto the reused tree view.
/// When passed to `TreeSearchSection`, each pickable root candidate gets a
/// Select control; once the user chooses one, the unpicked candidates collapse
/// + dim and the chosen one is accent-highlighted.
///
/// All emphasis is semantic/adaptive: `Color.accentColor` (the system accent,
/// adapts to appearance), `.primary` / `.secondary`, and alpha-based dimming —
/// never a hardcoded lightness, which would invert between light and dark.
struct BestOfNSelectionContext {
  /// Node ids the user may pick (the engine-saved candidates).
  var pickableIDs: Set<String>
  /// The chosen node id, or nil while awaiting a choice.
  var chosenID: String?
  /// Invoked with a candidate's node id when the user picks it.
  var onPick: (String) -> Void

  var hasChoice: Bool { chosenID != nil }
}

/// Collapsible "Tree search" disclosure for a tree-of-thought turn (#413)
/// — the structured analogue of `MessageBubble`'s `ThinkingSection`. As
/// the search streams it shows each level's branches appearing, their
/// scores landing, and the beam keeping the top candidates; the selected
/// final leaf is starred.
///
/// Expansion policy mirrors the Thinking section: auto-expanded while the
/// search runs (no answer yet), auto-folds once the final answer arrives,
/// and a manual toggle wins for the turn's lifetime so a user watching the
/// search keeps it open past completion. Folded by default when a
/// finished turn is reloaded from disk.
struct TreeSearchSection: View {
  let tree: ToTTree
  let answerStarted: Bool
  /// Best-of-N selection affordance (#690). Nil for an ordinary tree-of-thought
  /// turn (read-only tree); non-nil turns each root candidate into a pickable
  /// option with adaptive-highlight selection.
  var selection: BestOfNSelectionContext? = nil
  @State private var userExpanded: Bool?

  private var isBestOfN: Bool { selection != nil }
  /// Drives the slow breathing of the "searching…" label while the search
  /// runs. Toggled true on enter-search so the repeat-forever animation
  /// kicks; settles back when the search leaves `.searching`.
  @State private var breathe = false

  private var isExpanded: Bool { userExpanded ?? !answerStarted }

  /// True only while the search is actively streaming levels.
  private var isSearching: Bool {
    if case .searching = tree.status { return true }
    return false
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Button {
        userExpanded = !isExpanded
      } label: {
        HStack(spacing: 4) {
          Image(systemName: isBestOfN ? "square.grid.2x2" : "point.3.connected.trianglepath.dotted")
          Text(isBestOfN ? "Options" : "Tree search")
            .fontWeight(.medium)
          if !isBestOfN {
            Text(boundsPrefix)
              .foregroundStyle(.tertiary)
          }
          // The status word breathes (1.0 ↔ 0.4) while searching, then
          // settles opaque the moment the answer lands or the search fails.
          Text(statusWord)
            .foregroundStyle(.tertiary)
            .opacity(isSearching && breathe ? 0.4 : 1.0)
            .animation(
              isSearching
                ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true)
                : .easeInOut(duration: 0.25),
              value: breathe
            )
            .onAppear { breathe = isSearching }
            .onChange(of: isSearching) { _, searching in breathe = searching }
          Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(isExpanded ? "Hide the tree-of-thought search" : "Show the tree-of-thought search")

      if isExpanded {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(tree.rootChildren) { node in
            ToTNodeRow(tree: tree, node: node, selection: selection)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
          Color.secondary.opacity(0.08),
          in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .animation(.easeInOut(duration: 0.15), value: isExpanded)
  }

  /// The static bounds prefix shown before the (separately-pulsed) status
  /// word: "· 3×2, beam 2 ·", or just "·" before `tree_start` echoes bounds.
  private var boundsPrefix: String {
    guard let b = tree.breadth, let d = tree.depth, let w = tree.beamWidth else { return "·" }
    return "· \(b)×\(d), beam \(w) ·"
  }

  /// The status word, rendered as its own Text so only it breathes while
  /// searching: "searching…" / "9 nodes" / "no answer" / "failed".
  private var statusWord: String {
    if let selection {
      switch tree.status {
      case .idle, .searching:
        return "generating…"
      case .complete:
        return selection.hasChoice ? "chosen" : "pick one"
      case .failed:
        return "failed"
      }
    }
    switch tree.status {
    case .idle, .searching:
      return "searching…"
    case .complete:
      return tree.selectedNode != nil ? "\(tree.nodes.count) nodes" : "no answer"
    case .failed:
      return "failed"
    }
  }
}

/// One node in the tree-search disclosure, recursing into its children
/// (indented) for a foldable tree nested by depth (#413). The header shows
/// the beam state (kept / pruned / pending / starred selection) and the
/// value score; tapping it folds the node's detail + subtree. When expanded
/// the node shows its FULL output: the demuxed `<think>` reasoning behind a
/// per-node `ReasoningDisclosure` (#329 style) plus the answer — and, for a
/// node that reasoned but never answered, an honest "incomplete" note over
/// whatever partial reasoning exists rather than broken tag-soup (#434/#437).
private struct ToTNodeRow: View {
  let tree: ToTTree
  let node: ToTTree.Node
  /// Best-of-N selection context (#690); nil for a read-only tree-of-thought
  /// node.
  var selection: BestOfNSelectionContext? = nil
  @State private var userExpanded: Bool?

  private var isSelected: Bool { tree.selectedNodeID == node.id }
  private var isPruned: Bool { node.beam == .pruned }

  // MARK: Best-of-N selection state (#690)
  private var isBestOfN: Bool { selection != nil }
  private var isPickable: Bool { selection?.pickableIDs.contains(node.id) ?? false }
  private var isChosen: Bool { selection?.chosenID == node.id }
  private var hasChoice: Bool { selection?.hasChoice ?? false }
  /// An unpicked candidate after the user has chosen: collapse + dim it.
  private var isDimmed: Bool { hasChoice && !isChosen }
  private var children: [ToTTree.Node] { tree.children(of: node.id) }
  private var answer: String {
    node.content.trimmingCharacters(in: .whitespacesAndNewlines)
  }
  private var hasAnswer: Bool { !answer.isEmpty }
  // Expanded by default so the full tree is visible as it streams; a manual
  // fold sticks. Folded reload is handled one level up by the "Tree search"
  // section itself, which starts collapsed for a finished turn.
  private var isExpanded: Bool {
    // An unpicked candidate collapses once a choice is made (the chosen one
    // and pre-choice candidates expand by default as they stream).
    if isDimmed { return userExpanded ?? false }
    return userExpanded ?? true
  }
  private var hasDetail: Bool {
    !node.reasoning.isEmpty || hasAnswer || node.status == .error
      || node.status == .incomplete || !children.isEmpty
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        // Expand/collapse toggle. Holds only the glyph + headline + chevron —
        // the Select affordance is a SIBLING (below), never nested inside this
        // Button: a Button inside a Button both fires the toggle on a Select tap
        // AND hides Select from the accessibility tree (it gets absorbed into
        // the outer element), so Select must stand on its own.
        Button {
          userExpanded = !isExpanded
        } label: {
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            if isBestOfN {
              optionGlyph
            } else {
              beamGlyph
              scoreBadge
            }
            Text(headline)
              .font(.caption.monospaced())
              .foregroundStyle(headlineTint)
              .lineLimit(isBestOfN && !isDimmed ? 3 : 1)
              .strikethrough(isPruned, color: .secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
            if hasDetail {
              Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(isExpanded ? "Collapse this branch" : "Expand this branch")

        // The Select affordance — only before a choice is made, only for a
        // pickable (engine-saved) candidate. `borderedProminent` paints in the
        // system accent (adaptive). Sibling of the toggle so it is its own tap
        // target + its own accessibility element.
        if let selection, isPickable, !hasChoice {
          Button("Select") { selection.onPick(node.id) }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityIdentifier("bestofn.select.\(node.branchIndex ?? 0)")
        }
      }

      if isExpanded {
        // The node's reasoning — shown, never stripped, folded behind the
        // same disclosure the chat answer uses (#329). Auto-expands for an
        // unanswered (incomplete) node so its partial thought is visible.
        if !node.reasoning.isEmpty {
          ReasoningDisclosure(
            reasoning: node.reasoning,
            answerStarted: hasAnswer,
            labelFont: .caption2,
            bodyFont: .caption2.monospaced()
          )
          .padding(.leading, 4)
        }
        detail
          .padding(.leading, 4)
        ForEach(children) { child in
          ToTNodeRow(tree: tree, node: child)
            .padding(.leading, 14)
        }
      }
    }
    // Chosen candidate: accent-tinted card + accent border. Unpicked-after-
    // choice: alpha dim. Both use semantic `Color.accentColor` / opacity, which
    // adapt across light + dark — never a hardcoded lightness (#690).
    .padding(isChosen ? 8 : 0)
    .background {
      if isChosen {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(Color.accentColor.opacity(0.12))
      }
    }
    .overlay {
      if isChosen {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1)
      }
    }
    .opacity(isDimmed ? 0.5 : 1.0)
    .animation(.easeInOut(duration: 0.18), value: hasChoice)
    // Stable identity + a semantic state value for the Best-of-N selection GUI
    // test (#690): the chosen-vs-unpicked EMPHASIS is built from adaptive color
    // (asserted for light/dark by the ImageRenderer snapshot test), which
    // XCUITest cannot read — so the row also exposes its state as an
    // accessibility value the seated test can assert (`chosen` highlighted,
    // `unpicked` collapsed/dimmed, `pickable` before a choice). Empty on a
    // tree-of-thought node, which is not a Best-of-N candidate.
    // Selection-state probe for the seated GUI test (#690). A dedicated,
    // non-interactive marker in an OVERLAY (zero layout impact) encodes the
    // row's state INTO its accessibility identifier (`bestofn.candidate.<i>.
    // pickable` → `.chosen` / `.unpicked`) — the assertable proxy for the
    // adaptive-color emphasis XCUITest cannot see. State is in the identifier,
    // not a value, because XCUITest reliably matches identifiers but does not
    // surface `accessibilityValue` on a trait-less element. Kept OUT of the
    // row's interactive subtree so it neither combines with nor hides the
    // Select button (its own sibling element). Only on a candidate row.
    .overlay(alignment: .topLeading) {
      if isBestOfN {
        Color.clear
          .frame(width: 1, height: 1)
          .accessibilityElement()
          .accessibilityIdentifier("bestofn.candidate.\(node.branchIndex ?? 0).\(bestOfNRowState)")
      }
    }
  }

  /// Best-of-N selection state as a stable string for the seated GUI test —
  /// the assertable proxy for the adaptive-color emphasis. Empty for a
  /// tree-of-thought node (not a candidate).
  private var bestOfNRowState: String {
    guard isBestOfN else { return "" }
    if isChosen { return "chosen" }
    if isDimmed { return "unpicked" }
    if isPickable { return "pickable" }
    return "unavailable"
  }

  /// Glyph for a Best-of-N candidate: an accent check once chosen, else a
  /// hollow circle. (Replaces the tree-of-thought beam/score glyphs, which
  /// carry no meaning without a value scorer.)
  @ViewBuilder private var optionGlyph: some View {
    if isChosen {
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(Color.accentColor)
        .help("Chosen answer")
    } else {
      Image(systemName: "circle")
        .foregroundStyle(.secondary)
        .help(isPickable ? "Pick this answer" : "Unavailable")
    }
  }

  /// Headline tint: the chosen answer reads at full strength (`.primary`); a
  /// dimmed/pruned row recedes (`.tertiary`); everything else is `.secondary`.
  /// All adaptive hierarchical styles.
  private var headlineTint: AnyShapeStyle {
    if isChosen { return AnyShapeStyle(.primary) }
    if isDimmed || isPruned { return AnyShapeStyle(.tertiary) }
    return AnyShapeStyle(.secondary)
  }

  /// The node's answer, or an honest note for a non-`ok` node — never
  /// rendered tag-soup.
  @ViewBuilder private var detail: some View {
    switch node.status {
    case .error:
      Text(node.error ?? "generation failed")
        .font(.caption2)
        .foregroundStyle(.red)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    case .incomplete:
      Text(node.error ?? "Incomplete — the node reasoned but produced no answer.")
        .font(.caption2)
        .italic()
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, alignment: .leading)
    default:
      if hasAnswer {
        Text(answer)
          .font(.caption.monospaced())
          .foregroundStyle(isPruned ? .tertiary : .primary)
          .strikethrough(isPruned, color: .secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .textSelection(.enabled)
      }
    }
  }

  @ViewBuilder private var beamGlyph: some View {
    if isSelected {
      Image(systemName: "star.fill")
        .foregroundStyle(.yellow)
        .help("Selected as the final answer")
    } else {
      switch node.beam {
      case .kept:
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(.green)
          .help("Kept in the beam")
      case .pruned:
        Image(systemName: "xmark.circle")
          .foregroundStyle(.tertiary)
          .help("Pruned")
      case .pending:
        Image(systemName: "circle.dotted")
          .foregroundStyle(.secondary)
          .help("Generated; awaiting beam selection")
      }
    }
  }

  /// Score capsule: the 1–10 value, "err" for a failed node, "…" for an
  /// incomplete (reasoned-but-unanswered) node, "—" when the scorer returned
  /// nothing parseable.
  @ViewBuilder private var scoreBadge: some View {
    let (text, tint): (String, Color) = {
      switch node.status {
      case .error: return ("err", .red)
      case .incomplete: return ("…", .orange)
      default:
        if let s = node.score { return ("\(s)", .accentColor) }
        return ("—", .secondary)
      }
    }()
    Text(text)
      .font(.caption2.monospacedDigit())
      .foregroundStyle(tint)
      .frame(minWidth: 20)
      .padding(.horizontal, 4)
      .padding(.vertical, 1)
      .background(tint.opacity(0.12), in: Capsule())
  }

  /// One-line header preview: the answer's first line, a status word for an
  /// error/incomplete node, or a "thinking…" placeholder.
  private var headline: String {
    switch node.status {
    case .error:
      return node.error ?? "generation failed"
    case .incomplete:
      return "reasoned, no answer"
    default:
      if hasAnswer { return answer }
      return node.reasoning.isEmpty ? "…" : "thinking…"
    }
  }
}

#if DEBUG
/// Visual check for the Best-of-N selection highlight (#690) in BOTH
/// appearances. The chosen candidate must read as accent-emphasized and the
/// unpicked as de-emphasized in light AND dark — the colors are semantic
/// (`Color.accentColor`, `.primary`/`.secondary`/`.tertiary`, alpha dimming),
/// so they adapt rather than invert. Toggle the scheme in the canvas (or render
/// both via `BestOfNHighlightPreviewHarness`) to confirm.
private func bestOfNDemoTree() -> ToTTree {
  var tree = ToTTree()
  tree.apply(.treeStart(id: "bon-1", model: "qwen", breadth: 3, depth: 1, beamWidth: 3))
  let answers = [
    "Start with a tight agenda and a 25-minute timer.",
    "Assign one owner per action item before anyone leaves.",
    "Open with the decision you need, not a status recap.",
  ]
  for (i, a) in answers.enumerated() {
    tree.apply(.nodeComplete(ToTNode(
      id: "n\(i)", parentID: "root", depth: 1, branchIndex: i,
      content: a, score: nil, status: .ok)))
  }
  tree.apply(.levelPruned(level: 1, kept: ["n0", "n1", "n2"]))
  tree.apply(.awaitingSelection(level: 1, candidates: [
    ToTSelectionCandidate(id: "n0", branchIndex: 0, snapshotName: "bon/1/1/0"),
    ToTSelectionCandidate(id: "n1", branchIndex: 1, snapshotName: "bon/1/1/1"),
    ToTSelectionCandidate(id: "n2", branchIndex: 2, snapshotName: "bon/1/1/2"),
  ]))
  return tree
}

/// Renders the section with a candidate already chosen (`n1`) so the highlight
/// + dim are visible. `chosenID` is interactive so the canvas can also exercise
/// picking from the no-choice state.
struct BestOfNHighlightPreviewHarness: View {
  @State var chosenID: String? = "n1"
  var body: some View {
    TreeSearchSection(
      tree: bestOfNDemoTree(),
      answerStarted: false,
      selection: BestOfNSelectionContext(
        pickableIDs: ["n0", "n1", "n2"],
        chosenID: chosenID,
        onPick: { chosenID = $0 }))
      .padding()
      .frame(width: 420)
  }
}

#Preview("Best-of-N highlight — light") {
  BestOfNHighlightPreviewHarness().preferredColorScheme(.light)
}

#Preview("Best-of-N highlight — dark") {
  BestOfNHighlightPreviewHarness().preferredColorScheme(.dark)
}
#endif
