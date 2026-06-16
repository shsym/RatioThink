import AppKit
import XCTest

/// S420 — the `ratiothink://settings` deep link opens the Settings scene.
///
/// GUI-only. Guards the App's half of the #420 wiring that PR #49 left without
/// an automated check: `App/SettingsURLHandler.swift`'s `onOpenURL` →
/// `SettingsDeepLink.isSettings` → `NSApp.activate()` + `openSettings()`,
/// attached to the window-group root via
/// `.handlesSettingsDeepLink(settingsNavigation:)`. If that modifier is dropped
/// (or the matcher drifts) the deep link silently degrades to a plain
/// app-foreground — the app comes forward but Settings never opens.
///
/// The test delivers the deep link the same way the menu-bar Helper does —
/// `NSWorkspace.open([url], withApplicationAt: <the running app's bundle>)` —
/// so it exercises the real LaunchServices delivery path into the app under
/// test, then asserts a NEW Settings window appears and is frontmost.
// gui-suite: full-matrix-only: no product-area focused target; runs in the full `make test-gui` matrix.
final class S420_SettingsDeepLinkGUITests: XCTestCase {
  /// The wire contract the Helper produces. Hard-coded (not imported from
  /// `SettingsDeepLink`) because a UI-test target does not link the app module;
  /// the constant itself is pinned by SettingsDeepLinkTests. An external
  /// producer literally sends these bytes, so a literal is the honest input.
  private static let settingsDeepLink = URL(string: "ratiothink://settings")!

  /// SwiftUI tags the Settings scene's NSWindow with this stable AX identifier
  /// across all macOS localizations (see S5_AppWindowShellGUITests).
  private static let settingsWindowID = "com_apple_SwiftUI_Settings_window"

  /// Suppress NSWindow state restoration between tests so a Settings window
  /// left by a prior run can't masquerade as the deep-link result (mirrors
  /// S5_AppWindowShellGUITests.restorationOffArgs).
  private static let restorationOffArgs: [String] = [
    "-NSQuitAlwaysKeepsWindows", "NO",
    "-ApplePersistenceIgnoreState", "YES",
  ]

  override func setUp() async throws {
    try guardSeatedGUI()
  }

  @MainActor
  func test_settings_deeplink_opens_settings_window() async throws {
    // The app-under-test should be the staged app next to the UI-test bundle,
    // not "whatever LaunchServices currently maps com.ratiothink.app to".
    // Launch through the UI-test target's configured AUT so XCUITest owns the
    // staged bundle from the start, then assert the running app is that staged
    // artifact before delivering the deep link to the exact running bundle.
    let stagedAppURL = try XCTUnwrap(
      Self.locateSiblingApp(named: "Rational.app", from: type(of: self)),
      "Rational.app not found next to test bundle — verify RatioThinkGUITests depends on target RatioThink"
    )
    try terminateRunningRationalApps(at: stagedAppURL)
    let app = XCUIApplication()
    app.launchArguments.append(contentsOf: Self.restorationOffArgs)
    configureCompletedFirstLaunch(app)
    app.launch()
    defer {
      // Close Settings before quit so macOS captures no Settings window in
      // restoration state for the next test (S5 convention).
      app.activate()
      app.typeKey("w", modifierFlags: .command)
      app.terminate()
    }

    XCTAssert(app.wait(for: .runningForeground, timeout: 5),
              "Rational.app did not reach runningForeground")
    app.activate()
    let appURL = try resolvedRunningAppURL(expected: stagedAppURL)

    // Precondition: no Settings window yet — so a post-delivery Settings window
    // is unambiguously the deep link's doing, not launch-time restoration.
    let settings = app.windows.matching(identifier: Self.settingsWindowID).firstMatch
    XCTAssertFalse(settings.exists, "a Settings window was already open before the deep link")

    // Start delivery from a backgrounded Rational.app. Without this
    // precondition the final foreground assertion would be a silent
    // false-positive: the test itself foregrounds Rational above so the
    // assertion would pass even if SettingsURLHandler stopped calling
    // NSApp.activate() for user-initiated helper/menu-bar deep links.
    backgroundRationalBeforeDeepLink(app)

    // Deliver the deep link to the running app-under-test's own bundle, so
    // LaunchServices can't route it to some other registered Rational.app.
    // For this handler-focused assertion path, do NOT ask LaunchServices to
    // activate the app: foregrounding must come from SettingsURLHandler's
    // NSApp.activate(), otherwise the final foreground check is a false
    // positive that passes without app-side activation.
    let cfg = NSWorkspace.OpenConfiguration()
    cfg.activates = false
    let delivered = expectation(description: "deep link delivered")
    NSWorkspace.shared.open([Self.settingsDeepLink], withApplicationAt: appURL, configuration: cfg) { _, error in
      XCTAssertNil(error, "NSWorkspace failed to deliver the deep link: \(String(describing: error))")
      delivered.fulfill()
    }
    await fulfillment(of: [delivered], timeout: 10)

    // The deep link must open the Settings scene. If the routing glue is
    // dropped, the URL degrades to a plain app-foreground and NO Settings
    // window ever appears — this is the regression the test guards.
    XCTAssertTrue(
      settings.waitForExistence(timeout: 5),
      "ratiothink://settings did not open the Settings window — the deep link "
        + "degraded to a plain app-foreground (expected SwiftUI identifier "
        + "'\(Self.settingsWindowID)')")
    // Prove it is the REAL, rendered Settings scene the user can act on, not a
    // blank or degenerate window: its tab toolbar must be present (mirrors
    // S5_AppWindowShellGUITests). AX elements are queryable regardless of
    // z-order, so this holds even though delivering the URL via LaunchServices
    // also re-raises a main window over the freshly-opened Settings.
    let generalTab = settings.toolbars.buttons.matching(identifier: "General").firstMatch
    XCTAssertTrue(
      generalTab.waitForExistence(timeout: 3),
      "Settings window opened but its tabs did not render — deep link did not "
        + "reach the real Settings scene")
    // …and the deep link must bring Rational forward (NSApp.activate() in the
    // handler), the foreground half of "open straight to Settings".
    XCTAssertTrue(
      app.wait(for: .runningForeground, timeout: 5),
      "deep link did not foreground the app; final state=\(app.state)")
  }

