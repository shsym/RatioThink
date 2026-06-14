import SwiftUI

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
  @State private var userExpanded: Bool?
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
          Image(systemName: "point.3.connected.trianglepath.dotted")
          Text("Tree search")
            .fontWeight(.medium)
          Text(boundsPrefix)
            .foregroundStyle(.tertiary)
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
            ToTNodeRow(tree: tree, node: node)
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
  @State private var userExpanded: Bool?

  private var isSelected: Bool { tree.selectedNodeID == node.id }
  private var isPruned: Bool { node.beam == .pruned }
  private var children: [ToTTree.Node] { tree.children(of: node.id) }
  private var answer: String {
    node.content.trimmingCharacters(in: .whitespacesAndNewlines)
  }
  private var hasAnswer: Bool { !answer.isEmpty }
  // Expanded by default so the full tree is visible as it streams; a manual
  // fold sticks. Folded reload is handled one level up by the "Tree search"
  // section itself, which starts collapsed for a finished turn.
  private var isExpanded: Bool { userExpanded ?? true }
  private var hasDetail: Bool {
    !node.reasoning.isEmpty || hasAnswer || node.status == .error
      || node.status == .incomplete || !children.isEmpty
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Button {
        userExpanded = !isExpanded
      } label: {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          beamGlyph
          scoreBadge
          Text(headline)
            .font(.caption.monospaced())
            .foregroundStyle(isPruned ? .tertiary : .secondary)
            .lineLimit(1)
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
      .help(isExpanded ? "Collapse this branch" : "Expand this branch")

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
