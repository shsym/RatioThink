import XCTest
@testable import RatioThink

/// `AppPreferences` is `@MainActor`. Mark the suite likewise so the
/// `UserDefaults` reads/writes hop on the right actor without needing
/// per-test `await MainActor.run` blocks.
///
///  removed the swap skip-set; the only surviving preference is the
/// first-launch completion flag.
@MainActor
final class AppPreferencesTests: XCTestCase {

  /// Each test gets a scratch `UserDefaults` suite so process-wide
  /// state is never touched. The suite name is keyed on the test
  /// method's name + a UUID so parallel runs cannot alias.
  private func makeScratchDefaults() throws -> UserDefaults {
    let suite = "com.ratiothink.app.tests.AppPreferences." + UUID().uuidString
    guard let defaults = UserDefaults(suiteName: suite) else {
      throw XCTSkip("could not create scratch UserDefaults suite")
    }
    defaults.removePersistentDomain(forName: suite)
    return defaults
  }

  func test_first_launch_wizard_is_incomplete_until_user_finishes_it() throws {
    let defaults = try makeScratchDefaults()
    let prefs = AppPreferences(defaults: defaults)

    XCTAssertFalse(prefs.firstLaunchWizardCompleted)
  }

  func test_completing_first_launch_persists_completion() throws {
    let defaults = try makeScratchDefaults()
    let prefs = AppPreferences(defaults: defaults)

    // : the wizard no longer captures a model choice — model
    // setup moved to Settings → Models — so completion is a single flag.
    prefs.completeFirstLaunch()

    XCTAssertTrue(prefs.firstLaunchWizardCompleted)

    let reopened = AppPreferences(defaults: defaults)
    XCTAssertTrue(reopened.firstLaunchWizardCompleted)
  }

  func test_reset_first_launch_wizard_clears_completion() throws {
    let defaults = try makeScratchDefaults()
    let prefs = AppPreferences(defaults: defaults)
    prefs.completeFirstLaunch()

    prefs.resetFirstLaunchWizard()

    XCTAssertFalse(prefs.firstLaunchWizardCompleted)
    let reopened = AppPreferences(defaults: defaults)
    XCTAssertFalse(reopened.firstLaunchWizardCompleted)
  }

  func test_local_api_external_access_defaults_to_disabled() throws {
    let defaults = try makeScratchDefaults()
    let prefs = AppPreferences(defaults: defaults)

    XCTAssertFalse(prefs.localAPIExternalAccessEnabled)
    XCTAssertEqual(prefs.localAPIBindMode, .loopback)
  }

  func test_local_api_external_access_persists() throws {
    let defaults = try makeScratchDefaults()
    let prefs = AppPreferences(defaults: defaults)

    prefs.setLocalAPIExternalAccessEnabled(true)

    XCTAssertTrue(prefs.localAPIExternalAccessEnabled)
    XCTAssertEqual(prefs.localAPIBindMode, .external)

    let reopened = AppPreferences(defaults: defaults)
    XCTAssertTrue(reopened.localAPIExternalAccessEnabled)
    XCTAssertEqual(reopened.localAPIBindMode, .external)
  }

  func test_local_api_external_access_persists_to_shared_helper_readable_file() throws {
    let defaults = try makeScratchDefaults()
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("app-prefs-local-api-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try PieDirs.$homeOverride.withValue(root) {
      let prefs = AppPreferences(defaults: defaults)
      prefs.setLocalAPIExternalAccessEnabled(true)

      XCTAssertEqual(LocalAPIExposurePreference.loadEnabled(root: root), true)
      XCTAssertEqual(EngineHTTPBindMode.persistedLocalAPIBindMode(root: root), .external)
    }
  }
}
