import XCTest
@testable import RatioThinkCore

/// Unit tests for the hand-curated `CuratedModelCatalog`. The catalog
/// is data-only, so the assertions here are invariants the UI relies
/// on: stable IDs, ascending size sort, and non-empty repo/file pairs
/// so every entry can in fact be fed to `ModelDownloader.start`.
final class CuratedModelCatalogTests: XCTestCase {

  func test_catalog_is_non_empty() {
    XCTAssertFalse(CuratedModelCatalog.all.isEmpty,
                   "the curated catalog must surface at least one entry — empty catalogs lie to users")
  }

  func test_catalog_ids_are_unique() {
    let ids = CuratedModelCatalog.all.map(\.id)
    XCTAssertEqual(Set(ids).count, ids.count,
                   "id collisions would break SwiftUI list diffing")
  }

  func test_catalog_is_sorted_ascending_by_size() {
    let sizes = CuratedModelCatalog.all.map(\.approximateSizeBytes)
    XCTAssertEqual(sizes, sizes.sorted(),
                   "catalog must be sorted ascending so the smallest model is the first-run pick")
  }

  func test_every_entry_carries_repo_and_file() {
    for m in CuratedModelCatalog.all {
      XCTAssertFalse(m.huggingFaceRepo.isEmpty, "repo missing for \(m.id)")
      XCTAssertFalse(m.huggingFaceFile.isEmpty, "file missing for \(m.id)")
      XCTAssertTrue(m.huggingFaceFile.lowercased().hasSuffix(".gguf"),
                    "curated file must be a .gguf — \(m.huggingFaceFile)")
    }
  }

  func test_model_lookup_by_id() {
    let first = CuratedModelCatalog.all.first!
    XCTAssertEqual(CuratedModelCatalog.model(withID: first.id)?.id, first.id)
    XCTAssertNil(CuratedModelCatalog.model(withID: "no-such-model"))
  }

  func test_recommended_starter_resolves_to_a_small_catalog_entry() {
    let recommended = CuratedModelCatalog.model(withID: CuratedModelCatalog.recommendedModelID)
    XCTAssertNotNil(recommended,
                    "recommendedModelID must resolve to a real catalog entry")
    // Starter recommendation must be small enough to download quickly on
    // a fresh install —  keeps it under ~1 GB.
    XCTAssertLessThan(recommended?.approximateSizeBytes ?? .max, 1_000_000_000,
                      "recommended starter must be a small first-run model")
  }

  func test_starter_tier_models_are_present() {
    let ids = Set(CuratedModelCatalog.all.map(\.id))
    for starter in ["qwen2.5-0.5b-instruct-q4_k_m",
                    "qwen3-0.6b-q8_0",
                    "llama-3.2-1b-instruct-q4_k_m"] {
      XCTAssertTrue(ids.contains(starter),
                    " starter \(starter) missing from catalog")
    }
  }

  /// The Settings → Models curated "Add" hands `(huggingFaceRepo,
  /// huggingFaceFile)` straight to `ModelDownloader.start`. Pin the
  /// recommended starter's exact download coordinates so a typo in the
  /// catalog can't silently point the one-click starter at a
  /// non-existent HF file. Verified against the live HF repo.
  func test_recommended_starter_download_coordinates_match_published_gguf() {
    let recommended = CuratedModelCatalog.model(withID: CuratedModelCatalog.recommendedModelID)
    XCTAssertEqual(recommended?.huggingFaceRepo, "Qwen/Qwen3-0.6B-GGUF")
    XCTAssertEqual(recommended?.huggingFaceFile, "Qwen3-0.6B-Q8_0.gguf")
  }

  ///  review v2 F1: the seeded default must RESOLVE to where the
  /// recommended curated starter actually downloads — not merely share a
  /// leaf filename. `ModelDownloader` writes `<modelsRoot>/<repo>/<file>`
  /// and `LaunchSpecResolver.joinModelPath` resolves the seeded slug; the
  /// two must produce the same path. This fails if the seed regresses to
  /// a bare leaf name (the v1 bug) that joins to a flat top-level path.
  func test_seeded_default_resolves_to_recommended_download_destination() {
    let recommended = CuratedModelCatalog.model(withID: CuratedModelCatalog.recommendedModelID)!
    let modelsRoot = URL(fileURLWithPath: "/tmp/pie-models-test", isDirectory: true)

    let downloadSlug = "\(recommended.huggingFaceRepo)/\(recommended.huggingFaceFile)"
    let downloadDestination = LaunchSpecResolver.joinModelPath(
      modelsRoot: modelsRoot, slug: downloadSlug)
    let seededResolved = LaunchSpecResolver.joinModelPath(
      modelsRoot: modelsRoot, slug: ProfileStore.defaultChatModelID)

    XCTAssertEqual(seededResolved, downloadDestination,
                   "seeded default must resolve to where ModelDownloader writes the recommended starter")
    XCTAssertTrue(seededResolved.contains("/\(recommended.huggingFaceRepo)/"),
                  "resolved path must be nested under the repo, not a flat top-level leaf name")
  }

