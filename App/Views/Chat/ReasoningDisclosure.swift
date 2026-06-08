import SwiftUI

/// A collapsible "Thinking" disclosure for a model's `<think>` reasoning,
/// shared by the chat answer bubble (#329) and every tree-of-thought node
/// (#413/#437). The reasoning IS shown — never stripped — just organized
/// behind a fold.
///
/// Expansion policy: auto-expanded while reasoning is the only thing present
/// (no answer yet — a still-thinking or an incomplete/truncated node), auto-
/// folds once the answer lands, and a manual toggle wins for the view's
/// lifetime. Folded by default when a finished turn reloads from disk.
///
/// Reasoning renders as plain monospaced (secondary) text — an internal
/// scratchpad, not authored prose — and is absent from the view tree when
/// collapsed so a copy of the answer can't pull it in.
struct ReasoningDisclosure: View {
  let reasoning: String
  /// Whether the owning turn/node has produced its answer yet. Drives the
  /// auto fold: reasoning shows while this is false, folds once it is true.
  let answerStarted: Bool
  var title: String = "Thinking"
  var icon: String = "brain"
  var labelFont: Font = .caption
  var bodyFont: Font = .caption.monospaced()
  @State private var userExpanded: Bool?

  private var isExpanded: Bool { userExpanded ?? !answerStarted }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Button {
        userExpanded = !isExpanded
      } label: {
        HStack(spacing: 4) {
          Image(systemName: icon)
          Text(title)
            .fontWeight(.medium)
          Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
        }
        .font(labelFont)
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(isExpanded ? "Hide the model's reasoning" : "Show the model's reasoning")

      if isExpanded {
        Text(reasoning)
          .font(bodyFont)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
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
}
