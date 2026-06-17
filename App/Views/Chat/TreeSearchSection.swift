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
  /// Node ids the user may pick (the engine-saved candidates). Empty for a
  /// read-only (historical/finalized) round.
  var pickableIDs: Set<String>
  /// The chosen node id, or nil while awaiting a choice.
  var chosenID: String?
  /// Interactive iff this is the LIVE round (the one `TranscriptView` wires
  /// `onBestOfN` for). Live: every candidate stays pickable so the user can
  /// freely re-pick by tapping another (all snapshots are alive until
  /// think-more/use-this); unpicked rows stay full-strength + readable.
  /// Read-only (false): no pickable rows, no "pick one" state — just highlight
  /// which candidate was chosen and dim the rest (#708).
  var isInteractive: Bool
  /// Invoked with a candidate's node id when the user picks (or re-picks) it.
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
      // Stable handle for the seated GUI test to (re-)expand a Best-of-N round
      // — e.g. a finalized read-only round, which auto-folds once committed.
      .modifier(OptionalAccessibilityIdentifier(id: isBestOfN ? "bestofn.disclosure" : nil))

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
        // Read-only history: never prompt "pick one" — just note the outcome.
        if !selection.isInteractive { return selection.hasChoice ? "chosen" : "options" }
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
  private var isInteractive: Bool { selection?.isInteractive ?? false }
  private var isPickable: Bool { selection?.pickableIDs.contains(node.id) ?? false }
  private var isChosen: Bool { selection?.chosenID == node.id }
  private var hasChoice: Bool { selection?.hasChoice ?? false }
  /// An unpicked candidate in a READ-ONLY (historical/finalized) round: collapse
  /// + dim it so the chosen one stands out. On the live round nothing dims —
  /// every candidate stays full-strength and re-pickable until think-more/use-
  /// this (#708 click-to-reselect).
  private var isDimmed: Bool { hasChoice && !isChosen && !isInteractive }
  /// True when tapping the WHOLE card PICKS this candidate (#708 native
  /// tap-to-select + click-to-reselect): a pickable candidate on the live round
  /// that is NOT the current choice. The chosen card is excluded so its answer
  /// text becomes drag-selectable (you committed to reading it); re-selection is
  /// tapping a DIFFERENT, still-pickable card. Read-only rows are never pick
  /// targets (text always selectable, tap toggles expand).
  private var isPickAction: Bool { isInteractive && isPickable && !isChosen }
  /// Help text for the row's single tap action — pick vs expand/collapse.
  private var rowActionHelp: String {
    if isPickAction { return "Pick this answer" }
    return isExpanded ? "Collapse this branch" : "Expand this branch"
  }
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
      // The answer card — header + (when expanded) the answer detail + child
      // subtree. For a chosen Best-of-N candidate this carries the accent
      // highlight. A Best-of-N candidate's reasoning is deliberately NOT in
      // here; it renders below, outside the accent fill (#708 C).
      //
      // #708 click-to-select: a live pickable candidate makes the WHOLE card
      // (header AND answer body) one pick Button, and its answer text is NOT
      // selectable — so a tap anywhere on the card picks rather than starting a
      // text drag. Once chosen / in read-only history the card is no longer a
      // pick target: the header toggles expand and the answer text becomes
      // drag-selectable (resolves the pick-vs-copy conflict).
      Group {
        if isPickAction {
          Button { selection?.onPick(node.id) } label: {
            cardStack(answerSelectable: false, headerTogglesExpand: false)
              // The WHOLE card rectangle is the hit area (#708) — without this
              // only the opaque glyph/text glyphs are tappable, so a click on a
              // gap (or the answer text) between them is dropped and the pick
              // (or re-pick) silently no-ops. `.contentShape` makes the full
              // card, including the answer body, the pick target.
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .frame(maxWidth: .infinity, alignment: .leading)
          .help(rowActionHelp)
          .modifier(OptionalAccessibilityIdentifier(
            id: isBestOfN ? "bestofn.option.\(node.branchIndex ?? 0)" : nil))
        } else {
          cardStack(answerSelectable: true, headerTogglesExpand: true)
        }
      }
      // Chosen candidate: accent-tinted card + accent border. Unpicked-after-
      // choice (read-only history only): alpha dim. Both use semantic
      // `Color.accentColor` / opacity, which adapt across light + dark — never
      // a hardcoded lightness (#690).
      //
      // #708 layout stability: every Best-of-N candidate reserves the SAME 8pt
      // inset (not `isChosen ? 8 : 0`), so the accent card only fades in/out as
      // the choice moves between candidates (click-to-reselect) — the rows never
      // change geometry or shove their siblings. (The green-checkmark selection
      // FLASH itself was a separate bug — candidates rendering as tree-of-thought
      // `kept` beam nodes before `bestOfN` was set — fixed at the source in
      // `ChatSendController.sendBestOfN`.)
      .padding(isBestOfN ? 8 : (isChosen ? 8 : 0))
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

      // #708 C — thinking presentation: a Best-of-N candidate's reasoning uses
      // the SAME boxed brain-icon disclosure tree-of-thought uses, but rendered
      // BELOW the answer card on the plain surface (never under the chosen
      // accent fill) and pushed to `.tertiary` (`deEmphasized`) so the thinking
      // is unmistakably subordinate to the `.primary` answer — `.secondary` read
      // too close to the answer on a chosen card. It also folds by default once
      // an answer exists (`answerStarted: hasAnswer`). Absent entirely when there
      // is no reasoning — no empty box.
      if isBestOfN, isExpanded, !node.reasoning.isEmpty {
        ReasoningDisclosure(
          reasoning: node.reasoning,
          answerStarted: hasAnswer,
          labelFont: .caption2,
          bodyFont: .caption2.monospaced(),
          deEmphasized: true
        )
        .padding(.leading, 8)
        // Stable handle for the seated GUI test (#708): with thinking ON each
        // candidate carries reasoning, so this folded "Thinking" disclosure
        // renders next to the clean answer.
        .accessibilityIdentifier("bestofn.candidate.\(node.branchIndex ?? 0).thinking")
      }
    }
    .opacity(isDimmed ? 0.5 : 1.0)
    .animation(.easeInOut(duration: 0.18), value: hasChoice)
    // Stable identity + a semantic state value for the Best-of-N selection GUI
    // test (#690): the chosen-vs-unpicked EMPHASIS is built from adaptive color
    // (asserted for light/dark by the ImageRenderer snapshot test), which
    // XCUITest cannot read — so the row also exposes its state as an
    // accessibility value the seated test can assert (`chosen` highlighted,
    // `unpicked` dimmed in read-only history, `pickable`/re-pickable on the
    // live round). Empty on a tree-of-thought node, not a Best-of-N candidate.
    // Selection-state probe for the seated GUI test (#690). A dedicated,
    // non-interactive marker in an OVERLAY (zero layout impact) encodes the
    // row's state INTO its accessibility identifier (`bestofn.candidate.<i>.
    // pickable` → `.chosen` / `.unpicked`) — the assertable proxy for the
    // adaptive-color emphasis XCUITest cannot see. State is in the identifier,
    // not a value, because XCUITest reliably matches identifiers but does not
    // surface `accessibilityValue` on a trait-less element. Kept OUT of the
    // row's interactive subtree so it neither combines with nor hides the
    // tappable option row (`bestofn.option.<i>`, the pick/expand target since
    // #708 dropped the per-option Select button). Only on a candidate row.
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
  ///  - `chosen`: the picked candidate (accent-highlighted).
  ///  - `unpicked`: a non-chosen candidate in a READ-ONLY round (dimmed).
  ///  - `pickable`: a candidate on the LIVE round — selectable AND re-selectable,
  ///    so siblings stay `pickable` even after a choice (#708 click-to-reselect).
  ///  - `unavailable`: a read-only round with no recorded choice.
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
  /// rendered tag-soup. `selectable` is false while the whole card is a pick
  /// target (#708), so a tap on the answer body picks instead of starting a
  /// text drag; true once the card is no longer pickable (drag-to-copy).
  @ViewBuilder private func detail(selectable: Bool) -> some View {
    switch node.status {
    case .error:
      Text(node.error ?? "generation failed")
        .font(.caption2)
        .foregroundStyle(.red)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelectable(selectable)
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
          .textSelectable(selectable)
      }
    }
  }

  /// The card's header line — option/beam glyph + headline + (when this is not a
  /// pick target) an expand chevron. Plain content; the enclosing `cardStack`
  /// decides whether it sits inside a pick Button or an expand-toggle Button.
  @ViewBuilder private var headerRow: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      if isBestOfN {
        optionGlyph
      } else {
        beamGlyph
        scoreBadge
      }
      // The headline is the node's answer (`headline` returns `answer` when one
      // exists). A tree-of-thought node shows it `lineLimit 1` as a title above
      // its full-answer detail. A Best-of-N candidate, expanded by default,
      // renders its full answer in `detail()` below — so repeating the answer
      // here would show it TWICE on the card. Suppress the headline text for an
      // expanded Best-of-N candidate (detail owns the answer); keep it as the
      // preview when the candidate is FOLDED (read-only history), where detail
      // is hidden and the header is the only place the answer can show.
      if !(isBestOfN && isExpanded) {
        Text(headline)
          .font(.caption.monospaced())
          .foregroundStyle(headlineTint)
          .lineLimit(isBestOfN && !isDimmed ? 3 : 1)
          .strikethrough(isPruned, color: .secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        // Keep the header full-width so the glyph stays left-aligned and the
        // whole card rectangle remains the pick/expand hit target.
        Spacer(minLength: 0)
      }
      // No chevron while the card is a pick target — a live pickable candidate
      // is always shown expanded and the only affordance is "tap to pick".
      if hasDetail, !isPickAction {
        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
    }
    .contentShape(Rectangle())
  }

  /// The answer card's content: header + (when expanded) the answer detail and
  /// child subtree. When `headerTogglesExpand` the header is its own toggle
  /// Button (carrying the `bestofn.option.<i>` id for the seated test);
  /// otherwise the header is plain content inside the enclosing pick Button.
  @ViewBuilder private func cardStack(answerSelectable: Bool, headerTogglesExpand: Bool) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      if headerTogglesExpand {
        Button { userExpanded = !isExpanded } label: { headerRow }
          .buttonStyle(.plain)
          .frame(maxWidth: .infinity, alignment: .leading)
          .help(rowActionHelp)
          .modifier(OptionalAccessibilityIdentifier(
            id: isBestOfN ? "bestofn.option.\(node.branchIndex ?? 0)" : nil))
      } else {
        headerRow
      }

      if isExpanded {
        // Tree-of-thought keeps its reasoning inline above the answer (#329/
        // #413, unchanged). A Best-of-N candidate's reasoning is moved out of
        // this card (rendered below) so the chosen accent fill never washes it.
        if !isBestOfN, !node.reasoning.isEmpty {
          ReasoningDisclosure(
            reasoning: node.reasoning,
            answerStarted: hasAnswer,
            labelFont: .caption2,
            bodyFont: .caption2.monospaced()
          )
          .padding(.leading, 4)
        }
        detail(selectable: answerSelectable)
          .padding(.leading, 4)
        ForEach(children) { child in
          ToTNodeRow(tree: tree, node: child)
            .padding(.leading, 14)
        }
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

  /// Score capsule: a live "Scoring…" indicator while the value scorer runs
  /// (content done, score not yet landed — the gap can be several seconds),
  /// then the 1–10 value, "err" for a failed node, "…" for an incomplete
  /// (reasoned-but-unanswered) node, "—" when the scorer returned nothing
  /// parseable.
  @ViewBuilder private var scoreBadge: some View {
    if node.livePhase == .scoring {
      HStack(spacing: 3) {
        ProgressView().controlSize(.mini)
        Text("Scoring…").font(.caption2)
      }
      .foregroundStyle(.secondary)
      .padding(.horizontal, 4)
      .padding(.vertical, 1)
      .background(Color.secondary.opacity(0.12), in: Capsule())
      .help("Generating this node's value score")
    } else {
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

private extension View {
  /// Enables or disables text selection — `.textSelection(.enabled)` and
  /// `.textSelection(.disabled)` have different result types, so a ternary
  /// cannot pick between them; this branches at the modifier level instead.
  @ViewBuilder func textSelectable(_ enabled: Bool) -> some View {
    if enabled { textSelection(.enabled) } else { textSelection(.disabled) }
  }
}

/// Applies an `accessibilityIdentifier` only when one is provided, leaving a
/// tree-of-thought node's row untouched (it carries no Best-of-N identity).
private struct OptionalAccessibilityIdentifier: ViewModifier {
  let id: String?
  func body(content: Content) -> some View {
    if let id {
      content.accessibilityIdentifier(id)
    } else {
      content
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
  // n1 carries a reasoning trace so the chosen-card "thinking vs answer"
  // contrast (#708 C) is visible; the others have none (thinking is OFF for the
  // best-of-n profile by default, #679 — the no-reasoning rows must show no box).
  let reasoning = ["", "They want low-effort but memorable; an owner makes it stick.", ""]
  for (i, a) in answers.enumerated() {
    tree.apply(.nodeComplete(ToTNode(
      id: "n\(i)", parentID: "root", depth: 1, branchIndex: i,
      content: a, reasoning: reasoning[i], score: nil, status: .ok)))
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
/// picking from the no-choice state. `interactive` toggles the live (re-pickable,
/// nothing dimmed) vs read-only (chosen highlighted, rest dimmed) presentation.
struct BestOfNHighlightPreviewHarness: View {
  @State var chosenID: String? = "n1"
  var interactive: Bool = true
  var body: some View {
    TreeSearchSection(
      tree: bestOfNDemoTree(),
      answerStarted: false,
      selection: BestOfNSelectionContext(
        pickableIDs: interactive ? ["n0", "n1", "n2"] : [],
        chosenID: chosenID,
        isInteractive: interactive,
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

#Preview("Best-of-N read-only history") {
  BestOfNHighlightPreviewHarness(interactive: false).preferredColorScheme(.dark)
}
#endif
