import XCTest
@testable import RatioThink

/// `AppPreferences` is `@MainActor`. Mark the suite likewise so the
/// `UserDefaults` reads/writes hop on the right actor without needing
/// per-test `await MainActor.run` blocks.
///
///  removed the swap skip-set; the remaining preferences are user-visible
/// launch-time flags.
@MainActor
final class AppPreferencesTests: XCTestCase {
  private var tempRoot: URL!

  override func invokeTest() {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("app-prefs-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    tempRoot = root
    defer {
      try? FileManager.default.removeItem(at: root)
      tempRoot = nil
    }
    PieDirs.$homeOverride.withValue(root) {
      super.invokeTest()
    }
  }

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

    try prefs.setLocalAPIExternalAccessEnabled(true)

    XCTAssertTrue(prefs.localAPIExternalAccessEnabled)
    XCTAssertEqual(prefs.localAPIBindMode, .external)

    let reopened = AppPreferences(defaults: defaults)
    XCTAssertTrue(reopened.localAPIExternalAccessEnabled)
    XCTAssertEqual(reopened.localAPIBindMode, .external)
  }

  func test_local_api_external_access_persists_to_shared_helper_readable_file() throws {
    let defaults = try makeScratchDefaults()

    let prefs = AppPreferences(defaults: defaults)
    try prefs.setLocalAPIExternalAccessEnabled(true)

    XCTAssertEqual(LocalAPIExposurePreference.loadEnabled(root: tempRoot), true)
    XCTAssertEqual(EngineHTTPBindMode.persistedLocalAPIBindMode(root: tempRoot), .external)
  }

  func test_local_api_external_access_write_failure_leaves_app_and_shared_state_external() throws {
    struct StubError: Error {}
    let defaults = try makeScratchDefaults()
    defaults.set(true, forKey: AppPreferences.localAPIExternalAccessEnabledKey)
    try LocalAPIExposurePreference.saveEnabled(true, root: tempRoot)
    let prefs = AppPreferences(
      defaults: defaults,
      localAPIExposurePreference: LocalAPIExposurePreference.Store(
        loadEnabled: { true },
        saveEnabled: { _ in throw StubError() }
      )
    )

    XCTAssertThrowsError(try prefs.setLocalAPIExternalAccessEnabled(false))

    XCTAssertTrue(prefs.localAPIExternalAccessEnabled,
                  "app state must not claim loopback when the helper-readable file could not be updated")
    XCTAssertEqual(prefs.localAPIBindMode, .external)
    XCTAssertTrue(defaults.bool(forKey: AppPreferences.localAPIExternalAccessEnabledKey),
                  "UserDefaults mirror must not flip until the shared source-of-truth write succeeds")
    XCTAssertEqual(LocalAPIExposurePreference.loadEnabled(root: tempRoot), true)
  }

  func test_local_api_auto_start_defaults_off() throws {
    let defaults = try makeScratchDefaults()
    let prefs = AppPreferences(defaults: defaults)

    XCTAssertFalse(prefs.localAPIAutoStartEnabled,
                   "Local API must not start automatically unless the user opts in")
  }

  func test_local_api_auto_start_preference_persists() throws {
    let defaults = try makeScratchDefaults()
    let prefs = AppPreferences(defaults: defaults)

    prefs.setLocalAPIAutoStartEnabled(true)

    XCTAssertTrue(prefs.localAPIAutoStartEnabled)
    let reopened = AppPreferences(defaults: defaults)
    XCTAssertTrue(reopened.localAPIAutoStartEnabled)

    reopened.setLocalAPIAutoStartEnabled(false)
    let reopenedAgain = AppPreferences(defaults: defaults)
    XCTAssertFalse(reopenedAgain.localAPIAutoStartEnabled)
  }

  func test_follow_profile_default_model_defaults_off() throws {
    let defaults = try makeScratchDefaults()
    let prefs = AppPreferences(defaults: defaults)

    XCTAssertFalse(prefs.followProfileDefaultModel,
                   "explicit model selections should stay pinned across profile changes unless the user opts into follow-default compatibility")
  }

  func test_follow_profile_default_model_preference_persists() throws {
    let defaults = try makeScratchDefaults()
    let prefs = AppPreferences(defaults: defaults)

    prefs.setFollowProfileDefaultModel(true)

    XCTAssertTrue(prefs.followProfileDefaultModel)
    let reopened = AppPreferences(defaults: defaults)
    XCTAssertTrue(reopened.followProfileDefaultModel)
  }
}
