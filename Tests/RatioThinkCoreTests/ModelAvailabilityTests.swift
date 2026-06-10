import XCTest
@testable import RatioThinkCore

/// #514 — the Add Model duplicate guard. Pins that classification is
/// by canonical `<repo>/<file>` slug only: basename or display-name
/// collisions must NOT mark a different model as installed, and the
/// app-managed / HF-cache / in-flight sources each map to their own
/// status with the documented precedence.
final class ModelAvailabilityTests: XCTestCase {

  private func row(_ filename: String,
                   source: CachedModelSource = .appManaged,
                   isPartial: Bool = false,
                   metadataUnreadable: Bool = false) -> InstalledModel {
    InstalledModel(filename: filename,
                   url: URL(fileURLWithPath: "/tmp/\(filename)"),
                   sizeBytes: 1,
                   modifiedAt: Date(timeIntervalSince1970: 0),
                   isPartial: isPartial,
                   metadataUnreadable: metadataUnreadable,
                   source: source)
  }

  // MARK: - slug equality

  func test_app_managed_slug_match_is_installed() {
    let availability = ModelAvailability(
      installed: [row("Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf")])
    XCTAssertEqual(
      availability.status(repo: "Qwen/Qwen3-0.6B-GGUF", file: "Qwen3-0.6B-Q8_0.gguf"),
      .installedAppManaged)
  }

  func test_unknown_candidate_is_available_to_download() {
    let availability = ModelAvailability(
      installed: [row("Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf")])
    XCTAssertEqual(
      availability.status(repo: "Qwen/Qwen2.5-1.5B-Instruct-GGUF",
                          file: "qwen2.5-1.5b-instruct-q4_k_m.gguf"),
      .availableToDownload)
  }

  // MARK: - collisions must NOT match

  func test_basename_collision_does_not_match() {
    // Same leaf file, different repo — a different model. The bare
    // leaf is also what a top-level local import produces; it must
    // not block the curated download of the nested slug.
    let availability = ModelAvailability(
      installed: [row("Qwen3-0.6B-Q8_0.gguf"),
                  row("someoneelse/Mirror-GGUF/Qwen3-0.6B-Q8_0.gguf")])
    XCTAssertEqual(
      availability.status(repo: "Qwen/Qwen3-0.6B-GGUF", file: "Qwen3-0.6B-Q8_0.gguf"),
      .availableToDownload)
  }

  func test_display_name_collision_does_not_match() {
    // Two curated entries can share publisher/params-style display
    // labels; identity is the slug. An installed row whose displayName
    // ("Qwen3-0.6B-Q8_0.gguf") matches the candidate's leaf but whose
    // slug differs must not classify as installed.
    let installed = row("mirror/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf")
    XCTAssertEqual(installed.displayName, "Qwen3-0.6B-Q8_0.gguf")
    let availability = ModelAvailability(installed: [installed])
    XCTAssertEqual(
      availability.status(repo: "Qwen/Qwen3-0.6B-GGUF", file: "Qwen3-0.6B-Q8_0.gguf"),
      .availableToDownload)
  }

  // MARK: - broken / degraded installs (review v1 F1)

  func test_partial_install_stays_available_to_download() {
    // An interrupted download (.partial sibling) is broken bytes, not
    // an install — "Installed" would block the repairing re-download.
    let availability = ModelAvailability(
      installed: [row("Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf", isPartial: true)])
    XCTAssertEqual(
      availability.status(repo: "Qwen/Qwen3-0.6B-GGUF", file: "Qwen3-0.6B-Q8_0.gguf"),
      .availableToDownload)
  }

  func test_partial_hf_cache_row_stays_available_to_download() {
    let availability = ModelAvailability(
      installed: [row("Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf",
                      source: .huggingFaceCache, isPartial: true)])
    XCTAssertEqual(
      availability.status(repo: "Qwen/Qwen3-0.6B-GGUF", file: "Qwen3-0.6B-Q8_0.gguf"),
      .availableToDownload)
  }

