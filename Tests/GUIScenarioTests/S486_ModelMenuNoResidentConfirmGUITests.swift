import XCTest

/// S486 — the TOOLBAR model picker.
///
/// The picker was redesigned from a native `Menu` (AX: MenuButton + NSMenuItem
/// rows) to a `Button` that toggles a custom `.popover` of `ModelRow-<slug>`
/// buttons grouped under a base-name header. The model name is the group
/// header; the variant (quant for GGUF, precision for safetensors) is the
/// secondary row text. This suite drives the NEW control.
///
/// Deterministic behaviors asserted here (engine-free, no Helper):
///   · the popover opens from the `toolbar.model` button and lists the seeded
///     model as a grouped row — a base-name HEADER plus a `ModelRow-<slug>`
///     variant sub-row (#580: the row renders the quant tag, never the raw
///     `.gguf` leaf);
///   · the popover dismisses;
///   · the #486 repro: on an UNPINNED chat (`fromModel == nil`) picking the
///     already-effective profile default commits SILENTLY — no switch-model
///     confirm.
///
/// The non-sandboxed app self-seeds the `chat` profile (default model
/// Y = Qwen3-0.6B-Q8_0.gguf) in a fresh `/tmp` PIE_HOME; the chat's selection
/// authority (`Chat.modelID`) is the only lever, set via the DEBUG
/// `PIE_TEST_CHAT_MODEL_PIN` seam (#460).
///
/// Two assertions are NOT deterministic under this pure-XCUITest harness and
/// are kept as a single documented `XCTSkip` (same treatment as the
/// ReadmeScreenshots model-dropdown selection test):
///   · the POSITIVE cross-model SWITCH confirm — `PIE_TEST_CHAT_MODEL_PIN`
///     re-pins `Chat.modelID` every render, masking the post-pick switch;
///   · an UNAVAILABLE (split-shard / in-progress) row is not selectable — the
///     sandboxed XCUITest runner cannot stage an unavailable model file
///     (S204/S365 stage such fixtures from an unsandboxed wrapper; this suite
///     has none), so no unavailable row exists to assert against.
final class S486_ModelMenuNoResidentConfirmGUITests: XCTestCase {
  /// Seeded `chat` profile default (`ProfileStore.defaultChatModelID`).
  private let defaultModelSlug = "Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf"
  private let defaultModelLeaf = "Qwen3-0.6B-Q8_0.gguf"
  /// Base-name group header the redesigned dropdown renders for the default.
  private let defaultModelBaseName = "Qwen3 0.6B"
  /// A slug deliberately DIFFERENT from the profile default, pinned as the
  /// chat's `Chat.modelID` for the (skipped) cross-model switch guard.
  private let pinnedSlug = "ghost-pinned.gguf"

  override func setUp() async throws {
    try guardSeatedGUI()
  }

  // MARK: - Popover structure: grouped name header + variant sub-row (#580)

  @MainActor
  func test_model_popover_lists_grouped_rows() throws {
    let app = launch(pinned: nil)
    defer { app.terminate() }

    let modelButton = app.buttons["toolbar.model"]
    XCTAssertTrue(modelButton.waitForExistence(timeout: 10),
                  "toolbar.model missing after creating chat; app tree: \(app.debugDescription)")
    XCTAssertTrue(openModelPopover(modelButton, in: app),
                  "model popover did not open; app tree: \(app.debugDescription)")

    // Base name is the group HEADER (a Text, not a row).
    XCTAssertTrue(app.staticTexts[defaultModelBaseName].waitForExistence(timeout: 3),
                  "base-name group header '\(defaultModelBaseName)' missing; app tree: \(app.debugDescription)")

    // The concrete row is a `ModelRow-<slug>` button rendering the QUANT tag,
    // never the raw `.gguf` leaf (#580).
    let row = modelRow(containingLeaf: defaultModelLeaf, in: app)
    XCTAssertTrue(row.waitForExistence(timeout: 3),
                  "ModelRow-<slug> button missing for the seeded model; app tree: \(app.debugDescription)")
    let rowText = (row.label + " " + ((row.value as? String) ?? ""))
    XCTAssertTrue(rowText.localizedCaseInsensitiveContains("Q8_0"),
                  "the model row must render the quant tag (Q8_0); row text=\(rowText)")
    XCTAssertFalse(rowText.localizedCaseInsensitiveContains(".gguf"),
                   "the model row must NOT render the raw .gguf leaf; row text=\(rowText)")
  }

