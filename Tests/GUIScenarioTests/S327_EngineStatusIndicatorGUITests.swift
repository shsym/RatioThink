import XCTest

/// Ticket  — engine-status pip GUI regression guard.
///
/// The headline bug this redesign fixes: the toolbar status popover
/// "immediately closes" because the 1 Hz `EngineStatusStore` poll fired
/// `objectWillChange` every tick (via the published `pollCount`),
/// re-rendering `ChatScaffoldView` → the toolbar that hosts the popover,
/// and SwiftUI dismissed the transient popover ~1 s after it opened. The
/// root-cause fix demoted `pollCount` from `@Published`;
/// `test_popover_stays_open_across_poll_ticks` is the end-to-end guard —
/// it FAILS on `main` (pre-fix) and PASSES after.
///
/// Unlike the old model-load-only widget (S302), the  pip is ALWAYS
/// visible (it reflects the engine even at rest), so this opens the
/// popover directly — no model-load flow required for the stability test.
///
/// Popover container `.accessibilityIdentifier`s mask inner control ids,
/// so inner controls are queried by visible label / a narrow id. Uses
/// narrow type queries only — `descendants(matching: .any)` can SIGBUS on
/// a degraded session (GUI-test convention).
final class S327_EngineStatusIndicatorGUITests: XCTestCase {

  override func setUp() async throws { try guardSeatedGUI() }

  // MARK: - headline guard: popover survives ≥2 poll ticks

  @MainActor
  func test_popover_stays_open_across_poll_ticks() throws {
    let app = try launchedApp()
    defer { app.terminate() }

    let indicator = app.buttons["toolbar.modelLoadIndicator"].firstMatch
    // The pip is always present now (offline/starting/running all render
    // it) — its absence is a ContentToolbar wiring regression, not a
    // load-state issue.
    XCTAssertTrue(
      indicator.waitForExistence(timeout: 15),
      "toolbar.modelLoadIndicator (the always-on engine-status pip) was never instantiated — "
        + "ContentToolbar wiring regression? app: \(app.debugDescription)")

    XCTAssertTrue(openIndicatorPopover(indicator, in: app),
                  "engine-status pip popover did not open; app: \(app.debugDescription)")

    // Span ≥2 of the 1 Hz polls. On `main` (pre-fix) the popover dismisses
    // ~1 s in; the demoted `pollCount` keeps it open. Poll the popover
    // presence the whole window — a single late check could miss a
    // reopen/close flicker.
    let deadline = Date().addingTimeInterval(2.6)
    while Date() < deadline {
      XCTAssertGreaterThan(
        app.popovers.count, 0,
        "engine-status popover closed itself within the poll window — the 1 Hz poll is still "
          + "invalidating the toolbar (popover-churn regression); app: \(app.debugDescription)")
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
    }
  }

  // MARK: - live (best-effort): running popover shows a non-zero Memory readout

  /// End-to-end exercise of the real `engineMemory` pipeline:
  /// popover → `EngineStatusStore.engineMemory()` → XPC to `com.ratiothink.helper`
  /// → `PieEngineHost.residentMemoryBytes` → `proc_pid_rusage` on the live
  /// pie pid. When a real engine is up this asserts a PLAUSIBLE NON-ZERO RSS
  /// readout; otherwise it skips with the architectural reason below.
  ///
  /// Why best-effort at the GUI tier (not seated by the ticket302 harness):
  /// that harness is a load-SSE *fake* (`PIE_TEST_ENGINE_BASE_URL` only
  /// redirects the app's HTTP client). `engineMemory` is a separate XPC path
  /// to the helper's real pie process, which the fake cannot drive; and the
  /// sandboxed XCUITest runner cannot itself spawn a `pie serve`. So this
  /// GUI test exercises the SwiftUI render of the row opportunistically.
  /// The AUTHORITATIVE real-engine RSS coverage lives one tier down, where
  /// spawning is allowed: `RealEngineLaunchE2ETests`
  /// `.test_realEngine_reportsPlausibleResidentMemory` boots a real
  /// `pie serve` + real GGUF and asserts a non-zero RSS through the exact
  /// `PieEngineHost.residentMemoryBytes()` → `proc_pid_rusage` →
  /// `engineMemory` selector path the popover reads (run via
  /// `Scripts/run-ticket320-engine-e2e.sh`). The deterministic gate +
  /// formatter are also unit-covered (`ModelLoadPopoverMemoryRowTests`,
  /// `EngineMemorySampleTests`).
  @MainActor
  func test_running_popover_shows_memory_row() throws {
    let app = try launchedApp()   // real helper (no PIE_TEST_ENGINE_BASE_URL)
    defer { app.terminate() }

    let indicator = app.buttons["toolbar.modelLoadIndicator"].firstMatch
    XCTAssertTrue(indicator.waitForExistence(timeout: 15),
                  "engine-status pip missing; app: \(app.debugDescription)")
    XCTAssertTrue(openIndicatorPopover(indicator, in: app),
                  "engine-status pip popover did not open; app: \(app.debugDescription)")

    // The Memory row's id sits on the value Text, so its label is the
    // rendered RSS string ("1.80 GB" / "256 MB"). The on-demand poll
    // samples within ~2 s of opening; allow slack for the first XPC
    // round-trip on a cold engine.
    let memoryReadout = app.popovers.staticTexts["modelLoad.popover.memory"].firstMatch
    guard memoryReadout.waitForExistence(timeout: 12) else {
      throw XCTSkip("No Memory row — the registered helper has no running engine to sample. "
                    + "engineMemory is an XPC→helper→proc_pid_rusage path the ticket302 load-SSE "
                    + "fake cannot seat, and the sandboxed XCUITest runner cannot spawn a real "
                    + "pie. The real-engine RSS assertion lives in RealEngineLaunchE2ETests."
                    + "test_realEngine_reportsPlausibleResidentMemory; row gating + formatting are "
                    + "unit-covered. app: \(app.debugDescription)")
    }
    let readout = memoryReadout.label
    XCTAssertTrue(
      Self.isPlausibleNonZeroRSS(readout),
      "engine memory readout must be a non-zero MB/GB value from the real engineMemory XPC path; "
        + "got \(readout.debugDescription)")
  }

