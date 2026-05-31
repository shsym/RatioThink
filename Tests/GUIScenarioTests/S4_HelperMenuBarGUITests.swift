import AppKit
import XCTest

/// S4 — RatioThinkHelper menu bar shell.
///
/// GUI-only. Asserts against FINAL design strings (`Show RatioThink`, `Engine:
/// stopped`, `Settings…`, `Open Logs…`, `Quit RatioThink`) so the test stays
/// honest about whether real impl has landed. Skips if no seated session.
final class S4_HelperMenuBarGUITests: XCTestCase {
  override func setUp() async throws {
    try guardSeatedGUI()
  }

  /// `@MainActor` is required because `defer { app.terminate() }` runs in
  /// the test method's actor context; `XCUIApplication.terminate()` traps
  /// (`NSInternalInconsistencyException`) if called off the main thread.
  /// Sibling S5 tests apply the same annotation for the same reason.
  @MainActor
  func test_helper_status_bar_surfaces_design_items() async throws {
    // Drive a DETERMINISTIC `Engine: stopped` boot WITHOUT a staged model.
    // `HelperStatusItemModel` renders the status shell from the `.stopped`
    // status alone and never consults the model, so this menu-shell smoke
    // needs no weight and must run on a model-less checkout (gated only by
    // guardSeatedGUI). The helper auto-resumes the ACTIVE profile at boot
    // (HelperMain.autoResumeEngineOnBoot), so a freshly-seeded PIE_HOME —
    // whose seed also writes the active-profile marker — would boot to
    // `starting…`/`Pause Engine`. Pre-write a profile so `seedDefaultsIfEmpty`
    // skips (a .toml already exists) and NO `<PIE_HOME>/active-profile` marker
    // is written → `activeProfileID` is nil → autoResume no-ops
    // (`.noActiveProfile`) → the engine stays `.stopped`. Only the file's
    // existence matters (the helper never resolves it — no active profile), so
    // it is a minimal placeholder, NOT a copy of the seed format. PIE_HOME lives
    // under the runner-writable NSTemporaryDirectory container (the sandboxed
    // runner cannot create dirs under /tmp).
    let fm = FileManager.default
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("pie-s4design-\(UUID().uuidString)", isDirectory: true)
    let profilesDir = tempDir.appendingPathComponent("profiles", isDirectory: true)
    try fm.createDirectory(at: profilesDir, withIntermediateDirectories: true)
    addTeardownBlock { try? fm.removeItem(at: tempDir) }
    let placeholderProfile = """
    id = "chat"
    name = "Chat"
    model = "placeholder"
    inferlet = "chat-apc"
    """
    try placeholderProfile.write(to: profilesDir.appendingPathComponent("chat.toml"),
                                 atomically: true, encoding: .utf8)

    let app = XCUIApplication(bundleIdentifier: "com.ratiothink.app.helper")
    app.launchEnvironment["PIE_HOME"] = tempDir.path
    // Debug dev builds are ad-hoc-signed (no Team ID).
    // `HelperXPCListener.verifyStartupInvariants` preconditionFails
    // on `.teamIDAbsent` unless a bypass env is captured. Notarized
    // production helpers never enter this branch.
    app.launchEnvironment["PIE_ALLOW_UNSIGNED_CALLERS"] = "1"
    app.launch()
    defer { app.terminate() }

    // RatioThinkHelper is `LSUIElement=YES` (accessory activation policy): a
    // status-bar agent with no window stays `.runningBackground` and
    // never reaches `.runningForeground`. Accept either so the assert
    // matches the real macOS contract for menu-bar-only helpers.
    let reached = app.wait(for: .runningForeground, timeout: 1)
                  || app.wait(for: .runningBackground, timeout: 3)
    XCTAssert(reached, "RatioThinkHelper did not reach a running state")

    let statusItems = app.menuBars.statusItems
    XCTAssertGreaterThan(statusItems.count, 0, "no status items registered")

    let first = statusItems.element(boundBy: 0)
    first.click()

    let menu = app.menus.firstMatch
    XCTAssert(menu.waitForExistence(timeout: 2), "status menu did not appear")

    let titles = menu.menuItems.allElementsBoundByIndex.map(\.title)
    // "Resume Engine" is Phase 2.3's Pause/Resume affordance in its
    // stopped-state form — the supervisor publishes `.stopped` at
    // helper boot, which `HelperStatusItemModel` maps to the
    // disabled "Resume Engine" item. Phase 2.4 wires
    // ProfileStore so the item actually enables.
    for expected in ["Show RatioThink", "Engine: stopped", "Resume Engine",
                     "Settings…", "Open Logs…", "Quit RatioThink"] {
      XCTAssertTrue(titles.contains(expected),
                    "menu missing '\(expected)'; got: \(titles)")
    }
    // Idle-shell determinism: no active profile ⇒ autoResume no-ops, so the
    // running/starting affordances must be ABSENT — proving the `.stopped`
    // shell renders without any staged model.
    for absent in ["Pause Engine", "Engine: starting…"] {
      XCTAssertFalse(titles.contains(absent),
                     "idle shell must not show a running/starting affordance; got: \(titles)")
    }

    app.typeKey(.escape, modifierFlags: [])
  }

