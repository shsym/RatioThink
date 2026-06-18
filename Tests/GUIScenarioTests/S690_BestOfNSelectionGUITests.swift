import XCTest

/// S690 — Best-of-N interactive selection (seated GUI).
///
/// Drives the real app through one Best-of-N round and asserts the interactive
/// behavior the headless tests can't (#690/#708): the round renders its N
/// candidates inline as tap-to-select options, the user PICKS one (highlighted)
/// while siblings stay re-pickable, RE-PICKS a different one, then commits with
/// "Use this" — after which the round renders READ-ONLY (chosen still
/// highlighted, no pick affordance).
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
/// an accessibility identifier (`bestofn.candidate.<i>.<state>`), so the seated
/// test asserts the state transitions the emphasis encodes. The run is repeated
/// under the light and dark appearance launch args; the structural assertions
/// hold in both (and the run proves the flow works seated regardless of whether
/// AppKit honors the appearance override).
final class S690_BestOfNSelectionGUITests: XCTestCase {

  override func setUp() async throws {
    try guardSeatedGUI()
    continueAfterFailure = false
  }

  @MainActor
  func test_pick_reselect_commit_and_readonly_history_light() throws {
    try runSelectionFlow(appearance: "Light")
  }

  @MainActor
  func test_pick_reselect_commit_and_readonly_history_dark() throws {
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
    // #708 native tap-to-select: each candidate is itself the pick target (no
    // per-option "Select" button); the WHOLE card — header AND answer body —
    // exposes a `bestofn.option.<i>` identifier and tapping anywhere on it picks.
    func optionRow(_ idx: Int) -> XCUIElement {
      app.descendants(matching: .any)
        .matching(identifier: "bestofn.option.\(idx)").firstMatch
    }
    for idx in 0..<n {
      XCTAssertTrue(optionRow(idx).waitForExistence(timeout: 5),
                    "[\(appearance)] candidate \(idx) option row missing before a choice; app tree: \(app.debugDescription)")
    }
    // #708 thinking ON: each candidate now generates reasoning, which the demux
    // routes onto the reasoning channel, so every candidate row renders the
    // folded "Thinking" disclosure beside its clean answer. Assert the
    // disclosure exists for each candidate and the answer text is present and
    // carries no `<think>` markup (the reasoning is demuxed out, not inline).
    func thinkingDisclosure(_ idx: Int) -> XCUIElement {
      app.descendants(matching: .any)
        .matching(identifier: "bestofn.candidate.\(idx).thinking").firstMatch
    }
    for idx in 0..<n {
      XCTAssertTrue(thinkingDisclosure(idx).waitForExistence(timeout: 10),
                    "[\(appearance)] candidate \(idx) must render its reasoning 'Thinking' disclosure (#708 thinking ON); app tree: \(app.debugDescription)")
    }
    XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "<think>")).firstMatch.exists,
                   "[\(appearance)] no candidate answer may show raw <think> markup — reasoning is demuxed onto its own channel")

    // #708 flat layout: a candidate has NO headline/title — its answer is shown
    // once, flat in the body. (A prior layout repeated `node.content` as a
    // header preview above the full-answer detail, showing it twice.) A live
    // pickable candidate is one Button, so its child Texts flatten into the
    // Button's accessibility label; a re-introduced headline would make the
    // answer appear twice in that one label. Assert the first candidate's answer
    // (BestOfNRoundSeed.candidateTexts[0]) occurs exactly once in its row label.
    let firstAnswer = "Go for a long walk in a nearby park and bring a book to read on a bench."
    let optionLabel = optionRow(0).label
    let answerOccurrences = optionLabel.components(separatedBy: firstAnswer).count - 1
    XCTAssertEqual(answerOccurrences, 1,
                   "[\(appearance)] flat candidate answer must appear exactly once (no headline/title duplicating the body); found \(answerOccurrences) in option label: \(optionLabel)")

    // The dropped Select buttons must be gone everywhere.
    XCTAssertFalse(app.descendants(matching: .any)
      .matching(identifier: "bestofn.select.0").firstMatch.exists,
      "[\(appearance)] per-option Select buttons must be dropped (#708)")
    // No commit affordances until a candidate is chosen.
    XCTAssertFalse(app.buttons["bestofn.useThis"].exists,
                   "[\(appearance)] 'Use this' must not appear before a choice")

    // #708 click-to-select: pick candidate 1 by tapping its ANSWER BODY (the
    // lower region of the card), not the headline — the whole card is the pick
    // target, so a tap on the answer text must select rather than do nothing.
    let chosenIdx = 1
    optionRow(chosenIdx).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap()

    // The chosen row flips to `chosen` (highlighted). #708 click-to-reselect:
    // the OTHER candidates stay `pickable` (NOT dimmed/`unpicked`) so the user
    // can freely re-pick a different one — the live round never locks in.
    XCTAssertTrue(stateMarker(chosenIdx, "chosen").waitForExistence(timeout: 10),
                  "[\(appearance)] picked candidate \(chosenIdx) must become 'chosen' (highlighted); "
                    + "app tree: \(app.debugDescription)")
    for idx in 0..<n where idx != chosenIdx {
      XCTAssertTrue(stateMarker(idx, "pickable").waitForExistence(timeout: 5),
                    "[\(appearance)] sibling candidate \(idx) must stay 'pickable' for re-selection; app tree: \(app.debugDescription)")
    }

    // The commit affordances — Think more / Use this — appear once a candidate
    // is chosen. The short-lived 'Go back' button is gone (#708): re-selection
    // is by tapping another candidate, not a dedicated control.
    XCTAssertTrue(app.buttons["bestofn.thinkMore"].waitForExistence(timeout: 5),
                  "[\(appearance)] 'Think more' affordance must appear after a choice")
    XCTAssertTrue(app.buttons["bestofn.useThis"].exists,
                  "[\(appearance)] 'Use this' affordance must appear after a choice")
    XCTAssertFalse(app.buttons["bestofn.goBack"].exists,
                   "[\(appearance)] 'Go back' must be gone — re-pick by tapping a candidate (#708)")

    // #708 click-to-reselect: tap a DIFFERENT candidate → the choice moves to it,
    // the previously-chosen returns to `pickable`, and the controls persist.
    let reselectIdx = 2
    optionRow(reselectIdx).click()
    XCTAssertTrue(stateMarker(reselectIdx, "chosen").waitForExistence(timeout: 10),
                  "[\(appearance)] re-picked candidate \(reselectIdx) must become 'chosen'; app tree: \(app.debugDescription)")
    XCTAssertTrue(stateMarker(chosenIdx, "pickable").waitForExistence(timeout: 5),
                  "[\(appearance)] previously-chosen candidate \(chosenIdx) must return to 'pickable' after re-select")
    XCTAssertTrue(app.buttons["bestofn.useThis"].exists,
                  "[\(appearance)] commit affordances persist across a re-selection")

    // #708 finalized round: committing with 'Use this' shows the chosen answer
    // as a normal content bubble, the interactive controls disappear, and the N
    // options stay available behind a DEFAULT-FOLDED Options disclosure.
    app.buttons["bestofn.useThis"].click()
    XCTAssertTrue(waitForDisappearance(app.buttons["bestofn.useThis"], timeout: 10),
                  "[\(appearance)] 'Use this' must disappear once the round is committed")
    XCTAssertFalse(app.buttons["bestofn.thinkMore"].exists,
                   "[\(appearance)] 'Think more' must disappear once the round is committed")

    // The selected answer is visible as the committed bubble.
    let committedAnswer = "Take a day trip to a town one train ride away and wander with no fixed plan."
    let answerVisible = app.descendants(matching: .any)
      .matching(NSPredicate(format: "value == %@ OR label == %@", committedAnswer, committedAnswer)).firstMatch
    XCTAssertTrue(answerVisible.waitForExistence(timeout: 10),
                  "[\(appearance)] the selected answer must be visible as the committed bubble; app tree: \(app.debugDescription)")

    // The Options disclosure remains, DEFAULT-FOLDED — the candidate rows are
    // not rendered until the user expands it on-demand.
    let disclosure = app.descendants(matching: .any)
      .matching(identifier: "bestofn.disclosure").firstMatch
    XCTAssertTrue(disclosure.waitForExistence(timeout: 5),
                  "[\(appearance)] the Options disclosure must remain available on a finalized round")
    XCTAssertFalse(optionRow(reselectIdx).exists,
                   "[\(appearance)] the Options disclosure must be folded by default once the answer commits; app tree: \(app.debugDescription)")

    // Expanding it reveals ALL N candidates, the chosen one highlighted and the
    // rest read-only (not pickable).
    disclosure.click()
    XCTAssertTrue(stateMarker(reselectIdx, "chosen").waitForExistence(timeout: 5),
                  "[\(appearance)] the committed choice \(reselectIdx) must be highlighted when the options are expanded; app tree: \(app.debugDescription)")
    for idx in 0..<n {
      XCTAssertTrue(optionRow(idx).waitForExistence(timeout: 5),
                    "[\(appearance)] all \(n) candidates must stay available behind the Options disclosure; candidate \(idx) missing; app tree: \(app.debugDescription)")
      XCTAssertFalse(stateMarker(idx, "pickable").exists,
                     "[\(appearance)] finalized candidate \(idx) must not be pickable")
    }
    XCTAssertFalse(app.buttons["bestofn.useThis"].exists,
                   "[\(appearance)] expanding finalized options must not resurrect the commit controls")
  }

  /// Poll until an element no longer exists (XCUITest has no built-in
  /// wait-for-absence).
  private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if !element.exists { return true }
      usleep(200_000)
    }
    return !element.exists
  }
}
