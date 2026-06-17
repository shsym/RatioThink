import XCTest
import AppKit

/// S511 — chat-list row geometry guard.
///
/// Repro class: the first chat row ("New Chat" + relative timestamp like
/// "47 seconds ago") visually collided with the next row. Functional GUI
/// tests miss this because every control stays present and clickable while
/// the rendered layout is wrong — so this suite asserts accessibility
/// FRAMES, not just existence:
///
///   1. rows are vertically ordered and pairwise non-overlapping,
///   2. each row's title and timestamp stay inside their own row,
///   3. no row's text intrudes into the next row's frame.
///
/// Runs against an isolated `PIE_HOME` (real /tmp path — the sandboxed
/// runner's NSTemporaryDirectory() is unwritable for the app) and seeds
/// rows through the real "New Chat" affordance plus failed sends. Empty
/// draft chats are intentionally singletons under #512 lifecycle pruning, so
/// a geometry guard that needs several rows must make each seeded row a real
/// conversation before asking for the next draft.
///
/// Geometry checks accumulate and raise ONE terminal failure per
/// `assertRowGeometry` call, AFTER attaching a window screenshot and
/// printing a frame dump — the suite runs with continueAfterFailure=false
/// (a failed seed must abort), so diagnostics have to precede the fail.
///
/// Follow-up (#507 / PR #114): once the per-chat streaming spinner
/// (`chats.row.streaming`) lands in the chat list, extend `assertRowGeometry`
/// to include spinner frames in the containment + non-intrusion checks.
final class S511_ChatListGeometryGUITests: XCTestCase {
  private var tempHomes: [String] = []

  override func setUp() async throws {
    try guardSeatedGUI()
    // A failed seed or geometry check makes every later assertion in the
    // same test misattributed noise — stop at the first failure.
    continueAfterFailure = false
  }

  override func tearDown() {
    for home in tempHomes {
      try? FileManager.default.removeItem(atPath: home)
    }
    tempHomes.removeAll()
    super.tearDown()
  }

  private func makeApp() -> XCUIApplication {
    let app = XCUIApplication(bundleIdentifier: "com.ratiothink.app")
    app.launchArguments.append(contentsOf: [
      "-NSQuitAlwaysKeepsWindows", "NO",
      "-ApplePersistenceIgnoreState", "YES",
    ])
    configureCompletedFirstLaunch(app)
    let home = "/tmp/pie-s511-" + UUID().uuidString
    tempHomes.append(home)
    app.launchEnvironment["PIE_HOME"] = home
    app.launchEnvironment["PIE_TEST_CHAT_MODEL_PIN"] = "s511-deterministic"
    app.launchEnvironment["PIE_TEST_PIN_ENGINE_RUNNING"] = "1"
    app.launchEnvironment["PIE_TEST_ENGINE_BASE_URL"] = "http://127.0.0.1:9"
    app.launchEnvironment["PIE_TEST_PIN_HELPER_HEALTH"] = "healthy"
    return app
  }

