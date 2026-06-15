import XCTest

/// S486 — picking a model from the TOOLBAR model menu must NOT raise the
/// switch-model confirm when there is no current model.
///
/// User-reported repro: with NO model resident (engine stopped) on an unpinned
/// chat whose profile default is already effective, picking that same model
/// from the toolbar model menu raised a spurious "Switch model?" popover that
/// re-loaded the already-effective model. Root cause: `requestModelOverride`
/// keyed its same-model check on `modelID == fromModel`, which degrades to
/// `modelID == nil` (always false) when the chat has no current selection
/// (`fromModel == nil`), so it fell through to the confirm popover —
/// `requestSwap` already skipped that case (Policy 1.5) but the model-menu
/// path did not. Fix (#486): `requestModelOverride` commits silently with no
/// load when `fromModel == nil`.
///
/// This drives the REAL toolbar path engine-free, mirroring S459's #460
/// single-source model: the non-sandboxed app self-seeds the `chat` profile
/// (default model Y = Qwen3-0.6B-Q8_0.gguf) in a fresh `/tmp` PIE_HOME, no
/// real engine, no Helper. The chat's selection authority (`Chat.modelID`) is
/// the only lever:
///   · NEGATIVE (the repro): a fresh UNPINNED chat → `fromModel == nil`.
///     Picking the profile-default model row must commit silently — NO
///     `profileSwap.popover`, and the toolbar still reflects the model.
///   · POSITIVE (guard): pin a DIFFERENT model X (`PIE_TEST_CHAT_MODEL_PIN`)
///     as the chat's selection, then pick the profile default Y ≠ X — that IS
///     a real switch and MUST raise the popover. Proves the menu can raise the
///     confirm, so the negative's absence is meaningful, not a dead control.
///
/// Per the repo flake convention (#460 review), model-menu rows are
/// matched by a STABLE identity predicate (value/label/title CONTAINS the
/// slug leaf), never by exact menu-item title.
final class S486_ModelMenuNoResidentConfirmGUITests: XCTestCase {
  /// Seeded `chat` profile default (`ProfileStore.defaultChatModelID`). Its
  /// friendly leaf is what the toolbar model menu renders.
  private let defaultModelSlug = "Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf"
  private let defaultModelLeaf = "Qwen3-0.6B-Q8_0.gguf"
  /// A slug deliberately DIFFERENT from the profile default, pinned as the
  /// chat's `Chat.modelID` for the positive guard so picking Y is cross-model.
  private let pinnedSlug = "ghost-pinned.gguf"

  override func setUp() async throws {
    try guardSeatedGUI()
  }

  // MARK: - NEGATIVE: the repro — no current model → silent, no popover

  @MainActor
  func test_no_current_model_pick_commits_silently_without_switch_confirm() throws {
    let app = launch(pinned: nil)
    defer { app.terminate() }

    let modelMenu = app.menuButtons["toolbar.model"]
    XCTAssertTrue(modelMenu.waitForExistence(timeout: 10),
                  "toolbar.model missing after creating chat; app tree: \(app.debugDescription)")

    XCTAssertTrue(pickModelMenuRow(containingLeaf: defaultModelLeaf, modelMenu: modelMenu, in: app),
                  "could not pick the profile-default model row; app tree: \(app.debugDescription)")

    // CLICK-LANDED proof (review v2 F1): on an unpinned chat the toolbar
    // already shows the profile default and the silent commit is a no-op, so
    // every other assertion below is ALSO true before the click — a
    // non-delivered click (Helpers.swift:70-72 flake) would false-green the
    // guard. The menu row exists ONLY while the menu is open; it disappears
    // only when the click is delivered to the menu and it collapses. Assert
    // the row vanished so a no-op/dropped click cannot pass.
    let pickedRow = modelMenuRow(containingLeaf: defaultModelLeaf, in: app)
    XCTAssertTrue(pickedRow.waitForNonExistence(timeout: 5),
                  "the model-menu pick must collapse the menu (proves the click was delivered); app tree: \(app.debugDescription)")

    // The fix: with no current model there is nothing to REPLACE, so NO
    // switch-model confirm may appear. Assert the popover never presents.
    let popover = app.descendants(matching: .any)
      .matching(identifier: "profileSwap.popover").firstMatch
    XCTAssertFalse(popover.waitForExistence(timeout: 4),
                   "picking a model with no current model must NOT raise the switch-model confirm (#486); app tree: \(app.debugDescription)")
    XCTAssertFalse(app.buttons["Switch"].exists,
                   "no 'Switch' confirm button may appear on a no-current-model pick")

    // The override committed silently: the toolbar still reflects the model
    // (it did not blank out, and no modal is blocking it).
    XCTAssertTrue(waitForElementValueContaining(modelMenu, defaultModelLeaf, timeout: 8),
                  "after a silent pick the toolbar.model must still reflect the model; value=\(String(describing: modelMenu.value))")
  }

