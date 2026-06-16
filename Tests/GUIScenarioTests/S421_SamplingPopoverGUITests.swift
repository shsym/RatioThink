import AppKit
import XCTest

/// S421 — the sampling popover ("advanced setup sliders") after the #421
/// polish: Temperature + Top-p sliders carry a coarse labelled tick scale,
/// and the Max tokens slider is GONE (its real ceiling is an engine-launch
/// concern, #438). Engine-free — the popover only edits local `ChatSampling`,
/// so it needs no Helper or running engine. Captures a screenshot of the real
/// native sliders + tick scale (the one thing the offscreen `ImageRenderer`
/// snapshot can't show) for eyeballing.
final class S421_SamplingPopoverGUITests: XCTestCase {
  private var tempHomes: [String] = []

  override func setUp() async throws {
    try guardSeatedGUI()
  }

  // Best-effort only; the sandboxed runner can't delete the real /tmp home —
  // the authoritative cleanup is the GUI_TMP_HOMES sweep in the Make recipe.
  override func tearDown() {
    for home in tempHomes { try? FileManager.default.removeItem(atPath: home) }
    tempHomes.removeAll()
    super.tearDown()
  }

  @MainActor
  func test_sampling_popover_has_temp_topP_and_no_max_tokens() async throws {
    // Real /tmp path, NOT NSTemporaryDirectory() (sandboxed-runner container
    // trap) — matches the engine-free siblings S285/S286.
    let pieHome = "/tmp/pie-s421sampling-" + UUID().uuidString
    tempHomes.append(pieHome)

    let app = XCUIApplication(bundleIdentifier: "com.ratiothink.app")
    app.launchArguments.append(contentsOf: [
      "-NSQuitAlwaysKeepsWindows", "NO",
      "-ApplePersistenceIgnoreState", "YES",
    ])
    app.launchEnvironment["PIE_HOME"] = pieHome
    configureCompletedFirstLaunch(app, suiteName: stablePreferenceSuiteName(pieHome))
    app.launch()
    defer { app.terminate() }

    XCTAssert(app.wait(for: .runningForeground, timeout: 10),
              "Rational.app did not reach runningForeground")
    app.activate()

    let newChat = app.buttons["chats.newButton"]
    XCTAssertTrue(newChat.waitForExistence(timeout: 10), "New Chat button missing")
    newChat.click()

    let params = app.buttons["toolbar.params"]
    XCTAssertTrue(params.waitForExistence(timeout: 10),
                  "sampling params button missing; tree: \(app.debugDescription)")
    params.click()

    // The two retained sampling sliders are present…
    XCTAssertTrue(app.staticTexts["Temperature"].waitForExistence(timeout: 5),
                  "Temperature row missing; tree: \(app.debugDescription)")
    XCTAssertTrue(app.staticTexts["Top-p"].exists, "Top-p row missing")

    // …and the Max tokens slider is GONE (#421 — moved to engine launch, #438).
    XCTAssertFalse(app.staticTexts["Max tokens"].exists,
                   "Max tokens row should be removed in #421")

    // Capture the real native sliders + coarse tick scale.
    let shot = app.screenshot()
    let att = XCTAttachment(screenshot: shot)
    att.name = "s421-sampling-popover"
    att.lifetime = .keepAlways
    add(att)
    if let tiff = shot.image.tiffRepresentation,
       let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
      let url = URL(fileURLWithPath: "/tmp/rt421-real-sampling-popover.png")
      try? png.write(to: url)
      print("RT421-REAL-SHOT \(url.path) (\(png.count) bytes)")
    }

    app.typeKey(.escape, modifierFlags: [])
  }
}
