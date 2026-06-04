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

  private var isExpanded: Bool { userExpanded ?? !answerStarted }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Button {
        userExpanded = !isExpanded
      } label: {
        HStack(spacing: 4) {
          Image(systemName: "point.3.connected.trianglepath.dotted")
          Text("Tree search")
            .fontWeight(.medium)
          Text(summary)
            .foregroundStyle(.tertiary)
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

  /// "3×2, beam 2 · searching…" / "· 9 nodes" / "· no answer" / "failed".
  private var summary: String {
    var parts: [String] = []
    if let b = tree.breadth, let d = tree.depth, let w = tree.beamWidth {
      parts.append("\(b)×\(d), beam \(w)")
    }
    switch tree.status {
    case .idle, .searching:
      parts.append("searching…")
    case .complete:
      parts.append(tree.selectedNode != nil ? "\(tree.nodes.count) nodes" : "no answer")
    case .failed:
      parts.append("failed")
    }
    return parts.isEmpty ? "" : "· " + parts.joined(separator: " · ")
  }
}

/// One node in the tree-search disclosure, recursing into its children
/// (indented). Shows the beam state (kept / pruned / pending), the value
/// score, and a content preview; the selected final leaf is starred.
private struct ToTNodeRow: View {
  let tree: ToTTree
  let node: ToTTree.Node

  private var isSelected: Bool { tree.selectedNodeID == node.id }
  private var isPruned: Bool { node.beam == .pruned }

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        beamGlyph
        scoreBadge
        Text(preview)
          .font(.caption.monospaced())
          .foregroundStyle(isPruned ? .tertiary : .secondary)
          .lineLimit(3)
          .strikethrough(isPruned, color: .secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .textSelection(.enabled)
      }
      ForEach(tree.children(of: node.id)) { child in
        ToTNodeRow(tree: tree, node: child)
          .padding(.leading, 14)
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

  /// Score capsule: the 1–10 value, "err" for a failed node, "—" when the
  /// scorer returned nothing parseable.
  @ViewBuilder private var scoreBadge: some View {
    let (text, tint): (String, Color) = {
      if node.status == .error { return ("err", .red) }
      if let s = node.score { return ("\(s)", .accentColor) }
      return ("—", .secondary)
    }()
    Text(text)
      .font(.caption2.monospacedDigit())
      .foregroundStyle(tint)
      .frame(minWidth: 20)
      .padding(.horizontal, 4)
      .padding(.vertical, 1)
      .background(tint.opacity(0.12), in: Capsule())
  }

  /// One-line content preview. An error node shows its diagnostic; an
  /// empty (pending) node shows a placeholder.
  private var preview: String {
    if node.status == .error {
      return node.error ?? "generation failed"
    }
    let trimmed = node.content.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "…" : trimmed
  }
}