  // MARK: - POSITIVE guard: a real cross-model pick DOES confirm

  @MainActor
  func test_cross_model_pick_raises_switch_confirm() throws {
    let app = launch(pinned: pinnedSlug)
    defer { app.terminate() }

    let modelMenu = app.menuButtons["toolbar.model"]
    XCTAssertTrue(modelMenu.waitForExistence(timeout: 10),
                  "toolbar.model missing after creating chat; app tree: \(app.debugDescription)")
    // Sanity: the chat's pinned selection X is what the toolbar shows.
    XCTAssertTrue(waitForElementValueContaining(modelMenu, "ghost-pinned", timeout: 10),
                  "the pinned model X must be the chat's current selection; value=\(String(describing: modelMenu.value))")

    XCTAssertTrue(pickModelMenuRow(containingLeaf: defaultModelLeaf, modelMenu: modelMenu, in: app),
                  "could not pick the profile-default model row Y; app tree: \(app.debugDescription)")

    // Picking Y while pinned to X ≠ Y is a real switch → the confirm MUST show.
    let popover = app.descendants(matching: .any)
      .matching(identifier: "profileSwap.popover").firstMatch
    XCTAssertTrue(popover.waitForExistence(timeout: 6),
                  "a cross-model model-menu pick MUST raise the switch-model confirm; app tree: \(app.debugDescription)")
    // Container id masks inner button ids on macOS (S302/S459 quirk) — assert
    // the user-facing label.
    XCTAssertTrue(app.buttons["Switch"].waitForExistence(timeout: 4),
                  "the switch-model confirm must offer 'Switch'; app tree: \(app.debugDescription)")
    app.typeKey(.escape, modifierFlags: [])
  }

  // MARK: - #580 structured-name rendering (visual verification)

