import Foundation

/// Hand-curated catalog of GGUF models surfaced in *Settings → Models →
/// Add Model → Curated* so first-run users have a one-click path
/// instead of needing to know HF repo coordinates. Each entry maps
/// 1:1 to a `ModelDownloader.start(repo:file:)` call.
///
/// Curation policy (Phase 3.8): two small chat-capable GGUF builds
/// per family the engine has been smoke-tested with. Entries are
/// data-only — adding/removing models is a pure source change and
/// requires no migration since the catalog is not persisted.
public struct CuratedModel: Equatable, Identifiable, Sendable {
  /// Stable identifier for SwiftUI list diffing. Mirrors the `model`
  /// field a Profile would carry once installed, so the same string
  /// flows through `ProfileSwapCoordinator` later.
  public let id: String
  public let displayName: String
  public let publisher: String
  public let parameterCountBillions: Double
  public let quantization: String
  public let approximateSizeBytes: Int64
  public let huggingFaceRepo: String
  public let huggingFaceFile: String
  public let summary: String

  public init(id: String,
              displayName: String,
              publisher: String,
              parameterCountBillions: Double,
              quantization: String,
              approximateSizeBytes: Int64,
              huggingFaceRepo: String,
              huggingFaceFile: String,
              summary: String) {
    self.id = id
    self.displayName = displayName
    self.publisher = publisher
    self.parameterCountBillions = parameterCountBillions
    self.quantization = quantization
    self.approximateSizeBytes = approximateSizeBytes
    self.huggingFaceRepo = huggingFaceRepo
    self.huggingFaceFile = huggingFaceFile
    self.summary = summary
  }
}

/// A single-file GGUF download derived from a profile's model SLUG —
/// the input to `ModelDownloadController.enqueue(repo:file:)`. Surfaced
/// in the no-model prompt and the failed(modelMissing) banner so a
/// fresh-install user downloads the model the active profile needs
/// without hand-entering Hugging Face coordinates.
public struct ModelDownloadTarget: Equatable, Sendable {
  public let repo: String
  public let file: String
  /// Friendly label for the download CTA. Curated entries carry a real
  /// product name; a non-curated slug falls back to the `.gguf` leaf.
  public let displayName: String
  /// Published blob size when known (curated catalog), else nil — we
  /// never guess a size for an arbitrary Hugging Face repo.
  public let approximateSizeBytes: Int64?

  public init(repo: String,
              file: String,
              displayName: String,
              approximateSizeBytes: Int64?) {
    self.repo = repo
    self.file = file
    self.displayName = displayName
    self.approximateSizeBytes = approximateSizeBytes
  }
}

public enum CuratedModelCatalog {
  /// Sorted ascending by approximate size so the table reads from
  /// "smallest, fastest first run" to "biggest, best quality" without
  /// callers needing to re-sort.
  public static let all: [CuratedModel] = baseEntries.sorted {
    $0.approximateSizeBytes < $1.approximateSizeBytes
  }

  /// Map a profile's stored model SLUG to a single-file GGUF download
  /// target, or nil when the slug is not a single downloadable GGUF.
  ///
  /// Resolution order:
  ///   1. Curated match — a slug equal to `<repo>/<file>` of a catalog
  ///      entry returns that entry, carrying its display name and
  ///      published size. The seeded default slug matches the
  ///      recommended starter here.
  ///   2. Non-curated 3-segment `<org>/<name>/<file>.gguf` slug splits
  ///      into `(repo: <org>/<name>, file: <file>.gguf)` with the leaf
  ///      as the display name and unknown size.
  ///
  /// Everything else returns nil: a 2-segment slug is a safetensors
  /// snapshot DIR (pie loads it as a directory — multi-file, which the
  /// single-file `ModelDownloader.start(repo:file:)` cannot fetch); a
  /// bare leaf carries no repo; a non-`.gguf` file is out of v1's
  /// auto-download scope. Callers fall back to Settings → Models.
  public static func downloadTarget(forModelSlug slug: String) -> ModelDownloadTarget? {
    let trimmed = slug.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if let curated = all.first(where: {
      "\($0.huggingFaceRepo)/\($0.huggingFaceFile)" == trimmed
    }) {
      return ModelDownloadTarget(
        repo: curated.huggingFaceRepo,
        file: curated.huggingFaceFile,
        displayName: curated.displayName,
        approximateSizeBytes: curated.approximateSizeBytes)
    }

    let segments = trimmed
      .split(separator: "/", omittingEmptySubsequences: true)
      .map(String.init)
    guard segments.count >= 3 else { return nil }
    let file = segments.dropFirst(2).joined(separator: "/")
    guard file.lowercased().hasSuffix(".gguf") else { return nil }
    return ModelDownloadTarget(
      repo: "\(segments[0])/\(segments[1])",
      file: file,
      displayName: file,
      approximateSizeBytes: nil)
  }

  /// `O(n)` lookup is fine — the catalog is ≤ 16 entries by design.
  public static func model(withID id: String) -> CuratedModel? {
    all.first { $0.id == id }
  }

