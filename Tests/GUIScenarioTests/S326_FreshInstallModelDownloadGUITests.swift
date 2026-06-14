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
    // Keep this engine-free: if a real Helper is already running on the
    // developer machine, reconciliation must not discover its resident model
    // and bypass the fresh-install missing-model gate this scenario proves.
    app.launchEnvironment["PIE_TEST_ENGINE_BASE_URL"] = "http://127.0.0.1:9"
    // Fake the downloader so the CTA can be driven without a network /
    // real Hugging Face fetch. The seeded chat profile's model is not
    // staged in this fresh PIE_HOME, so the gate offers Download.
    app.launchEnvironment["PIE_TEST_FAKE_DOWNLOADS"] = "1"
    configureCompletedFirstLaunch(app, suiteName: stablePreferenceSuiteName(pieHome))
    app.launch()
    defer { app.terminate() }

    XCTAssert(app.wait(for: .runningForeground, timeout: 10))
    app.activate()

    // Open a chat and enter text via the shared focus-robust helpers
    // (`openFreshChat` re-activates + rescans; `typeComposerText` anchors
    // the click on the window and pastes) so a not-key full-suite launch
    // can't time out event synthesis and cascade into a spurious "download
    // absent" failure (#559). The remaining raw button clicks go through
    // `app.readyForInput` for the same reason.
    openFreshChat(in: app)

    typeComposerText("Hello with no model on disk", in: app)

    let send = app.buttons["composer.send"]
    XCTAssertTrue(send.waitForExistence(timeout: 5))
    XCTAssertTrue(send.isEnabled, "composer.send disabled after typing prompt; app tree: \(app.debugDescription)")
    try app.readyForInput(send).click()

    // Send is blocked behind the no-model gate — never a silent load.
    // #397: assert the gate via its state-independent prompt container,
    // not the pinned "No model loaded" headline (now state-dependent —
    // e.g. "Starting the engine…" while the engine boots, where #397 F2
    // keeps the download CTA below visible). On macOS, the parent prompt
    // identifier can subsume child button identifiers in busy states. The
    // real #326 contract — the inline Download CTA — is asserted next.
    XCTAssertTrue(noModelPrompt(in: app).waitForExistence(timeout: 5),
                  "send with nothing resolvable must raise the no-model gate")

    // #326: the model is NOT on disk, so the gate offers Download — the
    // inline recovery — and NOT the plain Load (which would dead-end).
    let download = missingModelDownloadButton(in: app)
    XCTAssertTrue(download.waitForExistence(timeout: 5),
                  "fresh install with no staged model must offer inline Download")
    XCTAssertFalse(app.buttons["noModel.load"].exists,
                   "Load must not be offered when the model is not on disk")

    // Tapping Download enqueues into the shared controller and switches
    // the CTA away from the Download affordance to its in-flight row (the
    // fake downloader yields .downloading). In the no-model sheet's busy
    // states macOS can collapse child accessibility identifiers into the
    // parent prompt, so assert the stable transition: the Download button
    // disappears rather than pinning the row's nested Cancel identifier.
    try app.readyForInput(download).click()
    XCTAssertTrue(download.waitForNonExistence(timeout: 5),
                  "tapping Download must replace the Download affordance with the in-flight progress row; app tree: \(app.debugDescription)")
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
    app.launchEnvironment["PIE_TEST_ENGINE_BASE_URL"] = "http://127.0.0.1:9"
    app.launchEnvironment["PIE_TEST_FAKE_DOWNLOADS"] = "1"
    // Drive the fake stream to a terminal `.completed` so the CTA's
    // completion latch fires.
    app.launchEnvironment["PIE_TEST_FAKE_DOWNLOAD_COMPLETE"] = "1"
    configureCompletedFirstLaunch(app, suiteName: stablePreferenceSuiteName(pieHome))
    app.launch()
    defer { app.terminate() }

    XCTAssert(app.wait(for: .runningForeground, timeout: 10))
    app.activate()

    openFreshChat(in: app)

    typeComposerText("Download then start", in: app)

    let send = app.buttons["composer.send"]
    XCTAssertTrue(send.waitForExistence(timeout: 5))
    XCTAssertTrue(send.isEnabled, "composer.send disabled after typing prompt; app tree: \(app.debugDescription)")
    try app.readyForInput(send).click()

    XCTAssertTrue(noModelPrompt(in: app).waitForExistence(timeout: 5))
    let download = missingModelDownloadButton(in: app)
    XCTAssertTrue(download.waitForExistence(timeout: 5))
    try app.readyForInput(download).click()

    // The fake stream completes → onDownloaded fires once → the prompt
    // dismisses (and the engine start is kicked). Assert the gate's
    // state-independent prompt container disappears, not the pinned headline (#397).
    XCTAssertTrue(noModelPrompt(in: app).waitForNonExistence(timeout: 10),
                  "a completed download must fire onDownloaded and dismiss the no-model prompt")
  }
}
