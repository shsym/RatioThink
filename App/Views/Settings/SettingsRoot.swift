import SwiftUI

/// `Settings { SettingsRoot() }` host for the RatioThink app's Cmd-, window.
///
/// Four tabs (§5 design): General, Models, Profiles, Advanced. There is no
/// API tab: the local API is a single live view in the main window's API
/// Endpoints section (`LocalAPIView`, #422), not a settings pane.
/// The toolbar-button AX identity propagates from each tab's root
/// view, so every tab body MUST carry `.accessibilityIdentifier(title)`.
/// The S5_AppWindowShellGUITests case
/// `test_cmd_comma_opens_settings_with_four_tabs` pins that string via
/// `toolbarButtons.matching(identifier:)` queries — see the comment
/// block on `tab(_:systemImage:content:)` below for why pinning only
/// `.tabItem { Label }` is insufficient on macOS 14, and why the
/// content root must be an `.accessibilityElement(children: .contain)`
/// container rather than carry an `.accessibilityLabel`.
struct SettingsRoot: View {
  @EnvironmentObject private var appPreferences: AppPreferences

  var body: some View {
    TabView {
      tab("General", systemImage: "gear") {
        GeneralSettingsTab()
      }
      tab("Models", systemImage: "shippingbox") {
        ModelsSettingsTab()
      }
      tab("Profiles", systemImage: "person.crop.rectangle") {
        ProfilesSettingsTab()
      }
      // No API tab: the local API lives in the main window's API Endpoints
      // section (LocalAPIView, #422), the single surface for it.
      tab("Advanced", systemImage: "wrench.and.screwdriver") {
        AdvancedSettingsTab()
      }
    }
    .frame(width: 720, height: 520)
  }

  /// SwiftUI's TabView renders each tab as a toolbar button whose AX
  /// `.label` is empty on macOS 14 — XCUITest sees ["", "", "", "",
  /// ""]. Empirically verified (S5 GUI test): the propagating element
  /// for the toolbar button's AX identity is the tab-pane content
  /// view (this outer `accessibilityIdentifier` modifier on the body
  /// root), NOT the `Label` inside `.tabItem`. Label-only pinning is
  /// ignored by SwiftUI's toolbar adapter and drops the queryable
  /// toolbar count from 4 to 2.
  ///
  /// `.accessibilityElement(children: .contain)` is load-bearing
  ///: an earlier version paired `.accessibilityIdentifier`
  /// with `.accessibilityLabel(title)` on the content root. The label
  /// turned the whole pane into one combined element and propagated
  /// `title` onto EVERY descendant — captured in the a11y tree, the
  /// Models tab's `AddModelButton`, header, and table rows all
  /// reported `identifier == "Models"`, so XCUITest could not drive
  /// any control inside a Settings tab (the documented "Settings
  /// content undriveable" symptom). Marking the root an explicit
  /// `.contain` container keeps the tab identity on the toolbar button
  /// while leaving each child's own `.accessibilityIdentifier` intact.
  /// Do NOT re-add `.accessibilityLabel` here.
  @ViewBuilder
  private func tab<Content: View>(_ title: String,
                                   systemImage: String,
                                   @ViewBuilder content: () -> Content) -> some View {
    content()
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier(title)
      .tabItem { Label(title, systemImage: systemImage) }
  }
}

// MARK: - Shared chrome

/// One-row "label + value" pair used by every tab. SwiftUI's `Form`
/// (`LabeledContent`) handles half of this but bakes its own padding
/// and grays the value — we want plain mono values for paths.
struct SettingsLabeledRow<Value: View>: View {
  let label: String
  @ViewBuilder var value: () -> Value

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(label)
        .foregroundStyle(.secondary)
        .frame(width: 160, alignment: .trailing)
      value()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

/// Section header used inside each tab. Distinct from `Section { … }`
/// because the Settings panes are not `Form`s — they are bespoke
/// layouts and the boxy `Form` header style fights the design.
struct SettingsSectionHeader: View {
  let title: String
  var body: some View {
    Text(title)
      .font(.headline)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}
