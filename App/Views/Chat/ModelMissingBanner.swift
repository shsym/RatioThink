import SwiftUI

/// In-chat banner for #326's failed(modelMissing) path. Shown when the
/// engine could not start because its model is not on disk (e.g. a fresh
/// install where the seeded profile's model was never downloaded). The
/// App previously swallowed `EngineStatus.failed(.modelMissing)` — the
/// user only discovered the problem by failing a send. This surfaces it
/// proactively with the same inline download the no-model prompt uses,
/// then auto-starts the engine.
///
/// Gating is decided by `MissingModelRecovery.bannerTarget`, so this view
/// only ever receives a real, downloadable target.
struct ModelMissingBanner: View {
  let target: ModelDownloadTarget
  /// Called once the inline download completes — the parent starts the
  /// engine on the active profile.
  let onDownloaded: () -> Void
  /// Live engine status, threaded into the CTA so its completed latch can
  /// revert to Retry if the post-download start does not take (PR#15 F1).
  let engineStatus: EngineStatus

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.yellow)
      VStack(alignment: .leading, spacing: 2) {
        Text("Model not installed")
          .font(.callout.weight(.medium))
        Text("This profile needs \(target.displayName) to run. Download it to start chatting.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 12)
      MissingModelDownloadCTA(target: target, onDownloaded: onDownloaded, engineStatus: engineStatus)
      SettingsLink {
        Text("Settings…")
      }
      .accessibilityIdentifier("modelMissing.openSettings")
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 10)
        .fill(Color.yellow.opacity(0.10))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .strokeBorder(Color.yellow.opacity(0.30))
    )
    .padding(.horizontal, 12)
    .padding(.top, 8)
    .accessibilityIdentifier("modelMissing.banner")
  }
}