  // MARK: - single-file-GGUF shape guards (#425)

  /// Every curated entry must be shaped as a SINGLE-FILE GGUF download:
  /// a 2-segment `<org>/<name>` repo and a single `.gguf` leaf with no
  /// path separators. pie loads one `.gguf` via `gguf_init_from_file`
  /// (and `ModelDownloader.start(repo:file:)` fetches one blob), so a
  /// directory slug or a nested path could never download-and-launch.
  /// This is the offline tripwire for the #425 class of bug.
  func test_every_curated_entry_is_shaped_as_a_single_file_gguf_download() {
    for m in CuratedModelCatalog.all {
      let repoSegments = m.huggingFaceRepo
        .split(separator: "/", omittingEmptySubsequences: true)
      XCTAssertEqual(repoSegments.count, 2,
                     "repo must be a 2-segment <org>/<name> for \(m.id): \(m.huggingFaceRepo)")
      XCTAssertFalse(m.huggingFaceFile.contains("/"),
                     "curated file must be a single leaf, not a nested path for \(m.id): \(m.huggingFaceFile)")
      XCTAssertTrue(m.huggingFaceFile.lowercased().hasSuffix(".gguf"),
                    "curated file must be a .gguf for \(m.id): \(m.huggingFaceFile)")

      // The slug the UI hands to the download path must resolve back to
      // exactly this single-file target — proves the entry is consumable
      // by `ModelDownloadController.enqueue(repo:file:)`, not a dir slug
      // that `downloadTarget` rejects (returns nil).
      let slug = "\(m.huggingFaceRepo)/\(m.huggingFaceFile)"
      let target = CuratedModelCatalog.downloadTarget(forModelSlug: slug)
      XCTAssertEqual(target?.repo, m.huggingFaceRepo,
                     "curated slug must resolve to its own repo for \(m.id)")
      XCTAssertEqual(target?.file, m.huggingFaceFile,
                     "curated slug must resolve to its own file for \(m.id)")
    }
  }

  /// No curated entry may point at a split GGUF shard
  /// (`…-NNNNN-of-MMMMM.gguf`). Reuses the SAME detector the launch path
  /// (`LaunchSpecResolver`) and cache discovery (`HFCacheCatalog`) use to
  /// refuse split models, so the curated catalog can't silently surface
  /// what the engine would reject downstream. Catches a maintainer
  /// pasting a shard filename from a split-only repo.
  func test_no_curated_entry_points_at_a_split_shard_file() {
    for m in CuratedModelCatalog.all {
      XCTAssertFalse(HFCacheCatalog.isSplitShardFilename(m.huggingFaceFile),
                     "curated entry \(m.id) points at a split GGUF shard the engine cannot assemble: \(m.huggingFaceFile)")
    }
  }

  /// #425 regression pin: Qwen2.5 7B Q4_K_M must come from bartowski's
  /// single-file repo, NOT the official `Qwen/Qwen2.5-7B-Instruct-GGUF`,
  /// which publishes that quant ONLY as `…-q4_k_m-00001-of-00002.gguf`
  /// shards (verified against the live HF repo). This fails the instant
  /// someone "corrects" the catalog back to the official repo and
  /// re-introduces a non-existent monolithic file.
  func test_qwen7b_entry_uses_single_file_repo_not_split_shard_repo() {
    let entry = CuratedModelCatalog.model(withID: "qwen2.5-7b-instruct-q4_k_m")
    XCTAssertNotNil(entry, "the 7B curated entry must exist")
    XCTAssertEqual(entry?.huggingFaceRepo, "bartowski/Qwen2.5-7B-Instruct-GGUF",
                   "7B must use the bartowski single-file repo, not the Qwen split-shard repo")
    XCTAssertEqual(entry?.huggingFaceFile, "Qwen2.5-7B-Instruct-Q4_K_M.gguf",
                   "7B must point at the monolithic Q4_K_M file")
    XCTAssertNotEqual(entry?.huggingFaceRepo, "Qwen/Qwen2.5-7B-Instruct-GGUF",
                      "the Qwen official repo ships this quant only as split shards — do not revert")
  }
}
