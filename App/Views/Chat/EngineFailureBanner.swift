import SwiftUI

/// In-chat banner for engine failures that are NOT "model missing"
/// (PR#15 F2/F3). The model-missing case has its own download banner
/// (`ModelMissingBanner`); everything else — `spawnFailed`,
/// `handshakeTimeout`, `engineGone`, a stop that left the engine running,
/// a transport error — surfaced here so a user who just acted sees the
/// failure in-chat instead of only on the menu-bar dot, and never under
/// the persistence "Couldn't save" banner (wrong fault domain).
///
/// The message is decided by `MissingModelRecovery.engineFailureBannerMessage`;
/// this view only renders it. `onDismiss` is non-nil ONLY for a
/// dismissable message (a thrown action error); a live `.failed` status
/// re-derives the banner every render, so its Dismiss would be a no-op
/// and the button is hidden (PR#15 v2 F2).
struct EngineFailureBanner: View {
  let message: String
  let onDismiss: (() -> Void)?

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      Image(systemName: "exclamationmark.octagon.fill")
        .foregroundStyle(.red)
      VStack(alignment: .leading, spacing: 2) {
        Text("Engine problem")
          .font(.callout.weight(.medium))
        Text(message)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(3)
          .truncationMode(.tail)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 12)
      if let onDismiss {
        Button("Dismiss", action: onDismiss)
          .buttonStyle(.borderless)
          .accessibilityIdentifier("engineFailure.dismiss")
      }
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 10)
        .fill(Color.red.opacity(0.10))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .strokeBorder(Color.red.opacity(0.30))
    )
    .padding(.horizontal, 12)
    .padding(.top, 8)
    .accessibilityIdentifier("engineFailure.banner")
  }
}