  /// The chat model dropdown renders the agreed STRUCTURED identity (Q1/Q3):
  /// the base name as the section header, the quant as the row tag, and the
  /// GGUF format dropped — NOT the raw `qwen3…gguf` leaf. Engine-free: the
  /// seeded `chat` default (`Qwen3-0.6B-Q8_0.gguf`) is enough to open the menu.
  @MainActor
  func test_model_menu_renders_structured_quant_tag_not_raw_leaf() throws {
    let app = launch(pinned: nil)
    defer { app.terminate() }

    let modelMenu = app.menuButtons["toolbar.model"]
    XCTAssertTrue(modelMenu.waitForExistence(timeout: 10),
                  "toolbar.model missing; app tree: \(app.debugDescription)")
    XCTAssertTrue(openModelMenu(modelMenu, in: app),
                  "model menu did not open; app tree: \(app.debugDescription)")

    // Base name is the section header (#580 #4 / Q1 "base prominent").
    XCTAssertTrue(app.menuItems["Qwen3 0.6B"].waitForExistence(timeout: 3),
                  "base-name section header 'Qwen3 0.6B' missing; app tree: \(app.debugDescription)")

    // The concrete row is targetable by its ModelRow-<slug> identifier and
    // renders the QUANT tag as its visible text (Q1 "quant as a tag").
    let row = app.menuItems
      .matching(NSPredicate(format: "identifier CONTAINS[c] %@", defaultModelLeaf)).firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 3),
                  "ModelRow-<slug> identifier missing for the seeded model; app tree: \(app.debugDescription)")
    XCTAssertTrue(row.title.localizedCaseInsensitiveContains("Q8_0"),
                  "the model row must render the quant tag (Q8_0); title=\(row.title)")

    // Q3 / "no raw leaf": no model ROW renders the `.gguf` leaf as its text.
    XCTAssertFalse(row.title.localizedCaseInsensitiveContains(".gguf"),
                   "the model row must NOT render the raw .gguf leaf; title=\(row.title)")
    app.typeKey(.escape, modifierFlags: [])
  }

  /// Open the toolbar model menu (no row click), retrying under seated-session
  /// focus contention. The `toolbar.model.manageModels` item is the
  /// menu-is-open signal (it has no other source).
  @MainActor
  private func openModelMenu(_ modelMenu: XCUIElement, in app: XCUIApplication) -> Bool {
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline {
      app.activate()
      modelMenu.click()
      if app.menuItems["toolbar.model.manageModels"].waitForExistence(timeout: 2) { return true }
      app.typeKey(.escape, modifierFlags: [])
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.4))
    }
    return false
  }

  // MARK: - setup

  /// Launch engine-free against a fresh `/tmp` PIE_HOME the NON-sandboxed app
  /// seeds itself. When `pinned` is non-nil, pin it as the fresh chat's
  /// `Chat.modelID` via the DEBUG `PIE_TEST_CHAT_MODEL_PIN` seam (#460 selection
  /// authority); when nil the chat is UNPINNED so `fromModel == nil` — the
  /// no-current-model repro.
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
    // Helper can never reconcile a resident model. The model-menu path keys on
    // the chat's pin regardless, but keep the harness from depending on it.
    app.launchEnvironment["PIE_TEST_ENGINE_BASE_URL"] = "http://127.0.0.1:9"
    configureCompletedFirstLaunch(app, suiteName: stablePreferenceSuiteName(pieHome))
    app.launch()

    XCTAssert(app.wait(for: .runningForeground, timeout: 10),
              "Rational.app did not reach runningForeground")
    app.activate()
    openFreshChat(in: app)
    return app
  }

  /// Open the toolbar model menu and click the row whose stable identity
  /// (value/label/title) CONTAINS `leaf`. Retries the whole open→find→click
  /// under a contended seated session (focus can transiently drop — S426/S459
  /// idiom). Returns true once the row was clicked and the menu dismissed.
  @MainActor
  private func pickModelMenuRow(containingLeaf leaf: String,
                                modelMenu: XCUIElement,
                                in app: XCUIApplication) -> Bool {
    let deadline = Date().addingTimeInterval(45)
    while Date() < deadline {
      app.activate()
      modelMenu.click()
      let row = modelMenuRow(containingLeaf: leaf, in: app)
      if row.waitForExistence(timeout: 3), row.isHittable {
        row.click()
        return true
      }
      // Menu didn't open / row missing / not hittable — reset and retry.
      app.typeKey(.escape, modifierFlags: [])
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.5))
    }
    return false
  }

  /// A model-menu ROW (a `menuItem`, present only while the menu is open)
  /// matched by stable identity (value/label/title CONTAINS the slug leaf),
  /// never exact title (#460 flake convention). Scoped to `menuItems` so it
  /// never aliases the collapsed `toolbar.model` menu button, whose own
  /// accessibility value also carries the slug.
  private func modelMenuRow(containingLeaf leaf: String,
                            in app: XCUIApplication) -> XCUIElement {
    // #580: rows now render the structured quant tag, not the leaf, so the
    // stable target is the row's `ModelRow-<slug>` accessibility IDENTIFIER
    // (the slug contains the leaf). `identifier` surfaces on the NSMenuItem
    // where `value` does not. value/label/title kept as a fallback.
    let predicate = NSPredicate(
      format: "identifier CONTAINS[c] %@ OR value CONTAINS[c] %@ OR label CONTAINS[c] %@ OR title CONTAINS[c] %@",
      leaf, leaf, leaf, leaf)
    return app.menuItems.matching(predicate).firstMatch
  }

  // MARK: - polling helpers (shared idiom with S459/S426)

  private func waitForElementValueContaining(_ element: XCUIElement,
                                             _ needle: String,
                                             timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      let value = (element.value as? String) ?? ""
      if value.localizedCaseInsensitiveContains(needle)
        || element.title.localizedCaseInsensitiveContains(needle) { return true }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.3))
    }
    return false
  }
}
