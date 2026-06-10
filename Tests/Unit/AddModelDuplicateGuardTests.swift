import XCTest
@testable import RatioThink

/// Pins the #514 pre-enqueue duplicate-guard decision (review v1 F4):
/// `ModelsSettingsTab.duplicateAddDecision` is the classify-or-enqueue
/// choke point, so both branches — blocked (actionError, no enqueue)
/// and proceed (enqueue) — are asserted directly, including the
/// review v1 F2 filesystem backstop for an install the `installed`
/// snapshot is too stale to know about.
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

  private func makeTempModelsDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("guard-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    return dir
  }

  // MARK: - classifier-driven branches

  func test_installed_slug_blocks_and_names_slug() {
    let decision = ModelsSettingsTab.duplicateAddDecision(
      repo: repo, file: file,
      installed: [installedRow()], inFlight: [], modelsDirectory: nil)
    guard case .blocked(let reason) = decision else {
      return XCTFail("installed slug must block before enqueue; got \(decision)")
    }
    XCTAssertTrue(reason.contains(slug), "reason must name the slug; got: \(reason)")
  }

  func test_in_flight_slug_blocks() {
    let decision = ModelsSettingsTab.duplicateAddDecision(
      repo: repo, file: file,
      installed: [], inFlight: [(repo: repo, file: file)], modelsDirectory: nil)
    XCTAssertNotEqual(decision, .proceed,
                      "a live in-flight download for the same repo/file must block")
  }

  func test_unknown_slug_proceeds() {
    let decision = ModelsSettingsTab.duplicateAddDecision(
      repo: repo, file: file,
      installed: [], inFlight: [], modelsDirectory: nil)
    XCTAssertEqual(decision, .proceed)
  }

  // MARK: - filesystem backstop (review v1 F2)

  func test_stale_snapshot_with_file_on_disk_blocks() throws {
    // The `installed` snapshot is empty (refresh() hasn't landed) but
    // the exact destination exists on disk — the backstop must block.
    let dir = try makeTempModelsDir()
    let dest = dir.appendingPathComponent(slug)
    try FileManager.default.createDirectory(
      at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("gguf".utf8).write(to: dest)

    let decision = ModelsSettingsTab.duplicateAddDecision(
      repo: repo, file: file,
      installed: [], inFlight: [], modelsDirectory: dir)
    guard case .blocked(let reason) = decision else {
      return XCTFail("on-disk destination must block despite a stale empty "
                     + "installed snapshot (review v1 F2); got \(decision)")
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

    let decision = ModelsSettingsTab.duplicateAddDecision(
      repo: repo, file: file,
      installed: [], inFlight: [], modelsDirectory: dir)
    XCTAssertEqual(decision, .proceed,
                   "a partial (broken) destination is not a duplicate — blocking "
                   + "it would leave delete-then-re-add as the only repair path")
  }

  func test_partial_installed_row_proceeds() {
    // Same policy through the classifier axis: a partial row in the
    // snapshot must not block the repairing re-download.
    let decision = ModelsSettingsTab.duplicateAddDecision(
      repo: repo, file: file,
      installed: [installedRow(isPartial: true)], inFlight: [], modelsDirectory: nil)
    XCTAssertEqual(decision, .proceed)
  }
}
