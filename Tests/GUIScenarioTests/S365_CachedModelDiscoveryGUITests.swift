import XCTest

/// Hugging Face cache model-discovery leg, driven through the GUI.
///
/// A model already staged in the shared HF cache (`$HF_HOME/hub`) must
/// surface in the real app without any download or engine launch:
///   RatioThink.app → Settings (⌘,) → Models tab → an "HF cache" row.
/// That row is produced by `CachedModelScan` → `HFCacheCatalog.scan(hfHome:)`
/// where `hfHome == $HF_HOME` (`LaunchSpecResolver.defaultHFHome`), so a
/// fixture cache pointed at by `HF_HOME` exercises the exact production
/// discovery path. The scan is pure filesystem — no engine is started.
///
/// This is the end-to-end guard for the cache-enumeration layer: the
/// clean re-import dropped that layer (and its e2e) while the
/// single-repo launch resolver survived, so cached models resolved at
/// launch but never appeared in Settings or the picker. A passing run
/// proves enumeration → Settings row, the leg unit tests cannot cover.
///
/// Two legs:
///  - Models tab: a cached safetensors repo shows an "HF-cache" row
///    (`InstalledRow-HFCache-<slug>`), read-only (no Delete).
///  - Profiles picker: a cached split-GGUF model — which the engine
///    cannot load — is offered but carries its unsupported reason, so the
///    user sees the cached model yet learns why it can't be the default.
///
/// Fixture injection (sandboxed-runner constraint): the XCUITest runner
/// is sandboxed and CANNOT write the fixture cache to a shared `/tmp`
/// path (EPERM). So the fixture + a fresh `PIE_HOME` are staged by
/// `Scripts/run-cache-discovery-gui-e2e.sh` (running as the normal,
/// unsandboxed user) BEFORE xcodebuild; these tests read their paths from
/// a config env file and skip when it is absent — the
/// `S204_ModelAcquisitionGUITests` pattern. The launched RatioThink.app
/// is NOT sandboxed, so it reads the staged `HF_HOME` and writes
/// `PIE_HOME` on `/tmp` without issue.
///
/// Uses narrow type queries only — `descendants(matching: .any)` can
/// SIGBUS on a degraded session (GUI-test convention).
final class S365_CachedModelDiscoveryGUITests: XCTestCase {
  override func setUp() async throws { try guardSeatedGUI() }

  /// Slug of the staged safetensors repo (matches the wrapper fixture).
  private static let safetensorsSlug = "acme/discovery-model"
  /// Leaf of the staged split-GGUF first shard (matches the wrapper).
  private static let splitGGUFLeaf = "split-Q4_K_M-00001-of-00002.gguf"

  // MARK: - Models tab discovery

  @MainActor
  func test_staged_cache_model_surfaces_as_hf_cache_row_in_models_tab() async throws {
    let app = try launchApp()
    defer { app.terminate() }
    let settings = try openSettingsTab("Models", in: app)

    // The HF-cache row's "HF cache" tag carries this identifier
    // (ModelsSettingsTab). Its presence proves the cached model was
    // enumerated AND tagged read-only, not mistaken for an app-managed
    // file. The badge is a SwiftUI Text whose identifier may surface as
    // staticTexts OR otherElements depending on Table cell collapse —
    // query both (the S204 badge pattern).
    let rowID = "InstalledRow-HFCache-\(Self.safetensorsSlug)"
    XCTAssertTrue(elementExists(rowID, in: settings, timeout: 15),
                  "cached safetensors model did not surface as an HF-cache row "
                  + "in Settings → Models; window: \(settings.debugDescription)")
  }

  // MARK: - Profiles picker unsupported reason

