import AppKit
import XCTest

/// Skip when no seated GUI session present (e.g. SSH without Screen Sharing).
///
/// The XCTRunner template ships with `com.apple.security.app-sandbox=true`, so
/// `Process` cannot exec `/usr/bin/pgrep`. Query the workspace instead — the
/// Dock's bundle identifier is stable and `runningApplications` is
/// sandbox-safe.
func guardSeatedGUI() throws {
  let dockRunning = NSWorkspace.shared.runningApplications.contains { app in
    app.bundleIdentifier == "com.apple.dock"
  }
  try XCTSkipUnless(dockRunning,
                    "No seated GUI session detected (Dock not running). " +
                    "Connect via Screen Sharing / sit at the console to run GUI tests.")
}

func configureCompletedFirstLaunch(
  _ app: XCUIApplication,
  suiteName: String = "com.ratiothink.app.gui." + UUID().uuidString
) {
  app.launchEnvironment["PIE_APP_PREFERENCES_SUITE"] = suiteName
  app.launchEnvironment["PIE_TEST_FIRST_LAUNCH_COMPLETED"] = "1"
}

func stablePreferenceSuiteName(_ seed: String) -> String {
  let safe = seed.map { char -> Character in
    char.isLetter || char.isNumber ? char : "."
  }
  return "com.ratiothink.app.gui." + String(safe).prefix(180)
}
