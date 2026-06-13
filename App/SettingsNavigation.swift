import SwiftUI
/// App-scoped selection state for the Settings scene.
///
/// `openSettings()` can only present the Settings window; it cannot choose a
/// TabView tab by itself. This small observable bridge lets in-app shortcuts
/// and URL deep links request a concrete tab before opening the scene.
@MainActor
final class SettingsNavigation: ObservableObject {
  @Published var selectedTab: SettingsDeepLink.Tab = .general

  func open(_ tab: SettingsDeepLink.Tab?) {
    if let tab { selectedTab = tab }
  }
}
