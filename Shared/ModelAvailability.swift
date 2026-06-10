import Foundation

/// Local-availability classifier for Add Model candidates (#514).
///
/// The Add Model sheet offers curated and Hugging Face rows that may
/// already exist locally; before this, every row always showed "Add"
/// and the only duplicate guard was `ModelDownloader`'s overwrite
/// semantics. This type classifies a candidate `(repo, file)` BEFORE
/// any enqueue, from the same identities the rest of the app uses:
///
///  - app-managed installs: `InstalledModel.filename` — the path
///    relative to the models root, i.e. the `<repo>/<file>` slug for a
///    nested curated download. This is exactly what a profile stores
///    and what the resolver joins, so equality here is the same
///    equality the engine uses.
///  - HF-cache models: `InstalledModel.filename` from
///    `HFCacheCatalog.scan` — `<org>/<name>/<file>.gguf` for GGUF rows
///    (and the 2-segment dir slug for safetensors repos, which can
///    never equal a 3-segment download candidate — by design those
///    rows stay downloadable as single GGUFs).
///  - in-flight downloads: `(repo, file)` pairs from
///    `ModelDownloadController.active` (non-terminal entries only —
///    a lingering completed/failed row is not "downloading").
///
/// Comparison is by canonical slug only — never display names, leaf
/// basenames, sizes, or catalog ids, all of which can collide or omit
/// the repo identity.
public struct ModelAvailability: Equatable, Sendable {

  /// How a candidate `(repo, file)` relates to what's already local.
  public enum Status: Equatable, Sendable {
    /// Not present anywhere we can see — Add is a real action.
    case availableToDownload
    /// A non-terminal download for the same repo/file is in flight.
    case downloading
    /// Present in the app-managed models directory.
    case installedAppManaged
    /// Discoverable in the shared Hugging Face cache. The app does
    /// not own that directory, so this is "already available", not
    /// "installed" — but a fresh download would still be redundant.
    case availableInHFCache

    /// `true` only when Add should actually enqueue a download.
    public var allowsAdd: Bool { self == .availableToDownload }

    /// Row badge for non-addable states; `nil` when Add is shown.
    public var badgeText: String? {
      switch self {
      case .availableToDownload: return nil
      case .downloading:         return "Downloading…"
      case .installedAppManaged: return "Installed"
      case .availableInHFCache:  return "In library"
      }
    }

    /// User-facing reason a duplicate enqueue was refused — the
    /// pre-enqueue guard's `actionError` copy. `nil` when addable.
    public func blockedReason(slug: String) -> String? {
      switch self {
      case .availableToDownload:
        return nil
      case .downloading:
        return "'\(slug)' is already downloading."
      case .installedAppManaged:
        return "'\(slug)' is already installed."
      case .availableInHFCache:
        return "'\(slug)' is already available from the Hugging Face cache."
      }
    }
  }

  private let appManagedSlugs: Set<String>
  private let hfCacheSlugs: Set<String>
  private let downloadingSlugs: Set<String>

  /// Canonical identity of a download candidate: the same
  /// `<repo>/<file>` string `InstalledModels.scan` emits for the
  /// nested file `ModelDownloader` places at
  /// `<modelsRoot>/<repo>/<file>`.
  public static func slug(repo: String, file: String) -> String {
    "\(repo)/\(file)"
  }

  public init(installed: [InstalledModel] = [],
              inFlight: [(repo: String, file: String)] = []) {
    var app = Set<String>()
    var hf = Set<String>()
    for row in installed {
      // A partial (interrupted) download is NOT an install: marking it
      // "Installed" would render a healthy badge over broken bytes AND
      // block the re-download that repairs it (review v1 F1). Skipped
      // rows stay `availableToDownload`, and `ModelDownloader.start`'s
      // stale-resume cleanup handles the leftover `.partial` sibling.
      //
      // `metadataUnreadable` rows DO count: only the size/date read
      // failed — the file itself is present, so a fresh download would
      // still be redundant. `isUnverified` likewise counts (the bytes
      // are complete; integrity badging is the Models table's job).
      if row.isPartial { continue }
      switch row.source {
      case .appManaged:       app.insert(row.filename)
      case .huggingFaceCache: hf.insert(row.filename)
      }
    }
    appManagedSlugs = app
    hfCacheSlugs = hf
    downloadingSlugs = Set(inFlight.map { Self.slug(repo: $0.repo, file: $0.file) })
  }

  /// Classify a candidate. Precedence: `downloading` first (it is the
  /// live activity, and an in-flight redundant download over an
  /// installed file should read as what it IS), then app-managed,
  /// then HF cache.
  public func status(repo: String, file: String) -> Status {
    let slug = Self.slug(repo: repo, file: file)
    if downloadingSlugs.contains(slug) { return .downloading }
    if appManagedSlugs.contains(slug) { return .installedAppManaged }
    if hfCacheSlugs.contains(slug) { return .availableInHFCache }
    return .availableToDownload
  }
}
