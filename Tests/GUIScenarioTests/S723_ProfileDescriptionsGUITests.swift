import XCTest

/// S723 — Settings → Profiles renders user-facing profile descriptions.
///
/// This is an engine-free GUI guard for the schema/UI split: the profile list
/// and detail pane should show `description`, while `system_prompt` remains a
/// separate editor section for engine instructions.
final class S723_ProfileDescriptionsGUITests: XCTestCase {
  override func setUp() async throws { try guardSeatedGUI() }

  @MainActor
  func test_seeded_profile_descriptions_render_in_profiles_settings() async throws {
    let pieHome = NSTemporaryDirectory()
      + "ratiothink-profile-descriptions-\(UUID().uuidString)"
    try FileManager.default.createDirectory(
      at: URL(fileURLWithPath: pieHome), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: pieHome) }

    let app = XCUIApplication(bundleIdentifier: "com.ratiothink.app")
    app.launchArguments.append(contentsOf: [
      "-NSQuitAlwaysKeepsWindows", "NO",
      "-ApplePersistenceIgnoreState", "YES",
    ])
    app.launchEnvironment["PIE_HOME"] = pieHome
    app.launchEnvironment["HF_HOME"] = pieHome + "/hf-empty"
    configureCompletedFirstLaunch(app, suiteName: stablePreferenceSuiteName(pieHome))
    app.launch()
    XCTAssert(app.wait(for: .runningForeground, timeout: 10),
              "RatioThink.app did not reach runningForeground")
    app.activate()
    defer { app.terminate() }

    app.typeKey(",", modifierFlags: .command)
    let settings = app.windows
      .matching(identifier: "com_apple_SwiftUI_Settings_window").firstMatch
    XCTAssertTrue(settings.waitForExistence(timeout: 10),
                  "Settings window did not appear; app: \(app.debugDescription)")
    let profilesTab = settings.toolbars.buttons.matching(identifier: "Profiles").firstMatch
    XCTAssertTrue(profilesTab.waitForExistence(timeout: 10),
                  "Profiles settings tab missing; window: \(settings.debugDescription)")
    profilesTab.click()

    assertDescription("A general-purpose chat profile for everyday questions and tasks.",
                      existsIn: settings)
    XCTAssertFalse(settings.staticTexts["A faster, deterministic chat profile that uses speculative decoding when available."].exists,
                   "retired Repeat Boost description must not render in seeded profile settings")
    XCTAssertTrue(settings.staticTexts["JSON Think"].exists,
                  "JSON Think seeded profile should remain listed")

    let chatDescription = settings.staticTexts["A general-purpose chat profile for everyday questions and tasks."]
    chatDescription.click()

    XCTAssertTrue(settings.staticTexts["Description"].waitForExistence(timeout: 5),
                  "Profile editor should expose a Description section; window: \(settings.debugDescription)")
    XCTAssertTrue(settings.textViews["ProfileEditorSystemPromptEditor"].waitForExistence(timeout: 5),
                  "System prompt should remain visible as separate editable engine instructions")
  }

  @MainActor
  private func assertDescription(_ text: String, existsIn settings: XCUIElement) {
    XCTAssertTrue(settings.staticTexts[text].waitForExistence(timeout: 10),
                  "Profile description missing: \(text); window: \(settings.debugDescription)")
  }
}