  // MARK: - Dismiss

  @MainActor
  func test_model_popover_dismisses() throws {
    let app = launch(pinned: nil)
    defer { app.terminate() }

    let modelButton = app.buttons["toolbar.model"]
    XCTAssertTrue(modelButton.waitForExistence(timeout: 10),
                  "toolbar.model missing; app tree: \(app.debugDescription)")
    XCTAssertTrue(openModelPopover(modelButton, in: app),
                  "model popover did not open; app tree: \(app.debugDescription)")

    let row = modelRow(containingLeaf: defaultModelLeaf, in: app)
    XCTAssertTrue(row.waitForExistence(timeout: 3),
                  "model row missing while popover open; app tree: \(app.debugDescription)")

    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(row.waitForNonExistence(timeout: 5),
                  "the model popover must dismiss (rows gone) on escape; app tree: \(app.debugDescription)")
  }

  // MARK: - #486: no current model → silent commit, no switch confirm

  @MainActor
  func test_no_current_model_pick_commits_silently_without_switch_confirm() throws {
    let app = launch(pinned: nil)
    defer { app.terminate() }

    let modelButton = app.buttons["toolbar.model"]
    XCTAssertTrue(modelButton.waitForExistence(timeout: 10),
                  "toolbar.model missing after creating chat; app tree: \(app.debugDescription)")

    XCTAssertTrue(pickModelRow(containingLeaf: defaultModelLeaf, modelButton: modelButton, in: app),
                  "could not pick the profile-default model row; app tree: \(app.debugDescription)")

    // CLICK-LANDED proof: the row exists only while the popover is open; it
    // disappears only once the pick is delivered and the popover collapses, so
    // a dropped/no-op click cannot false-green the assertions below.
    let pickedRow = modelRow(containingLeaf: defaultModelLeaf, in: app)
    XCTAssertTrue(pickedRow.waitForNonExistence(timeout: 5),
                  "the pick must collapse the popover (proves the click was delivered); app tree: \(app.debugDescription)")

    // The fix (#486): with no current model there is nothing to REPLACE, so no
    // switch-model confirm may appear.
    let popover = app.descendants(matching: .any)
      .matching(identifier: "profileSwap.popover").firstMatch
    XCTAssertFalse(popover.waitForExistence(timeout: 4),
                   "picking a model with no current model must NOT raise the switch-model confirm (#486); app tree: \(app.debugDescription)")
    XCTAssertFalse(app.buttons["Switch"].exists,
                   "no 'Switch' confirm button may appear on a no-current-model pick")

    // The override committed silently: the toolbar still reflects the model.
    XCTAssertTrue(waitForElementValueContaining(modelButton, defaultModelLeaf, timeout: 8),
                  "after a silent pick the toolbar.model must still reflect the model; value=\(String(describing: modelButton.value))")
  }

  // MARK: - Harness-masked: cross-model switch confirm + unavailable row

