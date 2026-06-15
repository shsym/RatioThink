import XCTest

/// S530 — rapid chat-switching main-thread responsiveness guard (regression
/// cover for the #521 transcript hang).
///
/// Before #521, `TranscriptView` sorted `chat.messages` several times per body
/// evaluation and rendered SwiftData `@Model Message` rows directly in the
/// SwiftUI identity/layout hot path. The operator-reported symptom was a
/// main-thread hang when switching fast between conversations. The fix projects
/// one cheap `TranscriptSnapshot` of value rows per body. No automated test
/// exercised that "switch fast between chats" pattern — this is that test.
///
/// Mechanism (fully deterministic, engine-free):
///   1. `PIE_TEST_SEED_TRANSCRIPTS=N` seeds N persisted chats, each with a long
///      mixed-role transcript (`TranscriptStressSeed`) carrying a unique,
///      collision-free per-chat tag in every turn.
///   2. `PIE_TEST_STALL_WATCHDOG=1` installs a main-run-loop probe that records
///      `max,total,count` main-thread stall metrics and mirrors them to the
///      `PIE_TEST_STALL_WATCHDOG_FILE` probe file.
///   3. The test storms through every seeded chat, then verifies each chat
///      still switches in and renders ITS content, and reads the stall probe.
///
/// IMPORTANT — what this guard does and does NOT catch. It reproduces the
/// operator workflow that previously had ZERO automated coverage and asserts
/// correctness (every chat renders the right transcript after the storm) plus a
/// no-wedge responsiveness ceiling. It is NOT tuned to flag the *specific*
/// pre-#521 micro-pattern: XCUITest synchronizes on app-idle after every click,
/// so each switch's cost is dominated by view layout that is identical on both
/// code paths. Reverting `TranscriptView` to the 4×-sort + @Model-`ForEach`
/// pattern was measured against this guard (and against an in-process streaming
/// variant) and produced cumulative main-thread stall statistically
/// indistinguishable from the fixed build — on this hardware/OS the isolated
/// churn is dwarfed by layout and is not a measurable black-box stall, matching
/// the ticket's note that the original spindump was not locally reproducible.
/// The stall ceiling is therefore a CATASTROPHIC-regression backstop (a true
/// hang / order-of-magnitude render blowup, e.g. an O(n²) render path),
/// calibrated from the measured baseline with generous margin. The single-sort
/// projection invariant is pinned structurally by `TranscriptSnapshotTests`, and
/// mid-stream switch continuity by S507's stream-cancel E2E.
final class S530_RapidChatSwitchGUITests: XCTestCase {
  /// Catastrophic-wedge ceiling (ms) for cumulative main-thread stall across the
  /// switch storm. Measured baseline on the current build is ~17 s of summed
  /// stall over 30 settled switches (each switch's layout dominates and is
  /// identical on both code paths, so this metric does NOT separate the buggy
  /// micro-pattern at this scale — see the type doc). Set to ~3.5× baseline so
  /// only a gross wedge / order-of-magnitude per-switch blowup trips it.
  private static let switchStormStallCeilingMs = 60_000

  /// Per-switch UI-settle ceiling (ms): a switch that never renders its target
  /// within this is a hard hang (also absorbs occasional harness re-activation).
  private static let perSwitchSettleBudgetMs = 15_000

  private let chatCount = 10
  private let passes = 3

  override func setUp() async throws {
    try guardSeatedGUI()
    continueAfterFailure = false
  }

