import XCTest

/// S5 — RatioThink.app window shell matches Notes-style 3-column design (§5).
///
/// GUI-only. Asserts against FINAL design strings — sidebar shows the nav
/// label `Chats` (the `API Endpoints` HTTP-serving feature is hidden in
/// v0.1.1; its nav row + the empty-state `Add Endpoint` CTA are both gone),
/// detail empty-state shows the `Start Chat` CTA, Settings opens via Cmd+,
/// with 4 tabs (the API tab is hidden in v0.1.1 with the rest of the feature).
final class S5_AppWindowShellGUITests: XCTestCase {
  override func setUp() async throws {
    try guardSeatedGUI()
  }

  /// Launch args that suppress NSWindow state restoration between
  /// tests. Without these, the cmd-comma test (which opens the
  /// Settings window) leaves macOS persisting the Settings window
  /// in restoration state; the next test's `launch()` then re-opens
  /// Settings and `app.windows.firstMatch` matches Settings instead
  /// of the main window — observed under Phase 3.8 review on
  /// 2026-05-19 (empty `title`, empty sidebar/CTA queries).
  ///
  /// `-NSQuitAlwaysKeepsWindows NO`     — per-launch override of the
  ///                                       per-user `NSQuitAlways…`
  ///                                       default that drives the
  ///                                       AppKit-side restoration
  ///                                       captureFile write at quit.
  /// `-ApplePersistenceIgnoreState YES` — belt-and-braces; tells the
  ///                                       launching app to ignore
  ///                                       any persistence blob that
  ///                                       *did* land before the
  ///                                       above flag took effect on
  ///                                       a prior test run.
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
              "RatioThink.app did not reach runningForeground")

    // XCUITest launches with `LSLaunchDoNotBringFrontmost=1`, so SwiftUI may
    // defer rendering until the window becomes active. Force activation so the
    // accessibility tree is populated before we query labels.
    app.activate()

    let window = app.windows.firstMatch
    XCTAssert(window.waitForExistence(timeout: 5), "main window missing")
    XCTAssertEqual(window.title, "RatioThink", "title was '\(window.title)'")

    // Sidebar (col 1) — design §5 final nav vocabulary.
    // SwiftUI can expose nav row text as label/identifier/title/value on
    // either a StaticText or Button element depending on the row style, so
    // scan the full descendant tree and check all string attributes.
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
    // v0.1.1: the API Endpoints feature is hidden — its sidebar nav row must
    // be absent (the enum case + Endpoint views remain, but unreachable).
    XCTAssertFalse(allStrings.contains("API Endpoints"),
                   "sidebar should NOT show 'API Endpoints' in v0.1.1; got: \(allStrings.filter { !$0.isEmpty }.sorted())")

    // Detail empty-state — design §5 CTA. Only `Start Chat` ships in v0.1.1;
    // the `Add Endpoint` CTA is hidden with the rest of the feature.
    XCTAssertTrue(allStrings.contains("Start Chat"),
                  "detail missing 'Start Chat' CTA; got: \(allStrings.filter { !$0.isEmpty }.sorted())")
    XCTAssertFalse(allStrings.contains("Add Endpoint"),
                   "empty-state should NOT show 'Add Endpoint' CTA in v0.1.1; got: \(allStrings.filter { !$0.isEmpty }.sorted())")

    // Pin the spoken VoiceOver label exactly — guards against SwiftUI
    // synthesizing the SF Symbol name into the Button's a11y label
    // (e.g. "bubble.left.and.bubble.right, Start Chat"). The Image inside
    // each CTA is `.accessibilityHidden(true)` so the Text is the sole
    // contributor to the spoken label.
    XCTAssertEqual(app.buttons["Start Chat"].label, "Start Chat",
                   "Start Chat VoiceOver label drifted from the Text content")
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
    // The previous title predicate ('Settings|Preferences|General') was
    // localization-fragile — never matches 'Préférences' / '設定' / etc — and
    // gave no signal when ⌘, was swallowed but a pre-existing window happened
    // to satisfy the predicate.
    let before = app.windows.count
    app.typeKey(",", modifierFlags: .command)

    // SwiftUI tags the Settings scene's NSWindow with the stable AX
    // identifier `com_apple_SwiftUI_Settings_window` across all macOS
    // localizations (verified via debugDescription dump in dev). Querying
    // by identifier is localization-proof; index-based resolution does not
    // work here because the new Settings window becomes Keyboard Focused
    // and is sorted ahead of the main window in `app.windows`.
    let settings = app.windows.matching(identifier: "com_apple_SwiftUI_Settings_window").firstMatch
    XCTAssertTrue(
      settings.waitForExistence(timeout: 3),
      "Settings window did not appear after ⌘, (had \(before) window(s) before; expected SwiftUI identifier 'com_apple_SwiftUI_Settings_window')"
    )
    XCTAssertEqual(
      app.windows.count, before + 1,
      "Expected exactly one new window after ⌘,; got delta=\(app.windows.count - before)"
    )

    // Lock toolbar-button cardinality before identifier queries — the
    // `buttons[id]` subscript resolves on label OR identifier across the
    // entire query, so without an explicit count assertion a stale sibling
    // (or the tab-pane content view) could satisfy `waitForExistence` while
    // the TabView toolbar itself is broken.
    let toolbarButtons = settings.toolbars.buttons
    XCTAssertEqual(
      toolbarButtons.count, 4,
      "Expected 4 TabView toolbar buttons (API tab hidden in v0.1.1); window: \(settings.debugDescription)"
    )

    // Query by identifier only (not the label-or-id subscript). Identifier
    // is pinned on the tab content view in App/RatioThinkApp.swift, which is the
    // verified propagation path for the toolbar button's AX identity on
    // macOS 14+ (pinning only on the inner `.tabItem` Label drops the
    // toolbar count from 5 to 2 — see commit notes).
    for expected in ["General", "Models", "Profiles", "Advanced"] {
      let tab = toolbarButtons.matching(identifier: expected).firstMatch
      XCTAssertTrue(
        tab.waitForExistence(timeout: 3),
        "Settings tab '\(expected)' missing; window: \(settings.debugDescription)"
      )
    }
    // v0.1.1: the API tab is hidden — its toolbar button must be absent.
    XCTAssertEqual(
      toolbarButtons.matching(identifier: "API").count, 0,
      "Settings should NOT show an 'API' tab in v0.1.1; window: \(settings.debugDescription)"
    )
  }
}