  /// Id of the recommended starter model surfaced with a "Recommended"
  /// badge in *Settings → Models → Add Model → Curated*. :
  /// small, modern, engine-detectable. Its `<huggingFaceRepo>/<huggingFaceFile>`
  /// is exactly the slug `chat.toml` is seeded with
  /// (`ProfileStore.defaultChatModelID` =
  /// `Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf`), so downloading the
  /// recommended starter stages the very file the seeded profile's
  /// default resolves to. `CuratedModelCatalogTests` pins that
  /// resolution invariant.
  public static let recommendedModelID = "qwen3-0.6b-q8_0"

  private static let baseEntries: [CuratedModel] = [
    //  starter tier — small, modern, engine-detectable GGUF
    // builds verified against their Hugging Face repos. Sizes are the
    // exact published blob sizes so the table + ETA estimate are honest.
    CuratedModel(
      id: "qwen2.5-0.5b-instruct-q4_k_m",
      displayName: "Qwen2.5 0.5B Instruct",
      publisher: "Alibaba",
      parameterCountBillions: 0.5,
      quantization: "Q4_K_M",
      approximateSizeBytes: 491_400_032,
      huggingFaceRepo: "Qwen/Qwen2.5-0.5B-Instruct-GGUF",
      huggingFaceFile: "qwen2.5-0.5b-instruct-q4_k_m.gguf",
      summary: "Smallest curated model. Instant first-run smoke test."
    ),
    CuratedModel(
      id: "qwen3-0.6b-q8_0",
      displayName: "Qwen3 0.6B",
      publisher: "Alibaba",
      parameterCountBillions: 0.6,
      quantization: "Q8_0",
      approximateSizeBytes: 639_446_688,
      huggingFaceRepo: "Qwen/Qwen3-0.6B-GGUF",
      huggingFaceFile: "Qwen3-0.6B-Q8_0.gguf",
      summary: "Recommended starter — same model RatioThink seeds as the default chat profile."
    ),
    CuratedModel(
      id: "llama-3.2-1b-instruct-q4_k_m",
      displayName: "Llama 3.2 1B Instruct",
      publisher: "Meta",
      parameterCountBillions: 1.0,
      quantization: "Q4_K_M",
      approximateSizeBytes: 807_694_464,
      huggingFaceRepo: "bartowski/Llama-3.2-1B-Instruct-GGUF",
      huggingFaceFile: "Llama-3.2-1B-Instruct-Q4_K_M.gguf",
      summary: "Tiny Llama. Quick everyday chat at minimal VRAM."
    ),
    CuratedModel(
      id: "qwen2.5-1.5b-instruct-q4_k_m",
      displayName: "Qwen2.5 1.5B Instruct",
      publisher: "Alibaba",
      parameterCountBillions: 1.5,
      quantization: "Q4_K_M",
      approximateSizeBytes: 1_117_000_000,
      huggingFaceRepo: "Qwen/Qwen2.5-1.5B-Instruct-GGUF",
      huggingFaceFile: "qwen2.5-1.5b-instruct-q4_k_m.gguf",
      summary: "Compact Qwen for fast everyday chat."
    ),
    CuratedModel(
      id: "llama-3.2-3b-instruct-q4_k_m",
      displayName: "Llama 3.2 3B Instruct",
      publisher: "Meta",
      parameterCountBillions: 3.0,
      quantization: "Q4_K_M",
      approximateSizeBytes: 2_020_000_000,
      huggingFaceRepo: "bartowski/Llama-3.2-3B-Instruct-GGUF",
      huggingFaceFile: "Llama-3.2-3B-Instruct-Q4_K_M.gguf",
      summary: "Solid daily-driver chat at low VRAM."
    ),
    CuratedModel(
      id: "phi-3.5-mini-instruct-q4_k_m",
      displayName: "Phi-3.5 Mini Instruct",
      publisher: "Microsoft",
      parameterCountBillions: 3.8,
      quantization: "Q4_K_M",
      approximateSizeBytes: 2_390_000_000,
      huggingFaceRepo: "bartowski/Phi-3.5-mini-instruct-GGUF",
      huggingFaceFile: "Phi-3.5-mini-instruct-Q4_K_M.gguf",
      summary: "Reasoning-leaning Phi family build."
    ),
    CuratedModel(
      id: "qwen2.5-7b-instruct-q4_k_m",
      displayName: "Qwen2.5 7B Instruct",
      publisher: "Alibaba",
      parameterCountBillions: 7.0,
      quantization: "Q4_K_M",
      approximateSizeBytes: 4_680_000_000,
      huggingFaceRepo: "Qwen/Qwen2.5-7B-Instruct-GGUF",
      huggingFaceFile: "qwen2.5-7b-instruct-q4_k_m.gguf",
      summary: "Bigger Qwen with broader general capability."
    ),
    CuratedModel(
      id: "llama-3.1-8b-instruct-q4_k_m",
      displayName: "Llama 3.1 8B Instruct",
      publisher: "Meta",
      parameterCountBillions: 8.0,
      quantization: "Q4_K_M",
      approximateSizeBytes: 4_920_000_000,
      huggingFaceRepo: "bartowski/Meta-Llama-3.1-8B-Instruct-GGUF",
      huggingFaceFile: "Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf",
      summary: "Llama 3.1 mid-size; long-form quality bump over 3B."
    ),
  ]
}