  ///  end-to-end (enable-only): a fresh `PIE_HOME` triggers
  /// `ProfileStore.seedDefaultsIfEmpty`, which now also writes the
  /// active-profile marker. The menu-bar `Resume Engine` item must
  /// become enabled — proving the seeded marker landed and the
  /// resolver / status binding wired through.
  ///
  ///  (landed): `togglePauseResume` now drives
  /// `PieEngineHost` → `PieControlLauncher.launch(spec:)` instead of
  /// the stale `PieSupervisor.start` argv. The end-to-end variant
  /// that actually clicks Resume and asserts the title transitions
  /// to `Pause Engine` lives below as
  /// `test_first_run_clicking_resume_boots_engine_and_flips_to_pause`.
  /// Its real pre-requisites are:
  ///   · TCC permissions granted (covered by the existing skip),
  ///   · the bundled pie binary at
  ///     `<RatioThink.app>/Contents/Resources/pie-engine/pie` (Scripts/
  ///     build-pie-engine.sh stages this during xcodebuild; the
  ///     portable Metal driver is compiled in — verify with
  ///     `pie doctor` → "portable compiled in"),
  ///   · the model fixture symlinked at
  ///     `<PIE_HOME>/models/Qwen3-0.6B-Q8_0.gguf` (resolved via
  ///     `PIE_TEST_MODEL` env or repo-root `test-models/`; the
  ///     `.gguf` is gitignored — keep it staged outside the repo).
  /// The enable-only contract guarded here is the narrower 
  /// regression: the resolver wires through without spawning pie.
  ///
  /// Wiring needed inside the isolated `PIE_HOME`:
  ///   - `profiles/` — empty, so seed runs.
  ///   - `models/Qwen3-0.6B-Q8_0.gguf` — symlinked at the repo-root
  ///     fixture (`test-models/`) or `PIE_TEST_MODEL` env override.
  ///     `LaunchSpecResolver` joins `<PIE_HOME>/models` with
  ///     `profile.model` to build the model path.
  ///   - `inferlets` — symlinked at `<RatioThink.app>/Contents/Resources/Inferlets`
  ///     resolved via the test bundle's sibling RatioThink.app (test target
  ///     depends on `RatioThink`, so xcodebuild stages it next to the runner),
  ///     so the engine's inferlet-dir walk finds the bundled
  ///     `chat-apc` artifacts.
  @MainActor
  func test_first_run_fresh_profiles_dir_enables_resume() async throws {
    //  review v1 F10: RatioThinkHelper's first-launch TCC prompt
    // (Accessibility / Automation) blocks menu-bar UI interaction;
    // without an opt-in env signal we cannot tell a real failure from
    // a permission-sheet timeout. Surface a clear skip reason instead
    // of an opaque expectation timeout.
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["PIE_TEST_TCC_GRANTED"] == "1",
      "RatioThinkHelper TCC permissions (Accessibility / Automation) required. " +
      "Grant once via System Settings, then set PIE_TEST_TCC_GRANTED=1 " +
      "before running the GUI suite."
    )

    let fm = FileManager.default