  func test_cleanupPlanRejectsNonStagedBundleURL() throws {
    let staged = URL(fileURLWithPath: "/tmp/current/Build/Products/Debug/Rational.app")
    let stale = URL(fileURLWithPath: "/Users/dev/Library/Developer/Xcode/DerivedData/Other/Build/Products/Debug/Rational.app")

    let plan = Self.rationalAppCleanupPlan(
      runningAppBundleURLs: [stale],
      stagedAppURL: staged)

    XCTAssertEqual(
      plan,
      .failNonStaged([
        "/Users/dev/Library/Developer/Xcode/DerivedData/Other/Build/Products/Debug/Rational.app",
      ]))
  }

  /// Move focus away from Rational before URL delivery so the post-delivery
  /// `.runningForeground` wait proves the deep-link handler foregrounded the
  /// app instead of inheriting a foreground state created by the test setup.
  @MainActor
  private func backgroundRationalBeforeDeepLink(
    _ app: XCUIApplication,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCUIApplication(bundleIdentifier: "com.apple.finder").activate()
    let deadline = Date().addingTimeInterval(5)
    while app.state == .runningForeground, Date() < deadline {
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
    }

    XCTAssertEqual(
      app.state,
      .runningBackground,
      "Rational must be backgrounded before deep-link delivery",
      file: file,
      line: line)
  }

  /// XCUITest's configured app launch is path-backed by the UI-test target.
  /// It is safe to remove only a previous instance of that same staged AUT; a
  /// different same-bundle-id Rational belongs to another install/worktree and
  /// must fail closed instead of being terminated by this test.
  private func terminateRunningRationalApps(at stagedAppURL: URL) throws {
    let apps = NSWorkspace.shared.runningApplications
      .filter { $0.bundleIdentifier == "com.ratiothink.app" }
    guard !apps.isEmpty else { return }

    switch Self.rationalAppCleanupPlan(
      runningAppBundleURLs: apps.map(\.bundleURL),
      stagedAppURL: stagedAppURL) {
    case .terminateStaged:
      break
    case let .failNonStaged(paths):
      throw S420LaunchError.nonStagedAppsAlreadyRunning(paths)
    }

    for app in apps where Self.isStagedRationalApp(
      bundleURL: app.bundleURL,
      stagedAppURL: stagedAppURL) {
      app.terminate()
    }

    if waitUntilNoStagedRationalAppsAreRunning(stagedAppURL: stagedAppURL, timeout: 2) { return }

    for app in NSWorkspace.shared.runningApplications
      .filter({
        $0.bundleIdentifier == "com.ratiothink.app"
          && Self.isStagedRationalApp(bundleURL: $0.bundleURL, stagedAppURL: stagedAppURL)
      }) {
      app.forceTerminate()
    }

    if waitUntilNoStagedRationalAppsAreRunning(stagedAppURL: stagedAppURL, timeout: 3) { return }

    let paths = NSWorkspace.shared.runningApplications
      .filter {
        $0.bundleIdentifier == "com.ratiothink.app"
          && Self.isStagedRationalApp(bundleURL: $0.bundleURL, stagedAppURL: stagedAppURL)
      }
      .compactMap { $0.bundleURL?.path }
      .joined(separator: ", ")
    throw S420LaunchError.timedOutTerminatingStagedApps(paths)
  }

