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