    // 1. Isolated PIE_HOME with empty profiles/.
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("pie-s4-resume-\(UUID().uuidString)", isDirectory: true)
    let profilesDir = tempDir.appendingPathComponent("profiles", isDirectory: true)
    let modelsDir   = tempDir.appendingPathComponent("models",   isDirectory: true)
    try fm.createDirectory(at: profilesDir, withIntermediateDirectories: true)
    try fm.createDirectory(at: modelsDir,   withIntermediateDirectories: true)
    // Review v1 F7: do NOT swallow teardown errors. If removal fails
    // (helper subprocess still alive, perms drift), XCTest propagates
    // the throw so subsequent tests don't inherit a polluted tempdir.
    addTeardownBlock { try fm.removeItem(at: tempDir) }

    // 2. Model fixture. Resolution order (review v1 F1):
    //    a. `PIE_TEST_MODEL` env override (cached layouts / CI bind
    //       mount).
    //    b. Repo-root `test-models/Qwen3-0.6B-Q8_0.gguf`, located
    //       by walking up from `#filePath` until `Package.swift` is
    //       found.
    //    XCTSkipUnless is reserved for the legitimate developer-only
    //    case where neither resolves on disk — large model weights are
    //    expected to be missing on a fresh checkout.
    let modelSource: URL = try {
      if let override = ProcessInfo.processInfo.environment["PIE_TEST_MODEL"],
         !override.isEmpty {
        return URL(fileURLWithPath: override)
      }
      return try Self.repoRoot()
        .appendingPathComponent("test-models/Qwen3-0.6B-Q8_0.gguf",
                                isDirectory: false)
    }()
    try XCTSkipUnless(
      fm.fileExists(atPath: modelSource.path),
      "model fixture missing at \(modelSource.path) — stage a Qwen3-0.6B-Q8_0.gguf at test-models/ or set PIE_TEST_MODEL"
    )
    try fm.createSymbolicLink(
      at: try Self.seededModelDestination(in: modelsDir),
      withDestinationURL: modelSource
    )

    // 3. Locate RatioThink.app via the test bundle's sibling, not LaunchServices.
    //    `project.yml` declares `RatioThinkGUITests.dependencies = [target: RatioThink,
    //    target: RatioThinkHelper]` so xcodebuild stages RatioThink.app at
    //    `<BUILT_PRODUCTS_DIR>/RatioThink.app` next to the runner. Walking up
    //    from `Bundle(for:)` finds it deterministically — LaunchServices
    //    lookup can fail for many reasons (stale LSDB entry, sandboxed
    //    runner) that produce a misleading skip (review v1 F1).
    let pieAppURL = try XCTUnwrap(
      Self.locateSiblingApp(named: "RatioThink.app", from: type(of: self)),
      "RatioThink.app not found next to test bundle — verify project.yml `RatioThinkGUITests.dependencies` includes `target: RatioThink`"
    )
    let inferletSource = pieAppURL
      .appendingPathComponent("Contents/Resources/Inferlets", isDirectory: true)
    XCTAssertTrue(
      fm.fileExists(atPath: inferletSource.path),
      "bundled inferlets dir missing at \(inferletSource.path) — re-run `make build-inferlets` and re-build RatioThink.app"
    )
    try fm.createSymbolicLink(
      at: tempDir.appendingPathComponent("inferlets"),
      withDestinationURL: inferletSource
    )

    // 4. Launch helper bound to the isolated PIE_HOME. No PIE_TEST_MODE
    //    so the real ProfileStore + LaunchSpecResolver wiring runs.
    let app = XCUIApplication(bundleIdentifier: "com.ratiothink.app.helper")
    app.launchEnvironment["PIE_HOME"] = tempDir.path
    app.launchEnvironment["PIE_ALLOW_UNSIGNED_CALLERS"] = "1"
    app.launch()
    defer { app.terminate() }

    let reached = app.wait(for: .runningForeground, timeout: 1)
                  || app.wait(for: .runningBackground, timeout: 3)
    XCTAssert(reached, "RatioThinkHelper did not reach a running state")

    let statusItems = app.menuBars.statusItems
    XCTAssertGreaterThan(statusItems.count, 0, "no status items registered")

