import SwiftUI

/// The unified, source-labeled engine/helper status banner (A): ONE bar
/// driven by the pure `StatusBannerReducer`, replacing the separate
/// engine-error and helper-unreachable banners so both axes read as one
/// surface with one poll-count policy.
///
///   · Tier 0 (silent)        → renders nothing; the toolbar pip carries
///                               the "Starting… (Ns)" chip.
///   · Tier 1 (reconnecting)  → calm neutral bar, source-labeled, no action.
///   · Tier 2 (error)         → loud red bar + a source-aware Force Restart
///                               (helper unreachable → restart helper; engine
///                               failed but helper alive → restart engine).
///
/// Gating + copy live in `StatusBannerReducer` (pure, unit-tested); this view
/// is thin presentation that mirrors `PersistenceBanner`'s bar styling.
struct UnifiedStatusBannerView: View {
  let banner: UnifiedStatusBanner?
  /// Force Restart the background helper (reload its launchd registration).
  var onRestartHelper: () -> Void = {}
  /// Force Restart the engine on the active profile (helper still alive).
  var onRestartEngine: () -> Void = {}

  var body: some View {
    if let banner {
      bar(banner)
        .accessibilityIdentifier("status.banner")
    }
  }

  private func bar(_ banner: UnifiedStatusBanner) -> some View {
    let isError = banner.tier == .error
    let tint: Color = isError ? .red : .secondary
    return HStack(alignment: .top, spacing: 8) {
      Image(systemName: isError ? "xmark.octagon.fill" : "arrow.triangle.2.circlepath")
        .foregroundStyle(tint)
      VStack(alignment: .leading, spacing: 2) {
        Text(banner.title).font(.callout).fontWeight(.medium)
        if !banner.message.isEmpty {
          Text(banner.message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(3)
        }
      }
      Spacer()
      if banner.forceRestart != .none {
        Button("Force Restart") {
          switch banner.forceRestart {
          case .helper: onRestartHelper()
          case .engine: onRestartEngine()
          case .none: break
          }
        }
        .accessibilityIdentifier("status.banner.forceRestart")
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(tint.opacity(0.12))
    .overlay(
      Rectangle().frame(height: 0.5).foregroundStyle(tint.opacity(0.5)),
      alignment: .bottom
    )
  }
}