  @MainActor
  func test_rapid_switching_renders_every_chat_without_hang() throws {
    let pieHome = "/tmp/pie-s530-" + UUID().uuidString
    let stallProbe = pieHome + "-stall.txt"
    defer {
      try? FileManager.default.removeItem(atPath: pieHome)
      try? FileManager.default.removeItem(atPath: stallProbe)
    }

    let app = XCUIApplication(bundleIdentifier: "com.ratiothink.app")
    app.launchArguments.append(contentsOf: [
      "-NSQuitAlwaysKeepsWindows", "NO",
      "-ApplePersistenceIgnoreState", "YES",
    ])
    app.launchEnvironment["PIE_HOME"] = pieHome
    app.launchEnvironment["PIE_TEST_SEED_TRANSCRIPTS"] = "\(chatCount)"
    app.launchEnvironment["PIE_TEST_STALL_WATCHDOG"] = "1"
    app.launchEnvironment["PIE_TEST_STALL_WATCHDOG_FILE"] = stallProbe
    // Pin the engine running against a closed URL so the chat surface mounts
    // normally (no "no model" gate) without a live engine — the guard only
    // switches between already-seeded transcripts, it never sends.
    app.launchEnvironment["PIE_TEST_CHAT_MODEL_PIN"] = "s530-deterministic"
    app.launchEnvironment["PIE_TEST_PIN_ENGINE_RUNNING"] = "1"
    app.launchEnvironment["PIE_TEST_ENGINE_BASE_URL"] = "http://127.0.0.1:9"
    app.launchEnvironment["PIE_TEST_PIN_HELPER_HEALTH"] = "healthy"
    configureCompletedFirstLaunch(app, suiteName: stablePreferenceSuiteName(pieHome))

    // Launch + re-activate until a sidebar landmark is genuinely hittable, so a
    // later launch in the full GUI matrix that comes up not-key (whole AX tree
    // reads Disabled) doesn't make every row click land on a dead tree (#545).
    defer { app.terminate() }
    app.launchActivated(landmark: { $0.buttons["Chats"].firstMatch })

    let chatList = app.descendants(matching: .any)
      .matching(identifier: "chats.list").firstMatch
    XCTAssertTrue(chatList.waitForExistence(timeout: 15),
                  "chat list missing; seed did not populate? app tree: \(app.debugDescription)")

    // All seeded rows must be present before the storm.
    let rows = app.descendants(matching: .any).matching(identifier: "chats.row")
    let rowsDeadline = Date().addingTimeInterval(15)
    while rows.count < chatCount && Date() < rowsDeadline {
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.25))
    }
    XCTAssertEqual(rows.count, chatCount,
                   "expected \(chatCount) seeded chat rows, got \(rows.count); app tree: \(app.debugDescription)")

    let titledRows: [(Int, XCUIElement)] = (1...chatCount).map { i in
      (i, chatList.staticTexts[seedTitle(i)].firstMatch)
    }

    // Storm: click through every chat back-to-back for several passes.
    var clicks = 0
    for _ in 0..<passes {
      for (_, row) in titledRows {
        if row.isHittable { row.click(); clicks += 1 }
        usleep(60_000)
      }
    }
    let metrics = readStallProbe(at: stallProbe)
    print("[s530] storm clicks=\(clicks) max=\(metrics.max)ms total=\(metrics.total)ms count=\(metrics.count) ceiling=\(Self.switchStormStallCeilingMs)ms")

    // Every chat must still switch in and render ITS unique content — the storm
    // left the UI responsive and correct, not wedged or showing a stale chat.
    for (i, row) in titledRows {
      let settled = switchToChat(row: row, needle: seedNeedle(i), in: app,
                                 timeout: TimeInterval(Self.perSwitchSettleBudgetMs) / 1000)
      XCTAssertTrue(settled,
                    "after the storm, chat \(i) needle '\(seedNeedle(i))' did not render within "
                      + "\(Self.perSwitchSettleBudgetMs)ms — the UI is wedged; app tree: \(app.debugDescription)")
    }

    XCTAssertGreaterThanOrEqual(metrics.total, 0,
                                "stall-watchdog probe '\(stallProbe)' missing — watchdog not installed?")
    XCTAssertLessThan(metrics.total, Self.switchStormStallCeilingMs,
                      "rapid switching wedged the main thread: \(metrics.total)ms cumulative stall "
                        + "(ceiling \(Self.switchStormStallCeilingMs)ms) — the #521 transcript churn may be back")
  }

  // MARK: - helpers

  /// Read the `max,total,count` main-thread stall metrics the watchdog mirrored
  /// to its probe file. Polls briefly so a final off-main-thread flush can land.
  /// Returns all -1 when the file never appears (watchdog not installed).
  private func readStallProbe(at path: String) -> (max: Int, total: Int, count: Int) {
    let deadline = Date().addingTimeInterval(5)
    repeat {
      if let text = try? String(contentsOfFile: path, encoding: .utf8) {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ",")
        if parts.count == 3, let mx = Int(parts[0]), let tot = Int(parts[1]), let cnt = Int(parts[2]) {
          return (mx, tot, cnt)
        }
      }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
    } while Date() < deadline
    return (-1, -1, -1)
  }

  /// Click a chat row and confirm the target transcript rendered (message bodies
  /// are `.textView`s — see `transcriptTextMatchCount`). Re-activates + re-clicks
  /// only as a stuck-fallback so the common path adds no `app.activate()`
  /// main-thread work that would pollute the stall measurement (#545).
  @MainActor
  private func switchToChat(
    row: XCUIElement, needle: String, in app: XCUIApplication, timeout: TimeInterval
  ) -> Bool {
    if row.isHittable { row.click() }
    var lastClick = Date()
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if transcriptTextMatchCount(needle, in: app) >= 1 { return true }
      if Date().timeIntervalSince(lastClick) > 3.0 {
        app.activate()
        if row.isHittable { row.click() }
        lastClick = Date()
      }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
    }
    return false
  }

  // Mirror the seed's stable title/needle derivation (the GUI suite links the
  // test bundle, not the App sources). Kept in lockstep with
  // `TranscriptStressSeed.title(forChat:)` / `.needle(forChat:)`.
  private func seedTitle(_ i: Int) -> String { String(format: "Stress Chat %02d", i) }
  private func seedNeedle(_ i: Int) -> String { String(format: "chatTAG%02d", i) }
}