  @MainActor
  func test_cross_model_switch_and_unavailable_row_are_harness_masked() throws {
    let app = launch(pinned: pinnedSlug)
    defer { app.terminate() }

    // Reachable preamble: the toolbar control still resolves with a pin set.
    let modelButton = app.buttons["toolbar.model"]
    XCTAssertTrue(modelButton.waitForExistence(timeout: 10),
                  "toolbar.model missing after creating chat; app tree: \(app.debugDescription)")

    throw XCTSkip("Cross-model SWITCH confirm and unavailable-row non-selectability " +
                  "are not deterministic under this pure-XCUITest harness: " +
                  "PIE_TEST_CHAT_MODEL_PIN re-pins Chat.modelID every render " +
                  "(masking the post-pick switch), and the sandboxed runner " +
                  "cannot stage an unavailable model file (no wrapper, unlike " +
                  "S204/S365). The deterministic popover structure, dismiss, and " +
                  "#486 silent-commit are covered by the other tests in this suite.")
  }

  // MARK: - new-control helpers

  /// Open the toolbar model popover (no row click), retrying under seated-session
  /// focus contention. The `toolbar.model.manageModels` button is the
  /// popover-is-open signal (it has no other source).
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

  /// Open the popover and click the row whose `ModelRow-<slug>` identifier
  /// CONTAINS `leaf`. Retries the whole open→find→click under a contended
  /// seated session. Returns true once the row was clicked.
  @MainActor
  private func pickModelRow(containingLeaf leaf: String,
                            modelButton: XCUIElement,
                            in app: XCUIApplication) -> Bool {
    let deadline = Date().addingTimeInterval(45)
    while Date() < deadline {
      app.activate()
      modelButton.click()
      let row = modelRow(containingLeaf: leaf, in: app)
      if row.waitForExistence(timeout: 3), row.isHittable {
        row.click()
        return true
      }
      app.typeKey(.escape, modifierFlags: [])
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.5))
    }
    return false
  }

  /// A popover model ROW — a `Button` carrying the `ModelRow-<slug>`
  /// accessibility identifier (the slug contains the leaf). Scoped to buttons so
  /// it never aliases the collapsed `toolbar.model` button, whose own value also
  /// carries the slug.
  private func modelRow(containingLeaf leaf: String,
                        in app: XCUIApplication) -> XCUIElement {
    app.buttons
      .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier CONTAINS[c] %@",
                            "ModelRow-", leaf))
      .firstMatch
  }

  // MARK: - setup

  /// Launch engine-free against a fresh `/tmp` PIE_HOME the NON-sandboxed app
  /// seeds itself. When `pinned` is non-nil, pin it as the fresh chat's
  /// `Chat.modelID` via the DEBUG `PIE_TEST_CHAT_MODEL_PIN` seam; when nil the
  /// chat is UNPINNED so `fromModel == nil` — the no-current-model repro.
  @MainActor
  private func launch(pinned: String?) -> XCUIApplication {
    let pieHome = "/tmp/pie-s486menu-" + UUID().uuidString
    let app = XCUIApplication(bundleIdentifier: "com.ratiothink.app")
    app.launchArguments.append(contentsOf: [
      "-NSQuitAlwaysKeepsWindows", "NO",
      "-ApplePersistenceIgnoreState", "YES",
    ])
    app.launchEnvironment["PIE_HOME"] = pieHome
    if let pinned { app.launchEnvironment["PIE_TEST_CHAT_MODEL_PIN"] = pinned }
    // Engine-free + hermetic: a dead loopback port means a stray developer
    // Helper can never reconcile a resident model.
    app.launchEnvironment["PIE_TEST_ENGINE_BASE_URL"] = "http://127.0.0.1:9"
    configureCompletedFirstLaunch(app, suiteName: stablePreferenceSuiteName(pieHome))
    app.launch()

    XCTAssert(app.wait(for: .runningForeground, timeout: 10),
              "Rational.app did not reach runningForeground")
    app.activate()
    openFreshChat(in: app)
    return app
  }

  // MARK: - polling helpers (shared idiom with S459/S426)

  private func waitForElementValueContaining(_ element: XCUIElement,
                                             _ needle: String,
                                             timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      let value = (element.value as? String) ?? ""
      if value.localizedCaseInsensitiveContains(needle)
        || element.label.localizedCaseInsensitiveContains(needle) { return true }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.3))
    }
    return false
  }
}
