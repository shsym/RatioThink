import XCTest

/// S411 — App menu update surface + New Chat removal (#411).
///
/// GUI-only. Drives the real `Rational.app` main menu bar and asserts the
/// two user-visible outcomes of #411:
///   1. The App menu (▸ "Rational") carries "Check for Updates…" — the
///      truthful manual update entry point, in the standard macOS slot.
///   2. The menu bar no longer exposes the orphaned no-op "New Chat" /
///      "New Chat (Always)" commands, and the default "New Window" stays
///      suppressed — so no ⌘N / ⌘T path can trigger the removed behavior.
///
/// No engine or model is needed: the menu shell renders from the completed
/// first-launch state alone. Skips without a seated GUI session.
final class S411_AppMenuUpdateGUITests: XCTestCase {
  override func setUp() async throws {
    try guardSeatedGUI()
  }

  /// Mirror S5: suppress NSWindow state restoration so a prior test's
  /// Settings window can't be the one this test inspects.
  private static let restorationOffArgs: [String] = [
    "-NSQuitAlwaysKeepsWindows", "NO",
    "-ApplePersistenceIgnoreState", "YES",
  ]

  @MainActor
  func test_appMenu_has_check_for_updates_and_no_new_chat() async throws {
    let app = XCUIApplication(bundleIdentifier: "com.ratiothink.app")
    app.launchArguments.append(contentsOf: Self.restorationOffArgs)
    configureCompletedFirstLaunch(app)
    app.launch()
    defer { app.terminate() }

    XCTAssert(app.wait(for: .runningForeground, timeout: 5),
              "Rational.app did not reach runningForeground")
    // XCUITest launches with the app not frontmost; activate so the main
    // menu populates the accessibility tree before we query it.
    app.activate()

    let menuBar = app.menuBars.firstMatch
    XCTAssertTrue(menuBar.waitForExistence(timeout: 5), "main menu bar missing")

    // 1. "Check for Updates…" lives specifically under the App menu (the
    //    menu bar item titled with the app name) — querying through it
    //    pins placement, not just existence somewhere in the bar.
    let appMenu = menuBar.menuBarItems["Rational"]
    XCTAssertTrue(appMenu.waitForExistence(timeout: 5), "App menu (Rational) missing")
    let checkForUpdates = appMenu.menuItems["Check for Updates…"]
    XCTAssertTrue(
      checkForUpdates.waitForExistence(timeout: 5),
      "App menu missing 'Check for Updates…'; app-menu items: \(appMenu.menuItems.allElementsBoundByIndex.map(\.title))"
    )

    // 2. No "New Chat" affordance survives anywhere in the menu bar, and the
    //    default "New Window" the empty `.newItem` replacement suppresses is
    //    also absent — so ⌘N / ⌘T cannot trigger a removed/half-baked action.
    for removed in ["New Chat", "New Chat (Always)", "New Window"] {
      XCTAssertFalse(
        menuBar.menuItems[removed].exists,
        "menu bar must not expose '\(removed)' after #411 cleanup"
      )
    }
  }
}
