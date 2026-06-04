import SwiftUI
import ServiceManagement

/// *Settings → General* — app-wide info and toggles that don't fit any
/// other tab. The About section shows the build version, a one-line
/// description, the GitHub URL, the bundle id, and the resolved PIE_HOME.
/// The Startup section surfaces whether RatioThink will keep its menu-bar
/// icon / background helper after the main app quits — a state owned by the
/// launchd-managed RatioThinkHelper's `SMAppService` registration, not the
/// app process — and routes to System Settings → Login Items to change it.
struct GeneralSettingsTab: View {
  @State private var resolvedPieHome: String = "—"
  @State private var menuBarPersistenceText =
    "Checking whether RatioThink stays in your menu bar after you quit…"

  /// One-line description of the app. Kept honest and feature-neutral — no
  /// release/update claims (those live in the #411 update-check surface).
  static let appDescription = "Native macOS app for the Pie inference engine."

  /// The project's public source URL, shown as a clickable link.
  static let gitHubURL = URL(string: "https://github.com/shsym/RatioThink")!

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        SettingsSectionHeader(title: "About")
        Text(Self.appDescription)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        VStack(alignment: .leading, spacing: 6) {
          SettingsLabeledRow(label: "Version") {
            Text(Self.versionString)
              .monospaced()
              .textSelection(.enabled)
          }
          SettingsLabeledRow(label: "GitHub") {
            Link(Self.gitHubURL.host ?? Self.gitHubURL.absoluteString,
                 destination: Self.gitHubURL)
              .textSelection(.enabled)
              .accessibilityIdentifier("GeneralGitHubLink")
          }
          SettingsLabeledRow(label: "Bundle") {
            Text(Bundle.main.bundleIdentifier ?? "—")
              .monospaced()
              .textSelection(.enabled)
          }
          SettingsLabeledRow(label: "PIE_HOME") {
            Text(resolvedPieHome)
              .monospaced()
              .textSelection(.enabled)
              .lineLimit(2)
              .truncationMode(.middle)
          }
        }

        Divider()

        SettingsSectionHeader(title: "Startup")
        VStack(alignment: .leading, spacing: 8) {
          Text(menuBarPersistenceText)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("MenuBarPersistenceSummary")
          Button("Open Login Items…") {
            SMAppService.openSystemSettingsLoginItems()
          }
          .accessibilityIdentifier("OpenLoginItemsButton")
        }

        Spacer(minLength: 0)
      }
      .padding(20)
    }
    .task {
      // Resolve both off the main actor: `SMAppService`'s status getter can
      // touch launchd, so run the read-only registration query (and the
      // PIE_HOME resolve, which may mkdir) on a detached task and hop back
      // only to assign @State. The query never registers/unregisters, so it
      // is safe on every launch — including GUI-test launches, which inject
      // a fixed status via PIE_TEST_LOGIN_ITEM_STATUS through the factory.
      let (home, summary) = await Task.detached {
        (Self.resolvePieHome(),
         LoginItemRegistrarFactory.make().status.menuBarPersistenceSummary)
      }.value
      await MainActor.run {
        resolvedPieHome = home
        menuBarPersistenceText = summary
      }
    }
  }

  private static var versionString: String {
    let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    return "\(short) (\(build))"
  }

  /// Mirror of `PieDirs.resolveRoot()` for display only. We hit the
  /// throwing primitive here so a permissions failure does not block
  /// the General tab from rendering — the error message is shown in
  /// place of the path.
  private static func resolvePieHome() -> String {
    do {
      return try PieDirs.applicationSupport().path
    } catch {
      return "error: \(error)"
    }
  }
}
