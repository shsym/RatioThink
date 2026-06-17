import XCTest

/// S678 — the chat toolbar model dropdown MARKS an unverified model.
///
/// "Unverified" = a staged GGUF carrying a `.unverified` sidecar (download
/// finished but its sha256 was never checked against HF's X-Linked-Etag). The
/// Settings → Models table already flags these; the dropdown must too.
///
/// Engine-free + hermetic (the S486 idiom): a fresh `/tmp` PIE_HOME the
/// non-sandboxed app reads, with an unverified GGUF + sidecar staged under
/// `PIE_HOME/models/` BEFORE launch. The chat scaffold's library scan surfaces
/// it as a `ModelRow-<slug>` whether or not any engine is running. The
/// unverified signal is asserted on the row's accessibility VALUE ("Unverified")
/// — robust to the icon being a presentation detail.
///
/// Two scenarios, the second being the operator-reported repro:
///   · a NON-current unverified row is marked;
///   · a CURRENT unverified row is STILL marked — pre-fix the leading checkmark
///     suppressed the shield, so a just-downloaded, now-current unverified model
///     looked identical to a verified one.
final class S678_UnverifiedModelMarkGUITests: XCTestCase {
  /// Staged unverified model. A clean trailing GGUF quant so #580 grouping
  /// renders a real row (base "Test Unverified", quant "Q4_K_M").
  private let unverifiedSlug = "Vendor/Test-Unverified-GGUF/Test-Unverified-Q4_K_M.gguf"
  private let unverifiedLeaf = "Test-Unverified-Q4_K_M.gguf"

  override func setUp() async throws {
    try guardSeatedGUI()
  }

  @MainActor
  func test_non_current_unverified_model_is_marked_in_dropdown() throws {
    let app = launch(pinUnverifiedAsCurrent: false)
    defer { app.terminate() }

    let row = openAndFindUnverifiedRow(in: app)
    XCTAssertTrue(row.waitForExistence(timeout: 5),
                  "staged unverified model row missing from dropdown; app tree: \(app.debugDescription)")
    XCTAssertTrue(rowReportsUnverified(row),
                  "a non-current unverified row must be marked Unverified; row value=\(String(describing: row.value)) label=\(row.label)")
  }

  /// The operator's repro: the unverified model is ALSO the current selection.
  /// Pre-fix the leading checkmark won the single-glyph precedence and the
  /// shield vanished; post-fix the trailing badge + row value keep it marked.
  @MainActor
  func test_current_unverified_model_is_still_marked_in_dropdown() throws {
    let app = launch(pinUnverifiedAsCurrent: true)
    defer { app.terminate() }

    let row = openAndFindUnverifiedRow(in: app)
    XCTAssertTrue(row.waitForExistence(timeout: 5),
                  "staged current unverified model row missing; app tree: \(app.debugDescription)")
    XCTAssertTrue(rowReportsUnverified(row),
                  "a CURRENT unverified row must STILL be marked Unverified (#678 repro); row value=\(String(describing: row.value)) label=\(row.label)")
  }

  // MARK: - row lookup

  /// Open the popover and return the staged model's `ModelRow-<slug>` button.
  @MainActor
  private func openAndFindUnverifiedRow(in app: XCUIApplication) -> XCUIElement {
    let modelButton = app.buttons["toolbar.model"]
    XCTAssertTrue(modelButton.waitForExistence(timeout: 10),
                  "toolbar.model missing; app tree: \(app.debugDescription)")
    XCTAssertTrue(openModelPopover(modelButton, in: app),
                  "model popover did not open; app tree: \(app.debugDescription)")
    return app.buttons
      .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier CONTAINS[c] %@",
                            "ModelRow-", unverifiedLeaf))
      .firstMatch
  }

  /// The unverified signal lives on the row's a11y VALUE (set by
  /// `ContentToolbar`) — the single signal, since the trailing shield image is
  /// `accessibilityHidden` (a pure visual cue, no double VoiceOver
  /// announcement).
  private func rowReportsUnverified(_ row: XCUIElement) -> Bool {
    let value = (row.value as? String) ?? ""
    if value.localizedCaseInsensitiveContains("unverified") { return true }
    return row.label.localizedCaseInsensitiveContains("unverified")
  }

  @MainActor
  private func openModelPopover(_ modelButton: XCUIElement, in app: XCUIApplication) -> Bool {
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline {
      app.activate()
      modelButton.click()
      if app.buttons["toolbar.model.manageModels"].waitForExistence(timeout: 2) { return true }
      app.typeKey(.escape, modifierFlags: [])
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.4))
    }
    return false
  }

  // MARK: - setup

  /// Launch engine-free against a fresh `/tmp` PIE_HOME. The unverified GGUF +
  /// `.unverified` sidecar is staged by the NON-sandboxed app via the
  /// `PIE_TEST_SEED_UNVERIFIED_MODEL` DEBUG seam — the XCUITest runner is
  /// sandboxed and cannot write into `PIE_HOME/models` itself. When
  /// `pinUnverifiedAsCurrent` the staged slug is also pinned as the chat's
  /// `Chat.modelID` (#460 seam) so its row renders as the current selection.
  @MainActor
  private func launch(pinUnverifiedAsCurrent: Bool) -> XCUIApplication {
    let pieHome = "/tmp/pie-s678-" + UUID().uuidString

    let app = XCUIApplication(bundleIdentifier: "com.ratiothink.app")
    app.launchArguments.append(contentsOf: [
      "-NSQuitAlwaysKeepsWindows", "NO",
      "-ApplePersistenceIgnoreState", "YES",
    ])
    app.launchEnvironment["PIE_HOME"] = pieHome
    app.launchEnvironment["PIE_TEST_SEED_UNVERIFIED_MODEL"] = unverifiedSlug
    if pinUnverifiedAsCurrent {
      app.launchEnvironment["PIE_TEST_CHAT_MODEL_PIN"] = unverifiedSlug
    }
    // Engine-free: a dead loopback port means no stray Helper can reconcile a
    // resident model and perturb the row state.
    app.launchEnvironment["PIE_TEST_ENGINE_BASE_URL"] = "http://127.0.0.1:9"
    configureCompletedFirstLaunch(app, suiteName: stablePreferenceSuiteName(pieHome))
    app.launch()

    XCTAssert(app.wait(for: .runningForeground, timeout: 10),
              "Rational.app did not reach runningForeground")
    app.activate()
    openFreshChat(in: app)
    return app
  }
}
