import Foundation
import XCTest
@testable import RatioThinkCore

/// LIVE integration test against the real Hugging Face tree API — the
/// audit that the offline `CuratedModelCatalogTests` shape guards can't
/// perform: it proves every curated `(repo, file)` actually EXISTS on HF
/// as a single regular `.gguf` blob, not a phantom monolithic name a repo
/// only publishes as split shards (the #425 bug — `Qwen/Qwen2.5-7B-
/// Instruct-GGUF/qwen2.5-7b-instruct-q4_k_m.gguf` does not exist; that
/// quant ships only as `…-00001-of-00002.gguf`).
///
/// OFF by default so CI stays network-free; opt in with
/// `PIE_TEST_REAL_HF=1` (mirrors the project's real-e2e env gating, e.g.
/// `PIE_TEST_REAL_GITHUB`). Reuses the production `HuggingFaceSearchClient`
/// so any drift in the HF tree decode is exercised by the same code the
/// in-app model search uses. One request per curated repo.
final class CuratedModelCatalogLiveHFTests: XCTestCase {
  /// Declared vs real published size may differ by rounding in the
  /// catalog (some entries carry a rounded `approximateSizeBytes`); a
  /// 5% band tolerates that while still catching a size copied from the
  /// wrong quant.
  private static let sizeTolerance = 0.05

  func test_everyCuratedEntryExistsAsASingleGGUFFileOnHuggingFace() async throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["PIE_TEST_REAL_HF"] == "1",
      "Live Hugging Face curated-catalog audit is opt-in (one real network "
      + "call per curated repo). Set PIE_TEST_REAL_HF=1 to run."
    )

    let client = HuggingFaceSearchClient()

    for m in CuratedModelCatalog.all {
      let files: [HFRepoFile]
      do {
        files = try await client.listFiles(in: m.huggingFaceRepo)
      } catch {
        XCTFail("\(m.id): listing \(m.huggingFaceRepo) failed: \(error)")
        continue
      }

      let match = files.first { $0.path == m.huggingFaceFile }
      if match == nil {
        // Surface WHY it's missing: a split-shard-only quant is the #425
        // failure shape, so name the shards we did find for the same base.
        let base = String(m.huggingFaceFile.dropLast(".gguf".count))
        let shards = files
          .map(\.path)
          .filter { HFCacheCatalog.isSplitShardFilename($0) && $0.hasPrefix(base) }
          .sorted()
        let hint = shards.isEmpty
          ? "no .gguf with that exact name is published"
          : "published ONLY as split shards: \(shards.joined(separator: ", "))"
        XCTFail("\(m.id): \(m.huggingFaceRepo)/\(m.huggingFaceFile) does not exist — \(hint)")
        continue
      }

      // It exists as a single regular `.gguf` file (decodeTree filters to
      // `type == "file"`). Cross-check the declared size is honest.
      if let real = match?.sizeBytes, real > 0 {
        let declared = Double(m.approximateSizeBytes)
        let delta = abs(declared - Double(real)) / Double(real)
        XCTAssertLessThanOrEqual(
          delta, Self.sizeTolerance,
          "\(m.id): declared \(m.approximateSizeBytes) B is \(Int(delta * 100))% off the "
          + "published \(real) B for \(m.huggingFaceFile)")
        print("LIVE-HF: \(m.id) OK — \(m.huggingFaceRepo)/\(m.huggingFaceFile) "
              + "declared=\(m.approximateSizeBytes) real=\(real)")
      } else {
        // Exists, but HF published no/zero size for the blob. A curated
        // `.gguf` HF reports with no positive size is itself suspicious
        // (odd/truncated repo metadata), and the declared size then goes
        // unverified — so the gated live audit must FAIL here rather than
        // print-and-continue and green on a missing size (#428 / PR #41 F2).
        let published = match?.sizeBytes.map(String.init) ?? "nil"
        XCTFail(
          "\(m.id): \(m.huggingFaceRepo)/\(m.huggingFaceFile) exists but HF "
          + "reports no positive size (size=\(published)) — suspicious repo "
          + "metadata; declared \(m.approximateSizeBytes) B unverifiable")
      }
    }
  }
}