  func test_metadata_unreadable_install_still_counts_as_installed() {
    // Policy: only the size/date read failed — the file is present, so
    // a fresh download is still redundant.
    let availability = ModelAvailability(
      installed: [row("Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf",
                      metadataUnreadable: true)])
    XCTAssertEqual(
      availability.status(repo: "Qwen/Qwen3-0.6B-GGUF", file: "Qwen3-0.6B-Q8_0.gguf"),
      .installedAppManaged)
  }

  // MARK: - source mapping

  func test_hf_cache_row_is_available_in_hf_cache() {
    let availability = ModelAvailability(
      installed: [row("Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf",
                      source: .huggingFaceCache)])
    XCTAssertEqual(
      availability.status(repo: "Qwen/Qwen3-0.6B-GGUF", file: "Qwen3-0.6B-Q8_0.gguf"),
      .availableInHFCache)
  }

  func test_app_managed_wins_over_hf_cache() {
    // The Models tab dedupes keeping the app-managed row; the
    // classifier must agree even when fed both.
    let availability = ModelAvailability(
      installed: [row("Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf", source: .appManaged),
                  row("Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf", source: .huggingFaceCache)])
    XCTAssertEqual(
      availability.status(repo: "Qwen/Qwen3-0.6B-GGUF", file: "Qwen3-0.6B-Q8_0.gguf"),
      .installedAppManaged)
  }

  // MARK: - in-flight

  func test_in_flight_download_is_downloading() {
    let availability = ModelAvailability(
      inFlight: [(repo: "Qwen/Qwen3-0.6B-GGUF", file: "Qwen3-0.6B-Q8_0.gguf")])
    XCTAssertEqual(
      availability.status(repo: "Qwen/Qwen3-0.6B-GGUF", file: "Qwen3-0.6B-Q8_0.gguf"),
      .downloading)
  }

  func test_downloading_takes_precedence_over_installed() {
    let availability = ModelAvailability(
      installed: [row("Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf")],
      inFlight: [(repo: "Qwen/Qwen3-0.6B-GGUF", file: "Qwen3-0.6B-Q8_0.gguf")])
    XCTAssertEqual(
      availability.status(repo: "Qwen/Qwen3-0.6B-GGUF", file: "Qwen3-0.6B-Q8_0.gguf"),
      .downloading)
  }

  func test_in_flight_other_file_does_not_block() {
    let availability = ModelAvailability(
      inFlight: [(repo: "Qwen/Qwen3-0.6B-GGUF", file: "Qwen3-0.6B-Q4_K_M.gguf")])
    XCTAssertEqual(
      availability.status(repo: "Qwen/Qwen3-0.6B-GGUF", file: "Qwen3-0.6B-Q8_0.gguf"),
      .availableToDownload)
  }

  // MARK: - Status surface

  func test_only_available_to_download_allows_add() {
    XCTAssertTrue(ModelAvailability.Status.availableToDownload.allowsAdd)
    XCTAssertFalse(ModelAvailability.Status.downloading.allowsAdd)
    XCTAssertFalse(ModelAvailability.Status.installedAppManaged.allowsAdd)
    XCTAssertFalse(ModelAvailability.Status.availableInHFCache.allowsAdd)
  }

  func test_blocked_reason_nil_only_when_addable() {
    XCTAssertNil(ModelAvailability.Status.availableToDownload.blockedReason(slug: "a/b/c.gguf"))
    for status: ModelAvailability.Status in [.downloading, .installedAppManaged, .availableInHFCache] {
      let reason = status.blockedReason(slug: "a/b/c.gguf")
      XCTAssertNotNil(reason)
      XCTAssertTrue(reason?.contains("a/b/c.gguf") == true,
                    "reason must name the slug; got \(reason ?? "nil")")
    }
  }

  func test_badge_text_per_status() {
    XCTAssertNil(ModelAvailability.Status.availableToDownload.badgeText)
    XCTAssertEqual(ModelAvailability.Status.downloading.badgeText, "Downloading…")
    XCTAssertEqual(ModelAvailability.Status.installedAppManaged.badgeText, "Installed")
    XCTAssertEqual(ModelAvailability.Status.availableInHFCache.badgeText, "In library")
  }
}
