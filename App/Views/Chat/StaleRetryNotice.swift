import SwiftUI

/// Transient in-chat notice for a retry click that no longer applies
/// (#513, review v2 F1). Deliberately its OWN surface with its own
/// state channel: the first cut rode `engineActionError`, whose banner
/// is rendered through `MissingModelRecovery.engineFailureBannerMessage`
/// — that helper shows `statusDetail` instead of the action error for
/// any `.failed` engine status, and the scaffold clears the field on
/// the next engine-status flip. Both rules are correct ENGINE semantics
/// and exactly wrong for a TRANSCRIPT condition: the notice could be
/// shadowed or wiped unread in the very windows it was added for.
/// Rendering from a dedicated value keeps its visibility and lifetime
/// independent of engine state; the owner dismisses it explicitly or
/// via its own auto-clear.
struct StaleRetryNotice: View {
  let message: String
  let onDismiss: () -> Void

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: "arrow.counterclockwise.circle")
        .foregroundStyle(.secondary)
      Text(message)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 12)
      Button("Dismiss", action: onDismiss)
        .buttonStyle(.borderless)
        .controlSize(.small)
        .accessibilityIdentifier("retryNotice.dismiss")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(
      RoundedRectangle(cornerRadius: 10)
        .fill(Color.secondary.opacity(0.08))
    )
    .padding(.horizontal, 12)
    .padding(.top, 8)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("retryNotice.banner")
  }
}
