import XCTest

/// #326: on a fresh install (seeded profile, model NOT on disk) the
/// no-model send gate offers to DOWNLOAD the profile's default model
/// inline — not the plain "Load" that would dead-end with the file
/// absent. Engine-free: the gate + the download CTA fire before any
/// engine contact, and the download itself is the fake downloader, so
/// this runs without a real engine or network.
final class S326_FreshInstallModelDownloadGUITests: XCTestCase {
  override func setUp() async throws {
    try guardSeatedGUI()
  }

  @MainActor
  func test_no_model_send_offers_inline_download_on_fresh_install() async throws {
    // Real /tmp path, NOT NSTemporaryDirectory() (sandboxed runner
    // container the non-sandboxed app cannot write) — see S286.
    let pieHome = "/tmp/pie-s326dl-" + UUID().uuidString

    let app = XCUIApplication(bundleIdentifier: "com.ratiothink.app")
    app.launchArguments.append(contentsOf: [
      "-NSQuitAlwaysKeepsWindows", "NO",
      "-ApplePersistenceIgnoreState", "YES",
    ])
    app.launchEnvironment["PIE_HOME"] = pieHome
    // Fake the downloader so the CTA can be driven without a network /
    // real Hugging Face fetch. The seeded chat profile's model is not
    // staged in this fresh PIE_HOME, so the gate offers Download.
    app.launchEnvironment["PIE_TEST_FAKE_DOWNLOADS"] = "1"
    configureCompletedFirstLaunch(app, suiteName: stablePreferenceSuiteName(pieHome))
    app.launch()
    defer { app.terminate() }

    XCTAssert(app.wait(for: .runningForeground, timeout: 10))
    app.activate()

    let newChat = app.buttons["chats.newButton"]
    XCTAssertTrue(newChat.waitForExistence(timeout: 10), "New Chat button missing")
    newChat.click()

    let composer = app.descendants(matching: .any)
      .matching(identifier: "composer.text")
      .firstMatch
    XCTAssertTrue(composer.waitForExistence(timeout: 10), "composer.text missing")
    composer.click()
    composer.typeText("Hello with no model on disk")

    let send = app.buttons["composer.send"]
    XCTAssertTrue(send.waitForExistence(timeout: 5))
    send.click()

    // Send is blocked behind the no-model gate — never a silent load.
    // #397: assert the gate via its state-independent Cancel affordance,
    // not the pinned "No model loaded" headline (now state-dependent —
    // e.g. "Starting the engine…" while the engine boots, where #397 F2
    // keeps the download CTA below visible). The real #326 contract — the
    // inline Download CTA — is asserted next and is what this case proves.
    XCTAssertTrue(app.buttons["noModel.cancel"].waitForExistence(timeout: 5),
                  "send with nothing resolvable must raise the no-model gate")

    // #326: the model is NOT on disk, so the gate offers Download — the
    // inline recovery — and NOT the plain Load (which would dead-end).
    let download = app.buttons["missingModel.download"]
    XCTAssertTrue(download.waitForExistence(timeout: 5),
                  "fresh install with no staged model must offer inline Download")
    XCTAssertFalse(app.buttons["noModel.load"].exists,
                   "Load must not be offered when the model is not on disk")

    // Tapping Download enqueues into the shared controller and switches
    // the CTA to its in-flight row (the fake downloader yields
    // .downloading), surfacing a Cancel affordance.
    download.click()
    XCTAssertTrue(app.buttons["missingModel.cancel"].waitForExistence(timeout: 5),
                  "tapping Download must show the in-flight progress row")
  }

  /// A completed download must fire the CTA's one-shot `onDownloaded`
  /// latch, which dismisses the no-model prompt and kicks the engine
  /// start. Drives the fake downloader all the way to `.completed`.
  @MainActor
  func test_completed_download_fires_latch_and_dismisses_prompt() async throws {
    let pieHome = "/tmp/pie-s326done-" + UUID().uuidString

    let app = XCUIApplication(bundleIdentifier: "com.ratiothink.app")
    app.launchArguments.append(contentsOf: [
      "-NSQuitAlwaysKeepsWindows", "NO",
      "-ApplePersistenceIgnoreState", "YES",
    ])
    app.launchEnvironment["PIE_HOME"] = pieHome
    app.launchEnvironment["PIE_TEST_FAKE_DOWNLOADS"] = "1"
    // Drive the fake stream to a terminal `.completed` so the CTA's
    // completion latch fires.
    app.launchEnvironment["PIE_TEST_FAKE_DOWNLOAD_COMPLETE"] = "1"
    configureCompletedFirstLaunch(app, suiteName: stablePreferenceSuiteName(pieHome))
    app.launch()
    defer { app.terminate() }

    XCTAssert(app.wait(for: .runningForeground, timeout: 10))
    app.activate()

    let newChat = app.buttons["chats.newButton"]
    XCTAssertTrue(newChat.waitForExistence(timeout: 10), "New Chat button missing")
    newChat.click()

    let composer = app.descendants(matching: .any)
      .matching(identifier: "composer.text")
      .firstMatch
    XCTAssertTrue(composer.waitForExistence(timeout: 10), "composer.text missing")
    composer.click()
    composer.typeText("Download then start")

    let send = app.buttons["composer.send"]
    XCTAssertTrue(send.waitForExistence(timeout: 5))
    send.click()

    XCTAssertTrue(app.buttons["noModel.cancel"].waitForExistence(timeout: 5))
    let download = app.buttons["missingModel.download"]
    XCTAssertTrue(download.waitForExistence(timeout: 5))
    download.click()

    // The fake stream completes → onDownloaded fires once → the prompt
    // dismisses (and the engine start is kicked). Assert the gate's
    // state-independent Cancel disappears, not the pinned headline (#397).
    XCTAssertTrue(app.buttons["noModel.cancel"].waitForNonExistence(timeout: 10),
                  "a completed download must fire onDownloaded and dismiss the no-model prompt")
  }
}