  /// Create `count` real chats through the header affordance. The closed
  /// engine URL makes each send fail after the user turn is saved and
  /// auto-titled, giving deterministic rows without a live engine.
  @MainActor
  private func seedChats(_ count: Int, in app: XCUIApplication) {
    let newButton = app.buttons["chats.newButton"]
    XCTAssertTrue(newButton.waitForExistence(timeout: 5),
                  "chat list header New Chat affordance missing")
    let rows = app.descendants(matching: .any).matching(identifier: "chats.row")
    for i in 1...count {
      // Space clicks past the host double-click interval so repeated header
      // clicks cannot coalesce into a swallowed double-click.
      let clickSpacing = max(NSEvent.doubleClickInterval, 0.4) + 0.1
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(clickSpacing))
      newButton.click()
      let deadline = Date().addingTimeInterval(5)
      while rows.count < i && Date() < deadline {
        usleep(200_000)
      }
      XCTAssertEqual(rows.count, i, "chat \(i) did not appear after New Chat click")
      let title = "Geometry seed chat \(i)"
      typeComposerText(title, in: app)
      let send = app.buttons["composer.send"]
      XCTAssertTrue(send.waitForExistence(timeout: 5),
                    "composer.send missing while seeding chat \(i); app tree: \(app.debugDescription)")
      XCTAssertTrue(send.isEnabled,
                    "composer.send disabled while seeding chat \(i); app tree: \(app.debugDescription)")
      send.click()
      XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 10),
                    "chat \(i) did not auto-title after failed send; app tree: \(app.debugDescription)")
    }
  }

  /// Frames of every element with `identifier`, top-to-bottom. Rows and
  /// their texts share per-kind identifiers; vertical order recovers the
  /// row pairing. (Per-row `descendants` lookups are NOT used — with
  /// duplicate identifiers XCUITest resolves them against a re-taken
  /// snapshot and can return a SIBLING row's child.)
  @MainActor
  private func sortedFrames(_ identifier: String, in app: XCUIApplication) -> [CGRect] {
    let query = app.descendants(matching: .any).matching(identifier: identifier)
    return (0..<query.count)
      .map { query.element(boundBy: $0).frame }
      .sorted { $0.minY < $1.minY }
  }

  @MainActor
  private func attachScreenshot(_ app: XCUIApplication, name: String) {
    let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
    shot.name = name
    shot.lifetime = .keepAlways
    add(shot)
  }

  /// Core geometry contract over the current row set. `epsilon` absorbs
  /// AppKit half-pixel rounding in accessibility frames.
  @MainActor
  private func assertRowGeometry(
    in app: XCUIApplication,
    expectedRows: Int,
    context: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let epsilon: CGFloat = 1.0
    let frames = sortedFrames("chats.row", in: app)
    guard frames.count == expectedRows else {
      attachScreenshot(app, name: "s511-\(context)-row-count")
      XCTFail("[\(context)] expected \(expectedRows) chat rows, got \(frames.count); " +
              "tree: \(app.debugDescription)", file: file, line: line)
      return
    }

    // Accumulate failures and raise ONE XCTFail at the end: the suite runs
    // with continueAfterFailure=false, so a per-check XCTFail would halt
    // the test before the screenshot + frame-dump diagnostics below run.
    var failures: [String] = []
    func check(_ condition: Bool, _ message: String) {
      if !condition {
        failures.append(message)
      }
    }

    let windowFrame = app.windows.firstMatch.frame
    for frame in frames {
      check(!frame.isEmpty, "chat row has empty accessibility frame")
      // #511's root-cause symptom was the whole hosting view drifting
      // offscreen while rows stayed mutually consistent in AX coordinates
      // — row-relative checks alone could pass that state.
      check(windowFrame.intersects(frame),
            "chat row (\(frame)) is outside the window (\(windowFrame))")
    }

    // 1. Rows are vertically ordered and pairwise non-overlapping.
    for i in 0..<(frames.count - 1) {
      let upper = frames[i], lower = frames[i + 1]
      check(upper.maxY <= lower.minY + epsilon,
            "row \(i) (\(upper)) overlaps row \(i + 1) (\(lower))")
    }

    // 2+3. Every title and timestamp stays VERTICALLY inside its own row
    // (paired by vertical order) and never intrudes into the following
    // row. Vertical-only on purpose: the live relative timestamp widens
    // over time ("now" → "47 seconds ago") between AX snapshots, so a
    // horizontal check races text growth; the overlap class under guard
    // is vertical.
    for childID in ["chats.row.title", "chats.row.timestamp"] {
      let childFrames = sortedFrames(childID, in: app)
      check(childFrames.count == expectedRows,
            "expected \(expectedRows) \(childID) elements, got \(childFrames.count)")
      guard childFrames.count == expectedRows else { continue }
      for (i, childFrame) in childFrames.enumerated() {
        let rowFrame = frames[i]
        check(childFrame.minY >= rowFrame.minY - epsilon
                && childFrame.maxY <= rowFrame.maxY + epsilon,
              "row \(i) \(childID) (\(childFrame)) escapes its row vertically (\(rowFrame))")
        if i + 1 < frames.count {
          check(childFrame.maxY <= frames[i + 1].minY + epsilon,
                "row \(i) \(childID) (\(childFrame)) intrudes into row \(i + 1) (\(frames[i + 1]))")
        }
      }
    }

    if !failures.isEmpty {
      attachScreenshot(app, name: "s511-\(context)-geometry-failure")
      // Frame dump for quick diagnosis without replaying the run.
      for (i, frame) in frames.enumerated() {
        print("[s511] \(context) row[\(i)] frame=\(frame)")
      }
      XCTFail("[\(context)] \(failures.joined(separator: "\n"))",
              file: file, line: line)
    }
  }

  /// Default sidebar width: seeded rows (first row = freshly created
  /// "New Chat" + seconds-old timestamp, the observed collision shape)
  /// must stack without overlap in both selected and unselected states.
  @MainActor
  func test_chat_rows_do_not_overlap_at_default_width() async throws {
    let app = makeApp()
    app.launch()
    defer { app.terminate() }
    XCTAssert(app.wait(for: .runningForeground, timeout: 5))
    app.activate()

    let window = app.windows.firstMatch
    XCTAssertTrue(window.waitForExistence(timeout: 5), "main window missing")

    seedChats(3, in: app)
    let firstRow = app.descendants(matching: .any)
      .matching(identifier: "chats.row").firstMatch
    XCTAssertTrue(firstRow.waitForExistence(timeout: 5), "no chat rows rendered")

    // Creating a chat selects it, so the last-created (top) row is the
    // selected state; the rest are unselected — both states covered.
    assertRowGeometry(in: app, expectedRows: 3, context: "default-width")

    // Selecting a different row must not disturb the stack. Click the
    // second row by its frame (window-anchored coordinate — the rows share
    // one identifier, so element-targeted clicks are snapshot-unstable).
    let frames = sortedFrames("chats.row", in: app)
    if frames.count > 1 {
      window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        .withOffset(CGVector(dx: frames[1].midX - window.frame.minX,
                             dy: frames[1].midY - window.frame.minY))
        .click()
      assertRowGeometry(in: app, expectedRows: 3, context: "default-width-reselected")
    }
  }

  /// Second width point + a real resize pass: geometry must hold at the
  /// launch width and again after the split view re-lays out at a different
  /// width. The relayout is the regression trigger class for #511's root
  /// cause (a re-render while the helper-recovery overlay is up compounded
  /// the layout height), so geometry must hold both before and after.
  ///
  /// The resize is driven by the DEBUG-only "Shrink Window (Test)" menu
  /// command, NOT Window ▸ Zoom or an external resize gesture. Zoom no-ops
  /// when the window already fills the screen (the constrained/maximized seat,
  /// where the old precondition failed 1920 == 1920 before any geometry was
  /// checked); a synthesized corner-drag silently misses the few-point resize
  /// border (observed 1200 == 1200); and the public Accessibility set-size API
  /// is APIDisabled for the XCUITest runner. The menu command resizes the key
  /// window in-process — the one resize trigger XCUITest fires reliably — and
  /// is floored at the 900pt window minimum, so it always yields a real width
  /// change that drives the split-view relayout this test guards.
  @MainActor
  func test_chat_rows_do_not_overlap_across_zoom_resize() async throws {
    let app = makeApp()
    app.launch()
    defer { app.terminate() }
    XCTAssert(app.wait(for: .runningForeground, timeout: 5))
    app.activate()

    let window = app.windows.firstMatch
    XCTAssertTrue(window.waitForExistence(timeout: 5), "main window missing")

    seedChats(3, in: app)
    assertRowGeometry(in: app, expectedRows: 3, context: "launch-width")

    let widthBefore = window.frame.width
    // A Shrink of 200pt floors at the 900pt minimum, so a launch width ≤ 1100
    // would make the resize a no-op; fail that as its own precondition rather
    // than mis-attributing it to the resize step below.
    XCTAssertGreaterThan(widthBefore, 1100,
                         "seat too narrow for Shrink to clear the 900pt floor")
    // The DEBUG menu command shrinks the key window's width (floored at the
    // 900pt minimum); from any launch width the app ships (≥ the 1200 default)
    // this is always a real change.
    app.menuBars.menuBarItems["Debug"].click()
    XCTAssertTrue(app.menuBars.menuItems["Shrink Window (Test)"].waitForExistence(timeout: 2),
                  "Debug ▸ Shrink Window (Test) missing — DEBUG build required")
    app.menuBars.menuItems["Shrink Window (Test)"].click()
    let deadline = Date().addingTimeInterval(5)
    while window.frame.width == widthBefore && Date() < deadline {
      usleep(200_000)
    }
    XCTAssertLessThan(window.frame.width, widthBefore,
                      "Shrink Window (Test) did not resize the window; cannot exercise relayout")

    assertRowGeometry(in: app, expectedRows: 3, context: "resized-width")
  }
}
