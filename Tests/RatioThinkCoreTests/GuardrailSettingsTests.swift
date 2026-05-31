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

  func test_default_when_unset() {
    XCTAssertEqual(GuardrailSettings.loadFraction(root: root), GuardrailSettings.defaultFraction)
    XCTAssertEqual(GuardrailSettings.defaultFraction, 0.65)
  }

  func test_round_trip() throws {
    try GuardrailSettings.saveFraction(0.80, root: root)
    XCTAssertEqual(GuardrailSettings.loadFraction(root: root), 0.80, accuracy: 1e-9)
  }

  func test_save_clamps_out_of_range() throws {
    try GuardrailSettings.saveFraction(0.99, root: root)
    XCTAssertEqual(GuardrailSettings.loadFraction(root: root),
                   GuardrailSettings.maxFraction, accuracy: 1e-9)
    try GuardrailSettings.saveFraction(0.10, root: root)
    XCTAssertEqual(GuardrailSettings.loadFraction(root: root),
                   GuardrailSettings.minFraction, accuracy: 1e-9)
  }

  func test_load_clamps_out_of_range_on_disk() throws {
    // Hand-write an out-of-range value (a stale/corrupt file) — load must clamp.
    let url = root.appendingPathComponent("guardrail.json", isDirectory: false)
    try Data(#"{"ramFraction": 9.0}"#.utf8).write(to: url)
    XCTAssertEqual(GuardrailSettings.loadFraction(root: root),
                   GuardrailSettings.maxFraction, accuracy: 1e-9)
  }

  func test_corrupt_file_falls_back_to_default() throws {
    let url = root.appendingPathComponent("guardrail.json", isDirectory: false)
    try Data("not json".utf8).write(to: url)
    XCTAssertEqual(GuardrailSettings.loadFraction(root: root), GuardrailSettings.defaultFraction)
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
      let loaded = GuardrailSettings.loadFraction(root: root)
      XCTAssertEqual(GuardrailSettings.matchingPreset(loaded), value, "preset \(value) must round-trip")
    }
  }

  func test_constants() {
    XCTAssertEqual(GuardrailSettings.minFraction, 0.50)
    XCTAssertEqual(GuardrailSettings.maxFraction, 0.95)
    XCTAssertEqual(GuardrailSettings.step, 0.05)
    XCTAssertEqual(GuardrailSettings.presets.map(\.value), [0.55, 0.65, 0.80])
  }

  /// Integration guard for the production wiring (Helper/HelperMain
  /// `buildLaunchSpecResolver`): the `memoryPolicy` built from a persisted
  /// `guardrail.json` must reflect the operator's fraction, NOT the
  /// hardcoded default — otherwise the Settings dial silently no-ops at
  /// the launch-time guard. Reproduces the production composition with a
  /// fixed RAM value so it never depends on the host's real memory.
  func test_persisted_fraction_drives_memoryPolicy_off_default() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("guardrail-wiring-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let chosen = 0.80
    XCTAssertNotEqual(chosen, ModelMemoryGuardrail.Policy.defaultRAMFraction,
                      "test fraction must differ from the default to prove the wiring")
    try GuardrailSettings.saveFraction(chosen, root: root)

    // The exact composition HelperMain's production memoryPolicy closure
    // uses.
    let policy = ModelMemoryGuardrail.Policy.recommended(
      physicalMemoryBytes: 64 * 1024 * 1024 * 1024,
      fraction: GuardrailSettings.loadFraction(root: root)
    )
    XCTAssertEqual(policy.ramFraction, chosen,
                   "launch-time guardrail must honor the persisted dial fraction, not the default")
  }
}
