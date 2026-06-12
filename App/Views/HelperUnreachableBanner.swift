import SwiftUI
import ServiceManagement

/// The loud, actionable escalation surface for a background-helper failure the
/// App could not auto-recover (#412). Renders ONLY when the
/// `HelperHealthController` restart ladder has exhausted (`.unreachable`) —
/// `reconnecting` / `repairing` stay quiet because the toolbar pip's helper
/// ring already carries those (white/amber blink), per the "quiet while
/// recovering, loud only when given up" design. Reuses `EngineStatusBanner` /
/// `PersistenceBanner` bar styling so the three read as the same app-level
/// alert.
///
/// The three actions are the complete recovery menu for a dead background
/// helper: restart it (re-run the launchd registration repair), re-enable it
/// in System Settings → Login Items (the only path that clears the macOS
/// consent gate), or collect a redacted diagnostics bundle for triage.
struct HelperUnreachableBanner: View {
  @ObservedObject var helperHealth: HelperHealthController

  struct Model: Equatable {
    let title: String
    let message: String
  }

  /// Pure gating + copy so the wording + "only when unreachable" rule are
  /// unit-tested without SwiftUI. Non-nil only for `.unreachable`.
  static func model(for health: HelperHealth) -> Model? {
    guard case .unreachable = health else { return nil }
    return Model(
      title: "Background helper isn’t responding",
      message: "Rational couldn’t restart its background engine helper, so the engine can’t run. Try restarting it, re-enable it in Login Items, or collect diagnostics."
    )
  }

  var body: some View {
    if let model = Self.model(for: helperHealth.health) {
      bar(model).accessibilityIdentifier("helperUnreachable.banner")
    }
  }

  private func bar(_ model: Model) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: "bolt.horizontal.circle.fill")
        .foregroundStyle(Color.red)
      VStack(alignment: .leading, spacing: 4) {
        Text(model.title).font(.callout).fontWeight(.medium)
        Text(model.message)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(3)
        HStack(spacing: 14) {
          Button("Restart Helper") { helperHealth.restartHelperManually() }
            .accessibilityIdentifier("helperUnreachable.banner.restart")
          Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
            .accessibilityIdentifier("helperUnreachable.banner.loginItems")
          Button("Collect Diagnostics…") {
            Task { await DiagnosticsCollector.collectAndReveal() }
          }
          .accessibilityIdentifier("helperUnreachable.banner.diagnostics")
        }
        .font(.caption)
        .padding(.top, 2)
      }
      Spacer()
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(Color.red.opacity(0.12))
    .overlay(
      Rectangle().frame(height: 0.5).foregroundStyle(Color.red.opacity(0.5)),
      alignment: .bottom
    )
  }
}
