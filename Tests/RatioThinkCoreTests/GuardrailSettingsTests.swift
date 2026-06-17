import XCTest
@testable import RatioThinkCore

/// Unit tests for `GuardrailSettings`: the file-backed,
/// App↔Helper-shared store for the operator-tuned RAM fraction.
final class GuardrailSettingsTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("guardrail-settings-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  func test_default_when_unset() throws {
    // Absent file is the legitimate unset state — default, no signal.
    XCTAssertEqual(try GuardrailSettings.loadFraction(root: root), GuardrailSettings.defaultFraction)
    XCTAssertEqual(GuardrailSettings.defaultFraction, 0.65)
  }

  func test_round_trip() throws {
    try GuardrailSettings.saveFraction(0.80, root: root)
    XCTAssertEqual(try GuardrailSettings.loadFraction(root: root), 0.80, accuracy: 1e-9)
  }

  func test_save_clamps_out_of_range() throws {
    try GuardrailSettings.saveFraction(0.99, root: root)
    XCTAssertEqual(try GuardrailSettings.loadFraction(root: root),
                   GuardrailSettings.maxFraction, accuracy: 1e-9)
    try GuardrailSettings.saveFraction(0.10, root: root)
    XCTAssertEqual(try GuardrailSettings.loadFraction(root: root),
                   GuardrailSettings.minFraction, accuracy: 1e-9)
  }

  func test_load_clamps_out_of_range_on_disk() throws {
    // A decodable, finite-but-out-of-range value is a recoverable stale
    // write — load must clamp, not signal.
    let url = root.appendingPathComponent("guardrail.json", isDirectory: false)
    try Data(#"{"ramFraction": 9.0}"#.utf8).write(to: url)
    XCTAssertEqual(try GuardrailSettings.loadFraction(root: root),
                   GuardrailSettings.maxFraction, accuracy: 1e-9)
  }

  /// The bug this ticket fixes: a present-but-corrupt file must *signal*,
  /// not collapse into `defaultFraction` (indistinguishable from unset),
  /// which would silently revert the operator's persisted ceiling.
  func test_corrupt_file_throws_rather_than_silent_default() throws {
    let url = root.appendingPathComponent("guardrail.json", isDirectory: false)
    try Data("not json".utf8).write(to: url)
    XCTAssertThrowsError(try GuardrailSettings.loadFraction(root: root)) { error in
      guard case GuardrailSettings.LoadError.corrupt = error else {
        return XCTFail("expected .corrupt, got \(error)")
      }
    }
  }

  /// A present-but-unreadable file (here: a directory where the JSON
  /// should be, so the read fails) signals `.unreadable`, distinct from
  /// both the absent and the corrupt-content cases.
  func test_unreadable_file_throws_unreadable() throws {
    let url = root.appendingPathComponent("guardrail.json", isDirectory: false)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    XCTAssertThrowsError(try GuardrailSettings.loadFraction(root: root)) { error in
      guard case GuardrailSettings.LoadError.unreadable = error else {
        return XCTFail("expected .unreadable, got \(error)")
      }
    }
  }

  func test_matching_preset_detects_presets_and_custom() {
    XCTAssertEqual(GuardrailSettings.matchingPreset(0.55), 0.55)
    XCTAssertEqual(GuardrailSettings.matchingPreset(0.65), 0.65)
    XCTAssertEqual(GuardrailSettings.matchingPreset(0.80), 0.80)
    XCTAssertNil(GuardrailSettings.matchingPreset(0.70), "off-preset value reads as Custom")
    XCTAssertNil(GuardrailSettings.matchingPreset(0.50))
  }

  func test_preset_round_trip_reads_as_that_preset() throws {
    for (_, value) in GuardrailSettings.presets {
      try GuardrailSettings.saveFraction(value, root: root)
      let loaded = try GuardrailSettings.loadFraction(root: root)
      XCTAssertEqual(GuardrailSettings.matchingPreset(loaded), value, "preset \(value) must round-trip")
    }
  }

  func test_constants() {
    XCTAssertEqual(GuardrailSettings.minFraction, 0.50)
    XCTAssertEqual(GuardrailSettings.maxFraction, 0.95)
    XCTAssertEqual(GuardrailSettings.step, 0.05)
    XCTAssertEqual(GuardrailSettings.presets.map(\.value), [0.55, 0.65, 0.80])
  }

  func test_percent_label_renders_whole_percent() {
    XCTAssertEqual(GuardrailSettings.percentLabel(0.65), "65%")
    XCTAssertEqual(GuardrailSettings.percentLabel(0.50), "50%")
    XCTAssertEqual(GuardrailSettings.percentLabel(0.95), "95%")
    XCTAssertEqual(GuardrailSettings.percentLabel(0.80), "80%")
  }

  func test_percent_label_non_finite_falls_back_to_default() {
    XCTAssertEqual(GuardrailSettings.percentLabel(.nan),
                   GuardrailSettings.percentLabel(GuardrailSettings.defaultFraction))
    XCTAssertEqual(GuardrailSettings.percentLabel(.infinity),
                   GuardrailSettings.percentLabel(GuardrailSettings.defaultFraction))
  }

  /// Integration guard for the production wiring (Helper/HelperMain
  /// `buildLaunchSpecResolver` AND the ProfileEditor picker badge — both
  /// now call `ModelMemoryGuardrail.livePolicy`): the policy built from a
  /// persisted `guardrail.json` must reflect the operator's fraction, NOT
  /// the hardcoded default — otherwise the Settings dial silently no-ops
  /// at the launch-time guard and the picker badge disagrees with it (#334).
  /// Uses a fixed RAM value so it never depends on the host's real memory.
  func test_persisted_fraction_drives_memoryPolicy_off_default() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("guardrail-wiring-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let chosen = 0.80
    XCTAssertNotEqual(chosen, ModelMemoryGuardrail.Policy.defaultRAMFraction,
                      "test fraction must differ from the default to prove the wiring")
    try GuardrailSettings.saveFraction(chosen, root: root)

    // The shared derivation HelperMain's memoryPolicy closure and the
    // ProfileEditor picker both call. `livePolicy` reads the persisted
    // fraction through the now-throwing `loadFraction`, logging + falling
    // back only on a present-but-bad file (here the file is a valid save).
    let policy = ModelMemoryGuardrail.livePolicy(
      root: root, physicalMemoryBytes: 64 * 1024 * 1024 * 1024)
    XCTAssertEqual(policy.ramFraction, chosen,
                   "launch-time guardrail must honor the persisted dial fraction, not the default")
  }
}
