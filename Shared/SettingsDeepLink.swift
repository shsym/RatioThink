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

  /// Host that requests a full-product quit (#448). The menu-bar Helper
  /// delivers `ratiothink://quit` to the running App so a single
  /// coordinator (the App) tears the whole product down — App + Helper +
  /// engine — instead of the Helper quitting itself while the App keeps
  /// polling and respawns it on-demand.
  public static let quitHost = "quit"

  /// `ratiothink://settings` — open straight to the Settings window.
  public static var settingsURL: URL {
    URL(string: "\(scheme)://\(settingsHost)")!
  }

  /// `ratiothink://quit` — ask the running App to perform a full-product quit.
  public static var quitURL: URL {
    URL(string: "\(scheme)://\(quitHost)")!
  }

  /// `true` when `url` is the canonical open-Settings deep link
  /// `ratiothink://settings`. Scheme and host are matched case-insensitively
  /// (both are case-insensitive per RFC 3986 and may be normalised by
  /// LaunchServices). Only the authority (`scheme://host`) spelling is
  /// accepted — that is the one and only form `settingsURL` produces, and
  /// authority parsing is stable across Foundation versions, unlike the
  /// no-authority `scheme:opaque` forms.
  public static func isSettings(_ url: URL) -> Bool {
    url.scheme?.lowercased() == scheme && url.host?.lowercased() == settingsHost
  }

  /// `true` when `url` is the canonical full-quit deep link
  /// `ratiothink://quit`. Same matching discipline as `isSettings`.
  public static func isQuit(_ url: URL) -> Bool {
    url.scheme?.lowercased() == scheme && url.host?.lowercased() == quitHost
  }
}
