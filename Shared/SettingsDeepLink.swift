import Foundation

/// The `ratiothink://` URL-scheme contract that lets the menu-bar Helper
/// (a separate process) ask the running — or launching — RatioThink.app to
/// open a specific surface.
///
/// Today the only route is Settings: the menu-bar "Settings…" item opens
/// `ratiothink://settings`, and the App's `onOpenURL` handler routes it to
/// the Settings scene instead of merely foregrounding the main window
/// (the prior behavior, which left the user to find ⌘, themselves).
///
/// Lives in `Shared` so the App (URL producer + router) and the Helper
/// (URL producer) share one source of truth and cannot drift on the
/// scheme/host strings — a drift would silently turn the deep link back
/// into a plain app-foreground.
public enum SettingsDeepLink {
  /// Custom URL scheme. MUST stay in sync with the App's
  /// `CFBundleURLTypes` (declared in `project.yml` → `App/Info.plist`).
  public static let scheme = "ratiothink"

  /// Host that selects the Settings surface.
  public static let settingsHost = "settings"

  /// `ratiothink://settings` — open straight to the Settings window.
  public static var settingsURL: URL {
    URL(string: "\(scheme)://\(settingsHost)")!
  }

  /// `true` when `url` is the open-Settings deep link.
  ///
  /// Scheme and host are matched case-insensitively (LaunchServices may
  /// normalise either), and both the `ratiothink://settings` (host) and
  /// the `ratiothink:settings` / `ratiothink:///settings` (path) spellings
  /// route, so a producer typo or a LaunchServices reshaping still lands
  /// on Settings rather than being dropped.
  public static func isSettings(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == scheme else { return false }
    if url.host?.lowercased() == settingsHost { return true }
    let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return path.lowercased() == settingsHost
  }
}
