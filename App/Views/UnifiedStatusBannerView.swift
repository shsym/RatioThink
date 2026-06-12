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
  /// #496: open System Settings → Login Items (the only path that clears the
  /// macOS consent gate). Offered alongside Force Restart on the helper-
  /// unreachable escalation — the full Helper recovery menu, ported from the
  /// deleted chat-body overlay.
  var onOpenLoginItems: () -> Void = {}
  /// #496: collect a redacted diagnostics bundle and reveal it in Finder.
  var onCollectDiagnostics: () -> Void = {}

  var body: some View {
    if let banner {
      bar(banner)
    }
  }

  private func bar(_ banner: UnifiedStatusBanner) -> some View {
    let isError = banner.tier == .error
    let tint: Color = isError ? .red : .secondary
    return HStack(alignment: .top, spacing: 8) {
      // The banner marker rides the decorative leading icon, NOT the container:
      // a container `accessibilityIdentifier` propagates down and OVERRIDES the
      // child buttons' own ids (the documented SwiftUI trap), which would make
      // Force Restart / Login Items / Diagnostics all unqueryable.
      Image(systemName: isError ? "xmark.octagon.fill" : "arrow.triangle.2.circlepath")
        .foregroundStyle(tint)
        .accessibilityIdentifier("status.banner")
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
      HStack(spacing: 8) {
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
        // #496: the full Helper recovery menu (ported from the deleted chat-body
        // overlay) rides ONLY the helper-unreachable escalation — never an
        // engine-axis error, where Login Items / diagnostics are irrelevant.
        if banner.source == .helper && banner.tier == .error {
          Button("Open Login Items…") { onOpenLoginItems() }
            .accessibilityIdentifier("status.banner.loginItems")
          Button("Collect Diagnostics…") { onCollectDiagnostics() }
            .accessibilityIdentifier("status.banner.diagnostics")
        }
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
