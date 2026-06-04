import XCTest
@testable import RatioThink

/// #420: the menu-bar "Settings…" deep link only works if the app bundle
/// registers the `ratiothink://` URL scheme (CFBundleURLTypes). That entry
/// lives in `project.yml` → `App/Info.plist` and is easy to drop in a regen
/// without any compile error — the deep link would then silently fall back
/// to a plain app-foreground. Pin the built host bundle's scheme to the
/// shared `SettingsDeepLink.scheme` constant so a drop fails loudly here.
final class SettingsDeepLinkBundleTests: XCTestCase {
  func test_host_app_registers_the_deeplink_scheme() throws {
    let urlTypes = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]
    let schemes = (urlTypes ?? []).flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] }
    XCTAssertTrue(
      schemes.contains(SettingsDeepLink.scheme),
      "App bundle must register the \(SettingsDeepLink.scheme):// scheme or the "
        + "menu-bar Settings deep link silently degrades to app-foreground; got \(schemes)")
  }
}