  private func waitUntilNoStagedRationalAppsAreRunning(
    stagedAppURL: URL,
    timeout: TimeInterval
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      let stillRunning = NSWorkspace.shared.runningApplications
        .contains {
          $0.bundleIdentifier == "com.ratiothink.app"
            && Self.isStagedRationalApp(bundleURL: $0.bundleURL, stagedAppURL: stagedAppURL)
        }
      if !stillRunning { return true }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
    } while Date() < deadline
    return false
  }

  private static func rationalAppCleanupPlan(
    runningAppBundleURLs: [URL?],
    stagedAppURL: URL
  ) -> RationalAppCleanupPlan {
    let nonStagedPaths = runningAppBundleURLs.compactMap { bundleURL -> String? in
      guard let bundleURL else { return "<unknown bundle URL>" }
      let actual = canonicalAppURL(bundleURL)
      return actual == canonicalAppURL(stagedAppURL) ? nil : actual.path
    }

    if !nonStagedPaths.isEmpty {
      return .failNonStaged(nonStagedPaths)
    }
    return .terminateStaged
  }

  private static func isStagedRationalApp(bundleURL: URL?, stagedAppURL: URL) -> Bool {
    guard let bundleURL else { return false }
    return canonicalAppURL(bundleURL) == canonicalAppURL(stagedAppURL)
  }

  private enum RationalAppCleanupPlan: Equatable {
    case terminateStaged
    case failNonStaged([String])
  }

  private enum S420LaunchError: Error, CustomStringConvertible {
    case nonStagedAppsAlreadyRunning([String])
    case timedOutTerminatingStagedApps(String)

    var description: String {
      switch self {
      case let .nonStagedAppsAlreadyRunning(paths):
        return "Non-staged Rational.app instances are already running; S420 will not terminate "
          + "apps outside its staged AUT boundary. Quit these apps and retry. Observed: "
          + paths.joined(separator: ", ")
      case let .timedOutTerminatingStagedApps(paths):
        return "Timed out terminating staged Rational.app instances before S420 launch: \(paths)"
      }
    }
  }

  /// The bundle URL of the running app under test. The deep link is delivered
  /// to this exact bundle so it can't be routed to an installed copy. The
  /// explicit equality check catches stale LaunchServices/Xcode state where a
  /// same-bundle-id app outside the current build products was launched.
  private func resolvedRunningAppURL(expected stagedAppURL: URL) throws -> URL {
    let expected = Self.canonicalAppURL(stagedAppURL)
    let deadline = Date().addingTimeInterval(5)
    var observed: URL?
    repeat {
      observed = NSWorkspace.shared.runningApplications
        .first { $0.bundleIdentifier == "com.ratiothink.app" }?
        .bundleURL
        .map(Self.canonicalAppURL)
      if observed == expected { return expected }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
    } while Date() < deadline

    let got = observed?.path ?? "<none>"
    return try XCTUnwrap(
      nil as URL?,
      "XCUITest launched a different com.ratiothink.app bundle; expected staged "
        + "\(expected.path), got \(got)")
  }

  /// Locates a sibling `.app` next to the test bundle by walking up
  /// `Bundle(for:)` until a directory containing `<name>` is found.
  private static func locateSiblingApp(named name: String, from cls: AnyClass) -> URL? {
    let fm = FileManager.default
    var dir = Bundle(for: cls).bundleURL.deletingLastPathComponent()
    for _ in 0..<8 {
      let candidate = dir.appendingPathComponent(name)
      if fm.fileExists(atPath: candidate.path) { return candidate }
      let parent = dir.deletingLastPathComponent()
      if parent == dir { return nil }
      dir = parent
    }
    return nil
  }

  private static func canonicalAppURL(_ url: URL) -> URL {
    url.standardizedFileURL.resolvingSymlinksInPath()
  }
}
