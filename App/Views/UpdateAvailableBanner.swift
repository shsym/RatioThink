import SwiftUI

/// Non-modal launch-time "update available" banner (#411). Surfaced by the
/// once-per-launch GitHub check (see `UpdateAvailabilityModel`) when a newer
/// release the user has not ignored is available. Mirrors the
/// `ModelMissingBanner` idiom — an inline rounded bar rather than a modal
/// `NSAlert` — so it informs without interrupting.
///
/// Two actions: **Download** opens the release page (and dismisses), and
/// **Ignore this version** persists the version so it never re-surfaces until
/// a strictly newer one ships. The manual "Check for Updates…" menu command is
/// unaffected — it always checks and bypasses the ignore-set.
struct UpdateAvailableBanner: View {
  let pending: UpdateAvailabilityModel.Pending
  let onDownload: () -> Void
  let onIgnore: () -> Void

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      Image(systemName: "arrow.down.circle.fill")
        .foregroundStyle(.blue)
      VStack(alignment: .leading, spacing: 2) {
        Text("Update available")
          .font(.callout.weight(.medium))
        Text("RatioThink \(pending.latest) is available. Download it from GitHub, or ignore this version.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 12)
      Button("Ignore this version", action: onIgnore)
        .buttonStyle(.bordered)
        .accessibilityIdentifier("updateAvailable.ignore")
      Button("Download", action: onDownload)
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("updateAvailable.download")
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 10)
        .fill(Color.blue.opacity(0.10))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .strokeBorder(Color.blue.opacity(0.30))
    )
    .padding(.horizontal, 12)
    .padding(.top, 8)
    .accessibilityIdentifier("updateAvailable.banner")
  }
}
