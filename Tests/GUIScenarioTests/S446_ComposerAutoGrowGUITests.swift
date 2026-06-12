import XCTest

/// #446: the composer must auto-grow for SOFT-WRAPPED lines, not just hard
/// newlines. Before the fix a long line with no Return kept the box one line
/// tall and the wrapped text (descenders) clipped. This drives the real
/// SwiftUI + NSTextView layout end-to-end: typing a long line that wraps must
/// grow the composer's rendered height. Engine-free (no send, no model).
final class S446_ComposerAutoGrowGUITests: XCTestCase {
  override func setUp() async throws {
    try guardSeatedGUI()
  }

  @MainActor
  func test_long_wrapping_line_grows_the_composer() async throws {
    let pieHome = "/tmp/pie-s446grow-" + UUID().uuidString

    let app = XCUIApplication(bundleIdentifier: "com.ratiothink.app")
    app.launchArguments.append(contentsOf: [
      "-NSQuitAlwaysKeepsWindows", "NO",
      "-ApplePersistenceIgnoreState", "YES",
    ])
    app.launchEnvironment["PIE_HOME"] = pieHome
    configureCompletedFirstLaunch(app, suiteName: stablePreferenceSuiteName(pieHome))
    app.launch()
    defer { app.terminate() }

    XCTAssert(app.wait(for: .runningForeground, timeout: 10))
    app.activate()

    let newChat = app.buttons["chats.newButton"]
    XCTAssertTrue(newChat.waitForExistence(timeout: 10), "New Chat button missing")
    newChat.click()

    // A no-model launch gate may be presented; dismiss it so the composer is
    // interactable (we are not exercising the gate here).
    let cancel = app.buttons["noModel.cancel"]
    if cancel.waitForExistence(timeout: 2) { cancel.click() }

    let composer = app.descendants(matching: .any)
      .matching(identifier: "composer.text")
      .firstMatch
    XCTAssertTrue(composer.waitForExistence(timeout: 10), "composer.text missing")
    let singleLineHeight = composer.frame.height
    XCTAssertGreaterThan(singleLineHeight, 0)

    // A long line with NO newlines — this is the case the old hard-`\n` count
    // could not detect, so the box stayed one line and clipped the wrap.
    typeComposerText(String(repeating: "The capital of France is a long sentence ", count: 6),
                     in: app)

    // The reported height is applied on the next runloop tick; poll for growth.
    let deadline = Date().addingTimeInterval(8)
    var grownHeight = composer.frame.height
    while Date() < deadline, grownHeight <= singleLineHeight + 8 {
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.3))
      grownHeight = composer.frame.height
    }

    XCTAssertGreaterThan(grownHeight, singleLineHeight + 8,
                         "a soft-wrapped line must grow the composer beyond one line " +
                         "(was \(singleLineHeight), now \(grownHeight))")
  }
}
