import XCTest

/// S5 — Rational.app window shell matches the simplified Chat/Search/API shell.
///
/// GUI-only. Asserts against FINAL design strings — the sidebar shows the nav
/// labels `Chats`, `Search`, and `API Endpoints` (the last mirrors the live
/// engine endpoint via `LocalAPIView`, #422). The titlebar branding label was
/// removed and replaced by an emphasized new-chat button (`chats.newButton`).
/// Conversation search is a sibling sidebar destination (a `Search` nav row →
/// `ConversationSearchView` in the detail column), NOT an inline chat-list
/// filter. The no-selection landing shows the `Start Chat` CTA. Settings opens
/// via Cmd+, with 4 tabs (no API settings tab — the local API's single surface
/// is the main window).
final class S5_AppWindowShellGUITests: XCTestCase {
  override func setUp() async throws {
    try guardSeatedGUI()
  }

  /// Launch args that suppress NSWindow state restoration between
  /// tests. Without these, the cmd-comma test (which opens the
  /// Settings window) leaves macOS persisting the Settings window
  /// in restoration state; the next test's `launch()` then re-opens
  /// Settings and `app.windows.firstMatch` matches Settings instead
  /// of the main window.
  private static let restorationOffArgs: [String] = [
    "-NSQuitAlwaysKeepsWindows", "NO",
    "-ApplePersistenceIgnoreState", "YES",
  ]

  @MainActor
  func test_main_window_matches_design_vocabulary() async throws {
    let app = XCUIApplication(bundleIdentifier: "com.ratiothink.app")
    app.launchArguments.append(contentsOf: Self.restorationOffArgs)
    configureCompletedFirstLaunch(app)
    app.launch()
    defer { app.terminate() }

    XCTAssert(app.wait(for: .runningForeground, timeout: 5),
              "Rational.app did not reach runningForeground")

    // XCUITest launches with `LSLaunchDoNotBringFrontmost=1`, so SwiftUI may
    // defer rendering until the window becomes active. Force activation so the
    // accessibility tree is populated before we query labels.
    app.activate()

    let window = app.windows.firstMatch
    XCTAssert(window.waitForExistence(timeout: 5), "main window missing")
    // Branding removed from the titlebar; an emphasized new-chat button took
    // that spot, so the titlebar no longer reads the product name as a label.
    XCTAssertNotEqual(window.title, "Rational",
                      "titlebar branding should be gone; title was '\(window.title)'")
    XCTAssertTrue(app.buttons["chats.newButton"].waitForExistence(timeout: 5),
                  "titlebar New Chat affordance missing")

    // Sidebar (col 1) — final nav vocabulary.
    XCTAssertTrue(
      window.descendants(matching: .any).matching(identifier: "Chats")
        .firstMatch.waitForExistence(timeout: 5),
      "sidebar nav row 'Chats' did not appear within 5s"
    )
    func collectStrings(from query: XCUIElementQuery) -> [String] {
      query.allElementsBoundByIndex.flatMap {
        [$0.label, $0.identifier, $0.title, $0.value as? String ?? ""]
      }
    }
    let descendantStrings = collectStrings(from: window.descendants(matching: .any))
    let buttonStrings = collectStrings(from: window.descendants(matching: .button))
    let staticTextStrings = collectStrings(from: window.descendants(matching: .staticText))
    let allStrings = Set(descendantStrings + buttonStrings + staticTextStrings)

    XCTAssertTrue(allStrings.contains("Chats"),
                  "sidebar missing 'Chats'; got: \(allStrings.filter { !$0.isEmpty }.sorted())")
    // Conversation search is a sibling sidebar destination.
    XCTAssertTrue(allStrings.contains("Search"),
                  "sidebar missing 'Search'; got: \(allStrings.filter { !$0.isEmpty }.sorted())")
    // The chat-list header was renamed Chat List → Conversations.
    XCTAssertTrue(allStrings.contains("Conversations"),
                  "chat-list header missing 'Conversations'; got: \(allStrings.filter { !$0.isEmpty }.sorted())")
    // #422: the API Endpoints section is live — its sidebar nav row routes to
    // the single LocalAPIView.
    XCTAssertTrue(allStrings.contains("API Endpoints"),
                  "sidebar missing 'API Endpoints'; got: \(allStrings.filter { !$0.isEmpty }.sorted())")

    // Search is a dedicated nav destination, NOT an inline chat-list filter.
    XCTAssertFalse(app.textFields["chats.searchField"].exists,
                   "conversation search must be a sidebar destination, not an inline chat-list filter")

    // The no-selection landing shows the Start Chat CTA; there is no
    // per-endpoint Add Endpoint CTA.
    XCTAssertTrue(allStrings.contains("Start Chat"),
                  "detail missing 'Start Chat' CTA; got: \(allStrings.filter { !$0.isEmpty }.sorted())")
    XCTAssertFalse(app.buttons["Add Endpoint"].exists,
                   "landing must not show an 'Add Endpoint' CTA")
  }

  @MainActor
  func test_cmd_comma_opens_settings_with_four_tabs() async throws {
    let app = XCUIApplication(bundleIdentifier: "com.ratiothink.app")
    app.launchArguments.append(contentsOf: Self.restorationOffArgs)
    configureCompletedFirstLaunch(app)
    app.launch()
    // Defense-in-depth on top of `-NSQuitAlwaysKeepsWindows NO`:
    // explicitly close the Settings window before letting the app
    // terminate. State restoration in macOS captures
    // currently-visible windows at quit; closing Settings first
    // means there is no Settings to restore even if the launch-arg
    // override is dropped on a future Xcode version.
    defer {
      app.typeKey("w", modifierFlags: .command)
      app.terminate()
    }
    XCTAssert(app.wait(for: .runningForeground, timeout: 5))

    // Snapshot window count before ⌘, so we can assert a NEW window appeared.
    let before = app.windows.count
    app.typeKey(",", modifierFlags: .command)

    // SwiftUI tags the Settings scene's NSWindow with the stable AX
    // identifier `com_apple_SwiftUI_Settings_window` across all macOS
    // localizations. Querying by identifier is localization-proof.
    let settings = app.windows.matching(identifier: "com_apple_SwiftUI_Settings_window").firstMatch
    XCTAssertTrue(
      settings.waitForExistence(timeout: 3),
      "Settings window did not appear after ⌘, (had \(before) window(s) before; expected SwiftUI identifier 'com_apple_SwiftUI_Settings_window')"
    )
    XCTAssertEqual(
      app.windows.count, before + 1,
      "Expected exactly one new window after ⌘,; got delta=\(app.windows.count - before)"
    )

    // Lock toolbar-button cardinality before identifier queries.
    let toolbarButtons = settings.toolbars.buttons
    XCTAssertEqual(
      toolbarButtons.count, 4,
      "Expected 4 TabView toolbar buttons (no API settings tab — the local API's surface is the main window); window: \(settings.debugDescription)"
    )

    for expected in ["General", "Models", "Profiles", "Advanced"] {
      let tab = toolbarButtons.matching(identifier: expected).firstMatch
      XCTAssertTrue(
        tab.waitForExistence(timeout: 3),
        "Settings tab '\(expected)' missing; window: \(settings.debugDescription)"
      )
    }
    XCTAssertEqual(
      toolbarButtons.matching(identifier: "API").count, 0,
      "Settings should NOT show an 'API' tab (single surface is the main window); window: \(settings.debugDescription)"
    )
  }
}
