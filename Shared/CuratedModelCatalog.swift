import Foundation

/// Operator posture for a curated model. The value is UI-facing metadata:
/// it does not change the downloader mechanics, but it makes clear which
/// model is the seeded/recommended starter vs heavyweight models that
/// should be downloaded and real-E2E'd only by an explicit local action.
public enum CuratedModelInstallIntent: String, Equatable, Sendable {
  case defaultRecommended
  case curated
  case manualOnly

  public var badgeText: String? {
    switch self {
    case .defaultRecommended:
      return "Recommended"
    case .curated:
      return nil
    case .manualOnly:
      return "Manual"
    }
  }
}

/// Hand-curated catalog of GGUF models surfaced in *Settings → Models →
/// Add Model → Curated* so first-run users have a one-click path
/// instead of needing to know HF repo coordinates. Each entry maps
/// 1:1 to a `ModelDownloader.start(repo:file:)` call.
///
/// Curation policy (Phase 3.8): two small chat-capable GGUF builds
/// per family the engine has been smoke-tested with. Entries are
/// data-only — adding/removing models is a pure source change and
/// requires no migration since the catalog is not persisted.
///
/// Source convention: any future file that contributes entries to
/// `CuratedModelCatalog.all` must live under
/// `Shared/Curated*Catalog*.swift` so the PR-time live-HF audit in
/// `.github/workflows/curated-catalog-audit.yml` still runs when a PR
/// changes only that split source.
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
  /// Recommended total system RAM for a comfortable launch, when the
  /// model is large enough that the artifact size alone understates the
  /// operator impact. `nil` for starter/small rows where the catalog size
  /// is sufficient guidance.
  public let recommendedSystemMemoryBytes: Int64?
  /// Notes about Pie support constraints: e.g. single-file GGUF, known
  /// architecture family, or manual/local E2E posture. Empty only for
  /// legacy small curated rows where no extra constraint is needed.
  public let pieSupportNotes: String
  public let installIntent: CuratedModelInstallIntent

  public init(id: String,
              displayName: String,
              publisher: String,
              parameterCountBillions: Double,
              quantization: String,
              approximateSizeBytes: Int64,
              huggingFaceRepo: String,
              huggingFaceFile: String,
              summary: String,
              recommendedSystemMemoryBytes: Int64? = nil,
              pieSupportNotes: String = "",
              installIntent: CuratedModelInstallIntent = .curated) {
    self.id = id
    self.displayName = displayName
    self.publisher = publisher
    self.parameterCountBillions = parameterCountBillions
    self.quantization = quantization
    self.approximateSizeBytes = approximateSizeBytes
    self.huggingFaceRepo = huggingFaceRepo
    self.huggingFaceFile = huggingFaceFile
    self.summary = summary
    self.recommendedSystemMemoryBytes = recommendedSystemMemoryBytes
    self.pieSupportNotes = pieSupportNotes
    self.installIntent = installIntent
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

  /// True when `slug` is one of the engine-validated, curated GGUF
  /// artifacts RatioThink offers through Add Model. HF-cache discovery can
  /// surface arbitrary local repos; callers use this predicate to distinguish
  /// "known supported" cache hits from "discovered but unverified" ones
  /// without blocking the latter.
  public static func isCuratedModelSlug(_ slug: String) -> Bool {
    all.contains { "\($0.huggingFaceRepo)/\($0.huggingFaceFile)" == slug }
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

  /// Representative heavyweight entry for the explicit/manual real-engine
  /// E2E wrapper. This must stay a curated, live-HF-verified, single-file
  /// GGUF model but must NOT become the seeded default or PR-CI path.
  public static let largeE2ERepresentativeModelID = "qwen3-14b-q4_k_m"

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
      summary: "Recommended starter — same model Rational seeds as the default chat profile.",
      installIntent: .defaultRecommended
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
    // NB: no Phi here. Phi-3/Phi-3.5 GGUFs fuse Q/K/V into one `qkv_proj`
    // tensor and Phi-2 declares arch `phi2`; the pie portable Metal loader
    // supports neither (it expects separate q/k/v in a Llama/Qwen layout), so
    // every Phi variant aborts at model load. Removed from the curated set
    // rather than shipped as a launch-failing entry. Engine-side fused-QKV
    // support is tracked upstream in pie-project/pie #402.
    // Qwen2.5 7B Q4_K_M comes from bartowski's repo, NOT the official
    // `Qwen/Qwen2.5-7B-Instruct-GGUF` — Qwen publishes this quant ONLY as
    // split shards (`…-q4_k_m-00001-of-00002.gguf` + `-00002-…`), which
    // pie cannot assemble (it loads a single .gguf via `gguf_init_from_file`).
    // bartowski ships a verified monolithic `Q4_K_M` file. Do not "fix" this
    // back to the official repo — `CuratedModelCatalogTests` fails if you do.
    CuratedModel(
      id: "qwen2.5-7b-instruct-q4_k_m",
      displayName: "Qwen2.5 7B Instruct",
      publisher: "Alibaba",
      parameterCountBillions: 7.0,
      quantization: "Q4_K_M",
      approximateSizeBytes: 4_683_074_240,
      huggingFaceRepo: "bartowski/Qwen2.5-7B-Instruct-GGUF",
      huggingFaceFile: "Qwen2.5-7B-Instruct-Q4_K_M.gguf",
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
    // Large/manual tier. Coordinates and exact blob sizes were
    // verified against the live Hugging Face tree API on 2026-06-07.
    // Keep them single-file GGUFs so ModelDownloader and pie's one-file
    // loader can consume them; do not move these into default seeding or
    // PR CI because each download is ~9 GB and real inference is operator-
    // gated. The manual real-engine wrapper documents/proves the path:
    //   make test-e2e-large-model
    CuratedModel(
      id: "qwen2.5-coder-14b-instruct-q4_k_m",
      displayName: "Qwen2.5 Coder 14B Instruct",
      publisher: "Alibaba",
      parameterCountBillions: 14.7,
      quantization: "Q4_K_M",
      approximateSizeBytes: 8_988_111_072,
      huggingFaceRepo: "bartowski/Qwen2.5-Coder-14B-Instruct-GGUF",
      huggingFaceFile: "Qwen2.5-Coder-14B-Instruct-Q4_K_M.gguf",
      summary: "Large coding-focused Qwen for explicit local use on roomy Macs.",
      recommendedSystemMemoryBytes: 32 * 1024 * 1024 * 1024,
      pieSupportNotes: "Single-file Qwen2 GGUF; manual/local real-engine E2E only, not PR CI.",
      installIntent: .manualOnly
    ),
    CuratedModel(
      id: "qwen3-14b-q4_k_m",
      displayName: "Qwen3 14B",
      publisher: "Alibaba",
      parameterCountBillions: 14.0,
      quantization: "Q4_K_M",
      approximateSizeBytes: 9_001_752_960,
      huggingFaceRepo: "Qwen/Qwen3-14B-GGUF",
      huggingFaceFile: "Qwen3-14B-Q4_K_M.gguf",
      summary: "Large Qwen thinking model for explicit local quality checks.",
      recommendedSystemMemoryBytes: 32 * 1024 * 1024 * 1024,
      pieSupportNotes: "Single-file Qwen3 GGUF; thinking-model behavior may use reasoning_content; manual/local real-engine E2E only.",
      installIntent: .manualOnly
    ),
    // Qwen3.6 family — the hybrid gated-delta-rule + GQA arch the portable
    // Metal engine runs as PieArch::Qwen3_5. Both builds declare a
    // general.architecture (qwen35 / qwen35moe) that the engine maps to
    // Qwen3_5, and both were real-loaded through the portable driver
    // (boot + a chat completion) before pinning. unsloth ships verified
    // MONOLITHIC single-file quants; only each repo's BF16 build is split
    // into shards pie cannot assemble. Manual/local posture (~16-21 GiB).
    CuratedModel(
      id: "qwen3.6-27b-q4_k_m",
      displayName: "Qwen3.6 27B",
      publisher: "Alibaba",
      parameterCountBillions: 27.0,
      quantization: "Q4_K_M",
      approximateSizeBytes: 16_817_244_384,
      huggingFaceRepo: "unsloth/Qwen3.6-27B-GGUF",
      huggingFaceFile: "Qwen3.6-27B-Q4_K_M.gguf",
      summary: "Hybrid-attention Qwen3.6 dense for top-quality chat on roomy Macs.",
      recommendedSystemMemoryBytes: 32 * 1024 * 1024 * 1024,
      pieSupportNotes: "Single-file Qwen3.6 GGUF (general.architecture=qwen35 → PieArch::Qwen3_5); manual/local real-engine E2E only.",
      installIntent: .manualOnly
    ),
    CuratedModel(
      id: "qwen3.6-35b-a3b-ud-q4_k_m",
      displayName: "Qwen3.6 35B-A3B (MoE)",
      publisher: "Alibaba",
      parameterCountBillions: 35.0,
      quantization: "UD-Q4_K_M",
      approximateSizeBytes: 22_134_528_992,
      huggingFaceRepo: "unsloth/Qwen3.6-35B-A3B-GGUF",
      huggingFaceFile: "Qwen3.6-35B-A3B-UD-Q4_K_M.gguf",
      summary: "Largest curated model. Sparse MoE (~3B active) — snappy, high-quality chat on 48 GB+ Macs.",
      recommendedSystemMemoryBytes: 48 * 1024 * 1024 * 1024,
      pieSupportNotes: "Single-file Qwen3.6 MoE GGUF (general.architecture=qwen35moe → PieArch::Qwen3_5; routed + shared experts); manual/local real-engine E2E only.",
      installIntent: .manualOnly
    ),
  ]
}
