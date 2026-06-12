import XCTest
@testable import RatioThink

/// Guards the launchd agent plist contract that makes Helper-death
/// recovery work.
///
/// The live "register agent → kill Helper → launchd respawns it →
/// `com.ratiothink.helper` republished" path requires a code-signed build with
/// a real Team ID (SMAppService refuses an unsigned agent), so it is not
/// runnable on an unsigned CI runner and is validated manually on a
/// signed build instead (see  / Scripts).
///
/// What IS ours to regress — and what this test pins — is the plist
/// itself: the keys whose absence silently reverts the fix. If the
/// staging script breaks or someone drops `MachServices`, launchd stops
/// owning `com.ratiothink.helper` and the 4099-until-logout gap returns. This
/// asserts the plist as actually staged into the built app bundle, so it
/// also covers the project.yml postCompileScript wiring.
final class HelperLaunchAgentPlistTests: XCTestCase {
  private func stagedPlist() throws -> [String: Any] {
    // RatioThinkTests is hosted by RatioThink, so this class's bundle IS Rational.app.
    let appBundle = Bundle(for: SMAppServiceLoginItemRegistrar.self)
    let plistURL = appBundle.bundleURL
      .appendingPathComponent("Contents/Library/LaunchAgents")
      .appendingPathComponent(SMAppServiceLoginItemRegistrar.defaultPlistName)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: plistURL.path),
      "agent plist not staged at \(plistURL.path) — project.yml postCompileStep regressed"
    )
    let data = try Data(contentsOf: plistURL)
    let parsed = try PropertyListSerialization.propertyList(from: data, format: nil)
    return try XCTUnwrap(parsed as? [String: Any], "agent plist is not a dictionary")
  }

  func test_label_matches_registrar_identifier() throws {
    let plist = try stagedPlist()
    XCTAssertEqual(plist["Label"] as? String, "com.ratiothink.app.helper")
  }

  func test_declares_com_pie_helper_machservice_on_demand() throws {
    // The crux of the fix: without this key launchd never owns
    // com.ratiothink.helper and a dead Helper is never republished.
    let plist = try stagedPlist()
    let machServices = try XCTUnwrap(
      plist["MachServices"] as? [String: Any],
      "plist must declare MachServices or launchd cannot own com.ratiothink.helper"
    )
    XCTAssertEqual(
      machServices["com.ratiothink.helper"] as? Bool, true,
      "com.ratiothink.helper must be an on-demand MachService"
    )
    XCTAssertEqual(
      machServices["com.ratiothink.helper"] as? Bool,
      machServices[HelperConfig.defaultXPCService] as? Bool,
      "MachService name must track HelperConfig.defaultXPCService"
    )
  }

  func test_bundleProgram_resolves_to_a_real_executable_in_the_app() throws {
    let plist = try stagedPlist()
    let bundleProgram = try XCTUnwrap(
      plist["BundleProgram"] as? String,
      "agent must use BundleProgram (bundle-relative), not an absolute Program path"
    )
    let appBundle = Bundle(for: SMAppServiceLoginItemRegistrar.self)
    let exe = appBundle.bundleURL.appendingPathComponent(bundleProgram)
    XCTAssertTrue(
      FileManager.default.isExecutableFile(atPath: exe.path),
      "BundleProgram \(bundleProgram) does not resolve to an executable inside the app bundle"
    )
  }

  func test_keepAlive_relaunches_on_unclean_exit() throws {
    // Relaunch after crash/OOM/force-quit (the reported symptom), while a
    // clean user-quit stays down.
    let plist = try stagedPlist()
    let keepAlive = try XCTUnwrap(
      plist["KeepAlive"] as? [String: Any],
      "KeepAlive required so a crashed Helper is relaunched"
    )
    XCTAssertEqual(
      keepAlive["SuccessfulExit"] as? Bool, false,
      "KeepAlive must relaunch only on unclean exit"
    )
  }
}
