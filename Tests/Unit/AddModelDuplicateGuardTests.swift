import XCTest
@testable import RatioThink

/// Pins the #514 pre-enqueue duplicate-guard decision (review v1 F4):
/// `ModelsSettingsTab.duplicateAddDecision` is the classify-or-enqueue
/// choke point, so both branches — blocked (actionError, no enqueue)
/// and proceed (enqueue) — are asserted directly, including the
/// filesystem backstop (kept as defense-in-depth after the store
/// rescope; it catches externally placed files between scans).
final class AddModelDuplicateGuardTests: XCTestCase {

  private let repo = "Qwen/Qwen3-0.6B-GGUF"
  private let file = "Qwen3-0.6B-Q8_0.gguf"
  private var slug: String { "\(repo)/\(file)" }

  private func installedRow(isPartial: Bool = false) -> InstalledModel {
    InstalledModel(filename: slug,
                   url: URL(fileURLWithPath: "/tmp/\(slug)"),
                   sizeBytes: 1,
                   modifiedAt: Date(timeIntervalSince1970: 0),
                   isPartial: isPartial)
  }

  /// Hermetic decision call: the fallback models root is pinned to nil
  /// so a test never consults the real `PieDirs.models()`.
  private func decide(availability: ModelAvailability,
                      modelsDirectory: URL? = nil) -> ModelsSettingsTab.AddDecision {
    ModelsSettingsTab.duplicateAddDecision(
      repo: repo, file: file,
      availability: availability,
      modelsDirectory: modelsDirectory,
      fallbackModelsDirectory: { nil })
  }

  private func makeTempModelsDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("guard-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    return dir
  }

  // MARK: - classifier-driven branches

  func test_installed_slug_blocks_and_names_slug() {
    let decision = decide(availability: ModelAvailability(installed: [installedRow()]))
    guard case .blocked(let reason) = decision else {
      return XCTFail("installed slug must block before enqueue; got \(decision)")
    }
    XCTAssertTrue(reason.contains(slug), "reason must name the slug; got: \(reason)")
  }

  func test_in_flight_slug_blocks() {
    let decision = decide(
      availability: ModelAvailability(inFlight: [(repo: repo, file: file)]))
    XCTAssertNotEqual(decision, .proceed,
                      "a live in-flight download for the same repo/file must block")
  }

  func test_unknown_slug_proceeds() {
    XCTAssertEqual(decide(availability: ModelAvailability()), .proceed)
  }

  func test_partial_installed_row_proceeds() {
    // F1 policy: a partial row in the snapshot must not block the
    // repairing re-download.
    let decision = decide(
      availability: ModelAvailability(installed: [installedRow(isPartial: true)]))
    XCTAssertEqual(decision, .proceed)
  }

  // MARK: - filesystem backstop (defense-in-depth)

  func test_file_on_disk_unknown_to_availability_blocks() throws {
    // An externally placed file the store has not scanned yet — the
    // backstop must block.
    let dir = try makeTempModelsDir()
    let dest = dir.appendingPathComponent(slug)
    try FileManager.default.createDirectory(
      at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("gguf".utf8).write(to: dest)

    let decision = decide(availability: ModelAvailability(), modelsDirectory: dir)
    guard case .blocked(let reason) = decision else {
      return XCTFail("on-disk destination must block despite an availability "
                     + "snapshot that does not know it; got \(decision)")
    }
    XCTAssertTrue(reason.contains(slug))
  }

  func test_partial_destination_on_disk_proceeds() throws {
    // F1 policy consistency: a destination with a `.partial` sibling is
    // a broken install — the re-download repairs it, so it proceeds.
    let dir = try makeTempModelsDir()
    let dest = dir.appendingPathComponent(slug)
    try FileManager.default.createDirectory(
      at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("gguf".utf8).write(to: dest)
    try Data().write(to: URL(fileURLWithPath: dest.path + InstalledModels.partialSuffix))

    XCTAssertEqual(decide(availability: ModelAvailability(), modelsDirectory: dir),
                   .proceed,
                   "a partial (broken) destination is not a duplicate — blocking "
                   + "it would leave delete-then-re-add as the only repair path")
  }

  func test_directory_at_destination_proceeds() throws {
    // cycle-607 minor: a DIRECTORY at the destination path is not an
    // installed model file and must not false-block the download.
    let dir = try makeTempModelsDir()
    try FileManager.default.createDirectory(
      at: dir.appendingPathComponent(slug), withIntermediateDirectories: true)

    XCTAssertEqual(decide(availability: ModelAvailability(), modelsDirectory: dir),
                   .proceed)
  }

  func test_nil_models_directory_uses_fallback() throws {
    // cycle-607 minor: before the first scan `modelsDirectory` is nil;
    // the backstop resolves the models root itself rather than
    // silently skipping.
    let dir = try makeTempModelsDir()
    let dest = dir.appendingPathComponent(slug)
    try FileManager.default.createDirectory(
      at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("gguf".utf8).write(to: dest)

    let decision = ModelsSettingsTab.duplicateAddDecision(
      repo: repo, file: file,
      availability: ModelAvailability(),
      modelsDirectory: nil,
      fallbackModelsDirectory: { dir })
    XCTAssertNotEqual(decision, .proceed,
                      "with modelsDirectory nil the backstop must consult the "
                      + "fallback models root, not silently skip")
  }

  // MARK: - enqueue-failure copy (deferred follow-up fold-in)

  func test_enqueue_failure_message_prefers_producer_reason() {
    XCTAssertEqual(ModelsSettingsTab.enqueueFailureMessage("disk full"), "disk full")
  }

  func test_enqueue_failure_message_never_silent_on_nil() {
    XCTAssertEqual(ModelsSettingsTab.enqueueFailureMessage(nil),
                   "Download could not be queued.")
  }
}