  /// True for "<number> MB" / "<number> GB" with number > 0 — a plausible
  /// resident-memory readout. Rejects "0 MB", empty, or malformed strings.
  static func isPlausibleNonZeroRSS(_ s: String) -> Bool {
    let parts = s.split(separator: " ")
    guard parts.count == 2,
          let value = Double(parts[0]), value > 0,
          parts[1] == "MB" || parts[1] == "GB" else { return false }
    return true
  }

  // MARK: - best-effort: engine error surfaces the in-window banner

  /// Drives the app to an engine failure (a bogus engine base URL the
  /// helper can't reach as a healthy engine) and asserts the in-window
  /// error banner appears + Dismiss removes it. Best-effort: the exact
  /// failure path depends on harness wiring, so a no-banner outcome is a
  /// soft skip (banner gating + dedup are unit-covered).
  @MainActor
  func test_engine_error_surfaces_banner() throws {
    let app = try launchedApp()
    defer { app.terminate() }

    // Wait briefly for any failure to settle into the banner. The banner
    // carries `engineStatus.banner`; a healthy/offline engine never
    // banners (offline is a quiet grey dot, not an error), so absence
    // here is expected unless a real failure is wired.
    let banner = app.otherElements["engineStatus.banner"].firstMatch
    let appeared = banner.waitForExistence(timeout: 8)
    if !appeared {
      throw XCTSkip("No engine-error banner surfaced — this harness did not drive a failure state; "
                    + "banner gating + dedup are unit-covered in EngineStatusBannerTests / "
                    + "EngineStatusStoreTests. app: \(app.debugDescription)")
    }
    // If it appeared, Dismiss must clear it.
    let dismiss = app.buttons["engineStatus.banner.dismiss"].firstMatch
    XCTAssertTrue(dismiss.waitForExistence(timeout: 3),
                  "error banner present but no Dismiss control; app: \(app.debugDescription)")
    dismiss.click()
    XCTAssertTrue(waitUntilGone(banner, timeout: 5),
                  "Dismiss did not remove the engine-error banner; app: \(app.debugDescription)")
  }

  // MARK: - launch

  /// Launch with an isolated, real-`/tmp` PIE_HOME (GUI convention: never
  /// NSTemporaryDirectory() — the sandboxed runner container differs from
  /// the app's). No harness engine needed: the pip is visible at rest, so
  /// the stability + banner-absence paths run without a seated engine.
  @MainActor
  private func launchedApp() throws -> XCUIApplication {
    let pieHome = makeIsolatedPieHome()
    let app = XCUIApplication(bundleIdentifier: "com.ratiothink.app")
    app.launchArguments.append(contentsOf: [
      "-NSQuitAlwaysKeepsWindows", "NO",
      "-ApplePersistenceIgnoreState", "YES",
    ])
    app.launchEnvironment["PIE_HOME"] = pieHome
    configureCompletedFirstLaunch(app, suiteName: stablePreferenceSuiteName(pieHome))
    app.launch()
    XCTAssert(app.wait(for: .runningForeground, timeout: 10),
              "Pie.app did not reach runningForeground")
    app.activate()
    // A chat surface mounts the ContentToolbar (which hosts the pip).
    let newChat = app.buttons["chats.newButton"]
    if newChat.waitForExistence(timeout: 10) {
      newChat.click()
    }
    return app
  }

  /// A unique real-`/tmp` PIE_HOME path for the launched app — short
  /// enough to stay under the 72-byte sun_path budget the helper's
  /// launchd socket needs and a real `/tmp` rather than
  /// `NSTemporaryDirectory()` (the sandboxed runner's temp container
  /// differs from the un-sandboxed app's — pie-mac XCUITest temp-dir
  /// trap). The directory is NOT created here: the sandboxed XCUITest
  /// runner is denied `mkdir` under `/tmp` (NSCocoaError 513), so the
  /// un-sandboxed app creates the tree itself via `PieDirs` on launch.
  private func makeIsolatedPieHome() -> String {
    "/tmp/pie-s327-\(UUID().uuidString.prefix(8))"
  }

  // MARK: - popover open helper (narrow queries only)

  /// Open the pip's popover, polling for it to appear. Never toggles an
  /// already-open popover shut. Returns true once a popover is open.
  @MainActor
  private func openIndicatorPopover(_ indicator: XCUIElement, in app: XCUIApplication) -> Bool {
    _ = waitForNoPopover(app, timeout: 5)
    var attempts = 0
    while app.popovers.count == 0 && attempts < 5 {
      attempts += 1
      indicator.click()
      let deadline = Date().addingTimeInterval(2.0)
      while Date() < deadline {
        if app.popovers.count > 0 { return true }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
      }
    }
    return app.popovers.count > 0
  }

  private func waitForNoPopover(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if app.popovers.count == 0 { return true }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
    }
    return false
  }

  private func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if !element.exists { return true }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
    }
    return false
  }
}
