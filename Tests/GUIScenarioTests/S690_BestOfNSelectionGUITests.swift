import XCTest

/// S690 — Best-of-N interactive selection (seated GUI).
///
/// Drives the real app through one Best-of-N round and asserts the interactive
/// behavior the headless tests can't: the round renders its N candidates inline,
/// the user SELECTS one, the unpicked siblings COLLAPSE, and the chosen one is
/// emphasized while the think-more / use-this commit affordances appear.
///
/// Engine-free + deterministic: `PIE_TEST_SEED_BESTOFN` seeds one persisted,
/// uncommitted Best-of-N round (`BestOfNRoundSeed`) — a sandboxed XCUITest can't
/// spawn pie or write `PIE_HOME`, so the round is canned but built through the
/// exact `ToTTree.apply` event path a live round uses.
///
/// The chosen-vs-unpicked EMPHASIS is built from adaptive `Color.accentColor` +
/// alpha, which reads correctly in light and dark — that color correctness is
/// asserted headlessly by `BestOfNHighlightSnapshotTests` (XCUITest cannot read
/// pixel color). Here each candidate row instead exposes its selection state as
/// an accessibility VALUE (`pickable` → `chosen` / `unpicked`), so the seated
/// test asserts the state transition the emphasis encodes. The run is repeated
/// under the light and dark appearance launch args; the structural assertions
/// hold in both (and the run proves the flow works seated regardless of whether
/// AppKit honors the appearance override).
final class S690_BestOfNSelectionGUITests: XCTestCase {

  override func setUp() async throws {
    try guardSeatedGUI()
    continueAfterFailure = false
  }

  @MainActor
  func test_select_collapses_unpicked_and_highlights_chosen_light() throws {
    try runSelectionFlow(appearance: "Light")
  }

  @MainActor
  func test_select_collapses_unpicked_and_highlights_chosen_dark() throws {
    try runSelectionFlow(appearance: "Dark")
  }

  /// One full selection round under the given system appearance.
  @MainActor
  private func runSelectionFlow(appearance: String) throws {
    let n = 3
    let pieHome = "/tmp/pie-s690-" + UUID().uuidString
    defer { try? FileManager.default.removeItem(atPath: pieHome) }

    let app = XCUIApplication(bundleIdentifier: "com.ratiothink.app")
    app.launchArguments.append(contentsOf: [
      "-NSQuitAlwaysKeepsWindows", "NO",
      "-ApplePersistenceIgnoreState", "YES",
      // Appearance override — AppKit may ignore it, but the structural
      // assertions are appearance-independent, so the run is valid either way.
      "-AppleInterfaceStyle", appearance,
      "-NSRequiresAquaSystemAppearance", appearance == "Dark" ? "NO" : "YES",
    ])
    app.launchEnvironment["PIE_HOME"] = pieHome
    app.launchEnvironment["PIE_TEST_SEED_BESTOFN"] = "\(n)"
    // Pin the engine running against a closed URL so the chat surface mounts
    // (no "no model" gate) without a live engine — the test only picks among
    // already-seeded candidates, it never sends a round.
    app.launchEnvironment["PIE_TEST_CHAT_MODEL_PIN"] = "s690-deterministic"
    app.launchEnvironment["PIE_TEST_PIN_ENGINE_RUNNING"] = "1"
    app.launchEnvironment["PIE_TEST_ENGINE_BASE_URL"] = "http://127.0.0.1:9"
    app.launchEnvironment["PIE_TEST_PIN_HELPER_HEALTH"] = "healthy"
    configureCompletedFirstLaunch(app, suiteName: stablePreferenceSuiteName(pieHome))

    defer { app.terminate() }
    app.launchActivated(landmark: { $0.buttons["Chats"].firstMatch })

    // Open the seeded round's chat.
    selectPersistedChat(titled: "Best of N Round", in: app)

    // Each candidate row encodes its selection state in its accessibility
    // identifier (`bestofn.candidate.<i>.<state>`). The round renders N panes,
    // each `pickable` before a choice.
    func stateMarker(_ idx: Int, _ state: String) -> XCUIElement {
      app.descendants(matching: .any)
        .matching(identifier: "bestofn.candidate.\(idx).\(state)").firstMatch
    }
    for idx in 0..<n {
      XCTAssertTrue(stateMarker(idx, "pickable").waitForExistence(timeout: 15),
                    "[\(appearance)] candidate \(idx) did not render as pickable; app tree: \(app.debugDescription)")
    }
    // Every candidate offers a Select control before a choice.
    for idx in 0..<n {
      let select = app.descendants(matching: .any)
        .matching(identifier: "bestofn.select.\(idx)").firstMatch
      XCTAssertTrue(select.waitForExistence(timeout: 5),
                    "[\(appearance)] candidate \(idx) Select control missing before a choice; app tree: \(app.debugDescription)")
    }
    // No commit affordances until a candidate is chosen.
    XCTAssertFalse(app.buttons["bestofn.useThis"].exists,
                   "[\(appearance)] 'Use this' must not appear before a choice")

    // Pick candidate 1.
    let chosenIdx = 1
    app.descendants(matching: .any)
      .matching(identifier: "bestofn.select.\(chosenIdx)").firstMatch.click()

    // The chosen row flips to `chosen` (highlighted); every other row collapses
    // to `unpicked`.
    XCTAssertTrue(stateMarker(chosenIdx, "chosen").waitForExistence(timeout: 10),
                  "[\(appearance)] picked candidate \(chosenIdx) must become 'chosen' (highlighted); "
                    + "app tree: \(app.debugDescription)")
    for idx in 0..<n where idx != chosenIdx {
      XCTAssertTrue(stateMarker(idx, "unpicked").waitForExistence(timeout: 5),
                    "[\(appearance)] unpicked candidate \(idx) must collapse to 'unpicked'; app tree: \(app.debugDescription)")
      XCTAssertFalse(stateMarker(idx, "pickable").exists,
                     "[\(appearance)] unpicked candidate \(idx) must no longer be 'pickable'")
    }

    // The Select controls are gone (no re-pick), and the commit affordances —
    // Think more / Use this — appear under the chosen candidate.
    for idx in 0..<n {
      XCTAssertFalse(app.descendants(matching: .any)
        .matching(identifier: "bestofn.select.\(idx)").firstMatch.exists,
        "[\(appearance)] Select control \(idx) must disappear after a choice")
    }
    XCTAssertTrue(app.buttons["bestofn.thinkMore"].waitForExistence(timeout: 5),
                  "[\(appearance)] 'Think more' affordance must appear after a choice")
    XCTAssertTrue(app.buttons["bestofn.useThis"].exists,
                  "[\(appearance)] 'Use this' affordance must appear after a choice")
  }
}