    // 5. Open the menu and wait for "Resume Engine" to become enabled.
    //    seedDefaultsIfEmpty runs synchronously inside ProfileStore.start(),
    //    but the `.stopped → enabled` publish hop, resolver wiring,
    //    and HelperStatusItemBinding's main-thread apply all take a
    //    tick to settle. 8s leaves margin.
    statusItems.element(boundBy: 0).click()
    let menu = app.menus.firstMatch
    XCTAssert(menu.waitForExistence(timeout: 2), "status menu did not appear")

    let resumeItem = menu.menuItems["Resume Engine"]
    XCTAssert(resumeItem.waitForExistence(timeout: 2),
              "Resume Engine menu item missing on fresh PIE_HOME=\(tempDir.path)")

    let enabledPredicate = NSPredicate(format: "isEnabled == true")
    let enabledExpect = expectation(for: enabledPredicate,
                                    evaluatedWith: resumeItem,
                                    handler: nil)
    let enabledOutcome = XCTWaiter().wait(for: [enabledExpect], timeout: 8)
    XCTAssertEqual(enabledOutcome, .completed,
                   "Resume Engine never became enabled — seedDefaultsIfEmpty or LaunchSpecResolver wiring failed (PIE_HOME=\(tempDir.path))")

    // 6. Dismiss without clicking Resume. The end-to-end click+boot
    //    assertion lives in the sibling test below; this test's
    //     contract is the enable transition itself, already
    //    asserted above. Keeping this case escape-only avoids
    //    paying the ~10–30 s pie boot cost on every run.
    app.typeKey(.escape, modifierFlags: [])
  }

  ///  GUI boundary: an oversized default model must be
  /// rejected by the helper's in-process Resume path and surfaced in
  /// the menu-bar UI instead of looking like a stopped/no-op state.
  /// Uses a sparse file fixture — no real huge download or engine load.
  @MainActor
  func test_resume_with_oversized_default_model_keeps_menu_out_of_starting() async throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["PIE_TEST_TCC_GRANTED"] == "1",
      "RatioThinkHelper TCC permissions (Accessibility / Automation) required. " +
      "Grant once via System Settings, then set PIE_TEST_TCC_GRANTED=1 " +
      "before running the GUI suite."
    )

    let fm = FileManager.default
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("pie-s4-memory-risk-\(UUID().uuidString)", isDirectory: true)
    let profilesDir = tempDir.appendingPathComponent("profiles", isDirectory: true)
    let modelsDir   = tempDir.appendingPathComponent("models",   isDirectory: true)
    try fm.createDirectory(at: profilesDir, withIntermediateDirectories: true)
    try fm.createDirectory(at: modelsDir,   withIntermediateDirectories: true)
    addTeardownBlock { try fm.removeItem(at: tempDir) }

    let oversizedDefault = try Self.seededModelDestination(in: modelsDir)
    try Self.writeSparseFile(
      at: oversizedDefault,
      sizeBytes: 8 * 1024 * 1024 * 1024 + 1
    )

    let pieAppURL = try XCTUnwrap(
      Self.locateSiblingApp(named: "RatioThink.app", from: type(of: self)),
      "RatioThink.app not found next to test bundle — verify project.yml `RatioThinkGUITests.dependencies` includes `target: RatioThink`"
    )
    let stagedPieBinary = pieAppURL
      .appendingPathComponent("Contents/Resources/pie-engine/pie", isDirectory: false)
    try XCTSkipUnless(
      fm.isExecutableFile(atPath: stagedPieBinary.path),
      "bundled pie engine missing at \(stagedPieBinary.path) — rebuild RatioThink.app (Scripts/build-pie-engine.sh)"
    )
    let inferletSource = pieAppURL
      .appendingPathComponent("Contents/Resources/Inferlets", isDirectory: true)
    XCTAssertTrue(
      fm.fileExists(atPath: inferletSource.path),
      "bundled inferlets dir missing at \(inferletSource.path) — re-run `make build-inferlets` and re-build RatioThink.app"
    )
    try fm.createSymbolicLink(
      at: tempDir.appendingPathComponent("inferlets"),
      withDestinationURL: inferletSource
    )

    let app = XCUIApplication(bundleIdentifier: "com.ratiothink.app.helper")
    app.launchEnvironment["PIE_HOME"] = tempDir.path
    app.launchEnvironment["PIE_ALLOW_UNSIGNED_CALLERS"] = "1"
    app.launch()
    defer { app.terminate() }

    let reached = app.wait(for: .runningForeground, timeout: 1)
                  || app.wait(for: .runningBackground, timeout: 3)
    XCTAssert(reached, "RatioThinkHelper did not reach a running state")

    let statusItems = app.menuBars.statusItems
    XCTAssertGreaterThan(statusItems.count, 0, "no status items registered")
    statusItems.element(boundBy: 0).click()
    let firstMenu = app.menus.firstMatch
    XCTAssert(firstMenu.waitForExistence(timeout: 2), "status menu did not appear")

    let resumeItem = firstMenu.menuItems["Resume Engine"]
    XCTAssert(resumeItem.waitForExistence(timeout: 2),
              "Resume Engine menu item missing on oversized-model PIE_HOME=\(tempDir.path)")
    let enabledPredicate = NSPredicate(format: "isEnabled == true")
    let enabledExpect = expectation(for: enabledPredicate,
                                    evaluatedWith: resumeItem,
                                    handler: nil)
    let enabledOutcome = XCTWaiter().wait(for: [enabledExpect], timeout: 8)
    XCTAssertEqual(enabledOutcome, .completed,
                   "Resume Engine never became enabled before memory-risk rejection test (PIE_HOME=\(tempDir.path))")
    resumeItem.click()

    try await Task.sleep(nanoseconds: 500_000_000)
    statusItems.element(boundBy: 0).click()
    let menu = app.menus.firstMatch
    XCTAssert(menu.waitForExistence(timeout: 2), "status menu did not re-open after rejected resume")
    let titles = menu.menuItems.allElementsBoundByIndex.map(\.title)
    let failureTitle = titles.first(where: { $0.contains("Engine: failed (memoryRisk)") })
    XCTAssertNotNil(failureTitle,
                    "oversized model rejection should surface memoryRisk status/copy in the menu; got \(titles)")
    if let failureTitle {
      XCTAssertTrue(failureTitle.contains("choose a smaller model"),
                    "memoryRisk menu copy should include recovery guidance; got \(failureTitle)")
    }
    XCTAssertFalse(titles.contains(where: { $0 == "Engine: starting…" || $0 == "Pause Engine" }),
                   "oversized model rejection left menu in a loading/running affordance; got \(titles)")
    app.typeKey(.escape, modifierFlags: [])
  }

  ///  end-to-end: clicking "Resume Engine" actually
  /// drives `PieEngineHost.start` → `PieControlLauncher.launch`,
  /// reaches `.running`, and the menu item flips to "Pause Engine".
  ///
  /// Pre-reqs (all skip-with-clear-reason if missing):
  ///   · `PIE_TEST_TCC_GRANTED=1` (Accessibility / Automation),
  ///   · pie binary bundled at
  ///     `<RatioThink.app>/Contents/Resources/pie-engine/pie` (built by
  ///     the `Build pie engine binary` post-compile phase — see
  ///     project.yml; portable Metal driver is compiled in),
  ///   · `Qwen3-0.6B-Q8_0.gguf` at `PIE_TEST_MODEL` or repo-root
  ///     `test-models/` (gitignored — staged outside the repo).
  ///
  /// Cold pie boot does cargo-free spawn → TCP handshake →
  /// WebSocket `install_program` (chat-apc.wasm load) →
  /// `launch_daemon`. Empirically 5–20 s on Apple Silicon with
  /// the 0.6B Q8_0 weights; this test allows 60 s.
  @MainActor
  func test_first_run_clicking_resume_boots_engine_and_flips_to_pause() async throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["PIE_TEST_TCC_GRANTED"] == "1",
      "RatioThinkHelper TCC permissions (Accessibility / Automation) required. " +
      "Grant once via System Settings, then set PIE_TEST_TCC_GRANTED=1 " +
      "before running the GUI suite."
    )

    let fm = FileManager.default

    // 1. Isolated PIE_HOME with empty profiles/.
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("pie-s4-resume-boot-\(UUID().uuidString)", isDirectory: true)
    let profilesDir = tempDir.appendingPathComponent("profiles", isDirectory: true)
    let modelsDir   = tempDir.appendingPathComponent("models",   isDirectory: true)
    try fm.createDirectory(at: profilesDir, withIntermediateDirectories: true)
    try fm.createDirectory(at: modelsDir,   withIntermediateDirectories: true)
    addTeardownBlock { try fm.removeItem(at: tempDir) }

    // 2. Model fixture (same resolution order as the enable test).
    let modelSource: URL = try {
      if let override = ProcessInfo.processInfo.environment["PIE_TEST_MODEL"],
         !override.isEmpty {
        return URL(fileURLWithPath: override)
      }
      return try Self.repoRoot()
        .appendingPathComponent("test-models/Qwen3-0.6B-Q8_0.gguf",
                                isDirectory: false)
    }()
    try XCTSkipUnless(
      fm.fileExists(atPath: modelSource.path),
      "model fixture missing at \(modelSource.path) — stage a Qwen3-0.6B-Q8_0.gguf or set PIE_TEST_MODEL"
    )
    try fm.createSymbolicLink(
      at: try Self.seededModelDestination(in: modelsDir),
      withDestinationURL: modelSource
    )

    // 3. Locate RatioThink.app via the test bundle's sibling, then verify
    //    the staged pie binary exists. If it's missing, the
    //    post-compile build phase didn't run — skip with a clear
    //    pointer so the operator knows to rebuild.
    let pieAppURL = try XCTUnwrap(
      Self.locateSiblingApp(named: "RatioThink.app", from: type(of: self)),
      "RatioThink.app not found next to test bundle — verify project.yml `RatioThinkGUITests.dependencies` includes `target: RatioThink`"
    )
    let stagedPieBinary = pieAppURL
      .appendingPathComponent("Contents/Resources/pie-engine/pie", isDirectory: false)
    try XCTSkipUnless(
      fm.isExecutableFile(atPath: stagedPieBinary.path),
      "bundled pie engine missing at \(stagedPieBinary.path) — rebuild RatioThink.app (Scripts/build-pie-engine.sh)"
    )
    let inferletSource = pieAppURL
      .appendingPathComponent("Contents/Resources/Inferlets", isDirectory: true)
    XCTAssertTrue(
      fm.fileExists(atPath: inferletSource.path),
      "bundled inferlets dir missing at \(inferletSource.path) — re-run `make build-inferlets` and re-build RatioThink.app"
    )
    try fm.createSymbolicLink(
      at: tempDir.appendingPathComponent("inferlets"),
      withDestinationURL: inferletSource
    )

    // 4. Launch helper bound to the isolated PIE_HOME.
    let app = XCUIApplication(bundleIdentifier: "com.ratiothink.app.helper")
    app.launchEnvironment["PIE_HOME"] = tempDir.path
    app.launchEnvironment["PIE_ALLOW_UNSIGNED_CALLERS"] = "1"
    app.launch()
    defer { app.terminate() }

    let reached = app.wait(for: .runningForeground, timeout: 1)
                  || app.wait(for: .runningBackground, timeout: 3)
    XCTAssert(reached, "RatioThinkHelper did not reach a running state")

    let statusItems = app.menuBars.statusItems
    XCTAssertGreaterThan(statusItems.count, 0, "no status items registered")

    // 5. Open menu, wait for "Resume Engine" to be enabled, click it.
    statusItems.element(boundBy: 0).click()
    let firstMenu = app.menus.firstMatch
    XCTAssert(firstMenu.waitForExistence(timeout: 2), "status menu did not appear")
    let resumeItem = firstMenu.menuItems["Resume Engine"]
    XCTAssert(resumeItem.waitForExistence(timeout: 2),
              "Resume Engine menu item missing on fresh PIE_HOME=\(tempDir.path)")
    let enabledPredicate = NSPredicate(format: "isEnabled == true")
    let enabledExpect = expectation(for: enabledPredicate,
                                    evaluatedWith: resumeItem,
                                    handler: nil)
    let enabledOutcome = XCTWaiter().wait(for: [enabledExpect], timeout: 8)
    XCTAssertEqual(enabledOutcome, .completed,
                   "Resume Engine never became enabled (PIE_HOME=\(tempDir.path))")
    resumeItem.click()

    // 6. NSMenu is a snapshot — clicking dismisses it. To observe
    //    the title flip we re-open the menu periodically until the
    //    "Pause Engine" item appears (engine reached `.running`)
    //    or we fail with a "stuck in starting/failed" diagnostic.
    let pauseDeadline = Date().addingTimeInterval(60)
    var sawPause = false
    var lastTitles: [String] = []
    while Date() < pauseDeadline {
      statusItems.element(boundBy: 0).click()
      let menu = app.menus.firstMatch
      if menu.waitForExistence(timeout: 2) {
        lastTitles = menu.menuItems.allElementsBoundByIndex.map(\.title)
        if menu.menuItems["Pause Engine"].exists {
          sawPause = true
          break
        }
        // Surface `Engine: failed` early — no point waiting 60 s if
        // pie already crashed on boot.
        if lastTitles.contains(where: { $0.hasPrefix("Engine: failed") }) {
          app.typeKey(.escape, modifierFlags: [])
          XCTFail("engine reached .failed during resume — titles: \(lastTitles)")
          return
        }
        app.typeKey(.escape, modifierFlags: [])
      }
      try await Task.sleep(nanoseconds: 1_000_000_000)
    }
    XCTAssertTrue(sawPause,
                  "engine never reached .running within 60s — last menu titles: \(lastTitles)")

    // 7. Tear the engine back down so the next test starts clean.
    //    The `defer app.terminate()` above also covers this, but
    //    clicking Pause first lets PieEngineHost.stop() invoke
    //    LaunchedSession.shutdown() cleanly before SIGTERM.
    if sawPause {
      statusItems.element(boundBy: 0).click()
      let teardownMenu = app.menus.firstMatch
      if teardownMenu.waitForExistence(timeout: 2),
         teardownMenu.menuItems["Pause Engine"].exists {
        teardownMenu.menuItems["Pause Engine"].click()
      }
    }
  }

  // MARK: - helpers

  /// Walks up from `#filePath` to the directory containing
  /// `Package.swift`. Anchors all repo-relative fixture lookups so
  /// tests don't carry hard-coded author-workstation paths (review
  /// v1 F1).
  private static func repoRoot(file: StaticString = #filePath) throws -> URL {
    let fm = FileManager.default
    var dir = URL(fileURLWithPath: "\(file)", isDirectory: false)
      .deletingLastPathComponent()
    while !fm.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
      let parent = dir.deletingLastPathComponent()
      if parent == dir {
        throw NSError(domain: "S4_HelperMenuBarGUITests", code: 1, userInfo: [
          NSLocalizedDescriptionKey: "could not locate repo root (no Package.swift above \(file))"
        ])
      }
      dir = parent
    }
    return dir
  }

  /// Locates a sibling `.app` next to the test bundle by walking up
  /// `Bundle(for:)` until a directory containing `<name>` is found
  /// at any level. Returns nil if no candidate exists (review v1 F1).
  private static func locateSiblingApp(named name: String, from cls: AnyClass) -> URL? {
    let fm = FileManager.default
    var dir = Bundle(for: cls).bundleURL.deletingLastPathComponent()
    for _ in 0..<8 {
      let candidate = dir.appendingPathComponent(name)
      if fm.fileExists(atPath: candidate.path) { return candidate }
      let parent = dir.deletingLastPathComponent()
      if parent == dir { return nil }
      dir = parent
    }
    return nil
  }

  private static func writeSparseFile(at url: URL, sizeBytes: Int64) throws {
    _ = FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: UInt64(sizeBytes))
    try handle.close()
  }

  ///  review v2 F1: the seeded default is the `<repo>/<file>` slug
  /// `Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf`, which the resolver
  /// joins to a path nested under `<models>/Qwen/Qwen3-0.6B-GGUF/`.
  /// Stage fixtures there (and create the intermediate dirs) so the
  /// app-staged lookup resolves. Built by chaining components — a bare
  /// `appendingPathComponent(slug)` would percent-escape the "/".
  private static func seededModelDestination(in modelsDir: URL) throws -> URL {
    let dest = modelsDir
      .appendingPathComponent("Qwen", isDirectory: true)
      .appendingPathComponent("Qwen3-0.6B-GGUF", isDirectory: true)
      .appendingPathComponent("Qwen3-0.6B-Q8_0.gguf", isDirectory: false)
    try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    return dest
  }
}
