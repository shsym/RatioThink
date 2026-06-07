import SwiftUI
import AppKit

/// Routes the `ratiothink://settings` deep link to the Settings scene.
///
/// The menu-bar Helper (a separate process) opens `ratiothink://settings`
/// when the user picks its "Settings…" item; LaunchServices launches or
/// foregrounds Rational.app and delivers the URL here. Without this the
/// Helper could only foreground the main window, leaving the user to find
/// ⌘, themselves — the gap #420 closes.
///
/// Uses the macOS 14 `openSettings` environment action (the same action a
/// `SettingsLink` fires), so it opens the real `Settings { … }` scene from
/// a cold or background launch without a private selector.
struct SettingsURLHandler: ViewModifier {
  @Environment(\.openSettings) private var openSettings

  func body(content: Content) -> some View {
    content.onOpenURL { url in
      // #448: the menu-bar Helper delivers `ratiothink://quit` to ask the
      // App (the single quit coordinator) to tear the whole product down.
      // Route it to NSApp.terminate so it flows through the standard
      // `applicationShouldTerminate` coordinator just like ⌘Q.
      if SettingsDeepLink.isQuit(url) {
        Diag.app.event("deeplink.open", [("route", "quit")])
        NSApp.terminate(nil)
        return
      }
      guard SettingsDeepLink.isSettings(url) else { return }
      // Triage breadcrumb: proves the menu-bar "Settings…" deep link
      // reached the app (vs. a LaunchServices/scheme-registration failure).
      Diag.app.event("deeplink.open", [("route", "settings")])
      // Bring the app forward first: a deep link that launches the app
      // from the background otherwise opens Settings behind other windows.
      // No-arg `activate()` is the non-deprecated macOS-14 API (and matches
      // the Helper's convention); LaunchServices already foregrounds the app
      // when it delivers the deep link, so dropping the argument is a no-op.
      NSApp.activate()
      openSettings()
    }
  }
}

extension View {
  /// Attach the `ratiothink://settings` → Settings-scene router.
  func handlesSettingsDeepLink() -> some View {
    modifier(SettingsURLHandler())
  }
}