  @MainActor
  func test_split_gguf_cache_model_shows_unsupported_reason_in_picker() async throws {
    let app = try launchApp()
    defer { app.terminate() }
    let settings = try openSettingsTab("Profiles", in: app)

    let picker = app.menuButtons["ProfileEditorModelPicker"]
    XCTAssertTrue(picker.waitForExistence(timeout: 15),
                  "model picker missing on Profiles tab (no seeded profile?); "
                  + "window: \(settings.debugDescription)")
    picker.click()

    // The split-GGUF option is offered (the user sees the cached model)
    // but carries the unsupported reason (ProfileEditor.modelOptionText
    // appends "— <reason>") and is disabled. Match on `title`, NOT
    // `label`: the option renders as `Label(text, systemImage:)` for the
    // unsupported case, so XCUITest derives `label`/`identifier` from the
    // SF Symbol while the composed text lands in `title`. Asserting the
    // "Split GGUF" reason text proves the unsupported path renders — a
    // launchable model never shows it.
    let option = app.menuItems
      .matching(NSPredicate(format: "title CONTAINS %@ AND title CONTAINS %@",
                            Self.splitGGUFLeaf, "Split GGUF")).firstMatch
    XCTAssertTrue(option.waitForExistence(timeout: 10),
                  "split-GGUF cache model is missing its unsupported reason in the "
                  + "picker; menu tree: \(app.debugDescription)")
    XCTAssertFalse(option.isEnabled,
                   "an unsupported (split-GGUF) option must be disabled so the user "
                   + "cannot pick a model the engine can never load")
    app.typeKey(.escape, modifierFlags: [])
  }

  // MARK: - Launch / navigation

  @MainActor
  private func launchApp() throws -> XCUIApplication {
    let config = try Self.loadConfig()
    let hfHome = try XCTUnwrap(config["PIE_TEST_DISCOVERY_HF_HOME"],
                               "\(Self.configPath) must define PIE_TEST_DISCOVERY_HF_HOME")
    let pieHome = try XCTUnwrap(config["PIE_TEST_DISCOVERY_PIE_HOME"],
                                "\(Self.configPath) must define PIE_TEST_DISCOVERY_PIE_HOME")

    let app = XCUIApplication(bundleIdentifier: "com.ratiothink.app")
    app.launchArguments.append(contentsOf: [
      "-NSQuitAlwaysKeepsWindows", "NO",
      "-ApplePersistenceIgnoreState", "YES",
    ])
    app.launchEnvironment["PIE_HOME"] = pieHome
    // Point the app's HF-cache scan at the staged fixture.
    app.launchEnvironment["HF_HOME"] = hfHome
    configureCompletedFirstLaunch(app, suiteName: stablePreferenceSuiteName(pieHome))
    app.launch()
    XCTAssert(app.wait(for: .runningForeground, timeout: 10),
              "RatioThink.app did not reach runningForeground")
    app.activate()
    return app
  }

  @MainActor
  private func openSettingsTab(_ tab: String, in app: XCUIApplication) throws -> XCUIElement {
    app.typeKey(",", modifierFlags: .command)
    let settings = app.windows
      .matching(identifier: "com_apple_SwiftUI_Settings_window").firstMatch
    XCTAssertTrue(settings.waitForExistence(timeout: 10),
                  "Settings window did not appear after ⌘,; app: \(app.debugDescription)")
    let tabButton = settings.toolbars.buttons[tab]
    XCTAssertTrue(tabButton.waitForExistence(timeout: 10),
                  "\(tab) settings tab missing; window: \(settings.debugDescription)")
    tabButton.click()
    return settings
  }

  /// An identifier-keyed element may surface as `staticTexts` OR
  /// `otherElements` depending on how SwiftUI collapses the host view
  /// (Table cell / Label) — query both, never a single type. Narrow type
  /// queries only (no `descendants(.any)`).
  @MainActor
  private func elementExists(_ identifier: String,
                             in settings: XCUIElement,
                             timeout: TimeInterval) -> Bool {
    if settings.staticTexts[identifier].waitForExistence(timeout: timeout) { return true }
    return settings.otherElements[identifier].exists
  }

  // MARK: - Config

  private static let configPath = "/tmp/pie-cache-discovery-e2e.env"

  /// Read the wrapper-script-staged config, or skip. The runner cannot
  /// stage the fixture itself (sandbox), so these tests are meaningful
  /// only when launched via `Scripts/run-cache-discovery-gui-e2e.sh`.
  /// Skipping here keeps a bare `make test-gui` green without a silent
  /// false pass.
  private static func loadConfig() throws -> [String: String] {
    let url = URL(fileURLWithPath: configPath)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw XCTSkip("cache-discovery GUI E2E config missing at \(configPath); "
                    + "run Scripts/run-cache-discovery-gui-e2e.sh")
    }
    let text = try String(contentsOf: url, encoding: .utf8)
    return text
      .split(separator: "\n")
      .reduce(into: [:]) { result, line in
        let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return }
        let key = String(parts[0])
        let value = String(parts[1])
        if !key.isEmpty { result[key] = value }
      }
  }
}
