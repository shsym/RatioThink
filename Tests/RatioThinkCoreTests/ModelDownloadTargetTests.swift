import XCTest
@testable import RatioThinkCore

/// Unit tests for `CuratedModelCatalog.downloadTarget(forModelSlug:)` —
/// the pure mapping #326 uses to turn a profile's stored model SLUG into
/// a single-file GGUF download the no-model / failed(modelMissing)
/// surfaces can hand to `ModelDownloadController.enqueue(repo:file:)`.
final class ModelDownloadTargetTests: XCTestCase {

  /// The seeded default profile slug must map to the recommended
  /// curated entry — same `(repo, file)` the one-click starter
  /// downloads, plus its honest display name + published size. This is
  /// the fresh-install happy path: "Load the default" with nothing on
  /// disk becomes "Download Qwen3 0.6B (639 MB)".
  func test_seeded_default_slug_maps_to_recommended_curated_entry() {
    let target = CuratedModelCatalog.downloadTarget(
      forModelSlug: ProfileStore.defaultChatModelID)
    XCTAssertEqual(target?.repo, "Qwen/Qwen3-0.6B-GGUF")
    XCTAssertEqual(target?.file, "Qwen3-0.6B-Q8_0.gguf")
    XCTAssertEqual(target?.displayName, "Qwen3 0.6B")
    XCTAssertEqual(target?.approximateSizeBytes, 639_446_688)
  }

  /// A slug that matches any curated entry's `<repo>/<file>` resolves to
  /// that entry so the UI shows the curated display name + size, not a
  /// raw leaf filename.
  func test_curated_match_carries_display_name_and_size() {
    let llama = CuratedModelCatalog.model(withID: "llama-3.2-1b-instruct-q4_k_m")!
    let slug = "\(llama.huggingFaceRepo)/\(llama.huggingFaceFile)"
    let target = CuratedModelCatalog.downloadTarget(forModelSlug: slug)
    XCTAssertEqual(target?.repo, llama.huggingFaceRepo)
    XCTAssertEqual(target?.file, llama.huggingFaceFile)
    XCTAssertEqual(target?.displayName, llama.displayName)
    XCTAssertEqual(target?.approximateSizeBytes, llama.approximateSizeBytes)
  }

  /// A non-curated 3-segment GGUF slug still downloads — split into
  /// `(repo, file)` with the leaf as the display name and unknown size
  /// (we have no published byte count for an arbitrary repo).
  func test_noncurated_three_segment_gguf_slug_splits_to_repo_and_file() {
    let target = CuratedModelCatalog.downloadTarget(
      forModelSlug: "TheBloke/Mistral-7B-Instruct-GGUF/mistral-7b-instruct.Q4_K_M.gguf")
    XCTAssertEqual(target?.repo, "TheBloke/Mistral-7B-Instruct-GGUF")
    XCTAssertEqual(target?.file, "mistral-7b-instruct.Q4_K_M.gguf")
    XCTAssertEqual(target?.displayName, "mistral-7b-instruct.Q4_K_M.gguf")
    XCTAssertNil(target?.approximateSizeBytes,
                 "an arbitrary repo carries no published size — must be nil, never a guess")
  }

  /// A 2-segment slug is a safetensors snapshot-DIR reference. pie loads
  /// it as a directory (multi-file), which the single-file
  /// `ModelDownloader.start(repo:file:)` cannot fetch — so there is no
  /// inline download target. The UI falls back to "Open Settings →
  /// Models" for these.
  func test_two_segment_safetensors_slug_has_no_single_file_target() {
    XCTAssertNil(CuratedModelCatalog.downloadTarget(forModelSlug: "Qwen/Qwen3-0.6B"))
  }

  /// A bare leaf filename carries no repo, so no HF download is
  /// derivable — nil (the user must import it locally instead).
  func test_bare_leaf_filename_has_no_target() {
    XCTAssertNil(CuratedModelCatalog.downloadTarget(forModelSlug: "some-model.gguf"))
  }

  /// A 3-segment slug whose file is not a `.gguf` is not a single-file
  /// GGUF download — nil (we only auto-download GGUF files in v1).
  func test_three_segment_non_gguf_file_has_no_target() {
    XCTAssertNil(CuratedModelCatalog.downloadTarget(
      forModelSlug: "org/repo/model.safetensors"))
  }

  /// Empty / whitespace slug is never a target.
  func test_empty_slug_has_no_target() {
    XCTAssertNil(CuratedModelCatalog.downloadTarget(forModelSlug: ""))
    XCTAssertNil(CuratedModelCatalog.downloadTarget(forModelSlug: "   "))
  }
}
