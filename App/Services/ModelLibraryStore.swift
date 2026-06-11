import Foundation
import Combine

/// `@MainActor ObservableObject` owner of the local model library —
/// the ONE live source of truth for "what models exist locally" that
/// the Models settings table, the Add Model sheet, and the duplicate
/// guard all read (#514 rescope).
///
/// Before this store, `ModelsSettingsTab` held the scan results in
/// scattered `@State` (`installed` / `modelsDirectory` / `scanError`)
/// refreshed via `completionTick` plumbing, and the Add sheet got a
/// copied `installed` array. That left two structural staleness
/// windows the store closes:
///
///  1. **Pre-first-scan**: consumers could not distinguish "no models"
///     from "not scanned yet". `freshness` makes that explicit.
///  2. **Post-completion flicker**: a terminal download leaves
///     `downloads.active` (linger eviction) before the async rescan
///     surfaces the placed file, so availability briefly flipped back
///     to Add. The store reconciles completions SYNCHRONOUSLY: the
///     moment a download reaches `.completed`, its slug joins a
///     pending-installed overlay that classifies as installed until a
///     fresh scan confirms it — no window, by construction.
///
/// Publishing discipline (#327's lesson): `availability` is
/// `Equatable` and assigned only on real change, so per-tick download
/// progress (bytes) never re-renders availability consumers. The
/// in-flight axis itself is derived inside `availability` rather than
/// republished separately.
@MainActor
final class ModelLibraryStore: ObservableObject {

  /// Explicit first-scan state so "empty library" is never conflated
  /// with "haven't looked yet". Re-scans after the first stay
  /// `.scanned` — the previous truth remains rendered, no flicker to
  /// a loading state.
  enum Freshness: Equatable {
    case notScanned
    case scanning
    case scanned
  }

  @Published private(set) var freshness: Freshness = .notScanned
  /// Table-facing rows: app-managed + HF-cache, deduped by slug
  /// keeping the app-managed row (the resolver's app-staged-first
  /// precedence — migrated from `ModelsSettingsTab.refresh()`).
  @Published private(set) var installed: [InstalledModel] = []
  /// App models directory when it was prepared — the Add sheet's
  /// local-file import and the duplicate guard's backstop need it.
  @Published private(set) var modelsDirectory: URL?
  /// Non-nil when the app-dir scan failed; HF rows stay valid.
  @Published private(set) var scanError: String?
  /// Live classification input for the Add sheet + duplicate guard:
  /// installed rows (incl. the completion overlay) + the non-terminal
  /// download set. Change-guarded — see the publishing note above.
  @Published private(set) var availability = ModelAvailability()

  private let downloads: ModelDownloadController
  private let scan: @Sendable () async -> CachedModelScan.Result
  /// Slugs whose download completed but whose placed file a finished
  /// scan has not yet confirmed. Feeds `availability` as synthesized
  /// app-managed rows; retired when a scan reports the slug.
  private var pendingInstalledSlugs: Set<String> = []
  /// Download ids whose `.completed` transition was already
  /// reconciled, so per-tick re-emissions don't re-trigger rescans.
  private var reconciledCompletions: Set<UUID> = []
  /// Monotonic guard: only the newest in-flight `refresh()` applies
  /// its result (two overlapping scans must not land out of order).
  private var scanEpoch: UInt64 = 0
  private var downloadsSubscription: AnyCancellable?

  init(downloads: ModelDownloadController,
       scan: @escaping @Sendable () async -> CachedModelScan.Result = CachedModelScan.run) {
    self.downloads = downloads
    self.scan = scan
    downloadsSubscription = downloads.$active.sink { [weak self] active in
      self?.reconcile(active: active)
    }
  }

  /// Re-walk the filesystem and republish. Callers: Models tab appear,
  /// delete, drop import, sheet outcome — and the store itself on
  /// every download completion.
  func refresh() async {
    scanEpoch &+= 1
    let epoch = scanEpoch
    if freshness == .notScanned { freshness = .scanning }
    let result = await scan()
    guard epoch == scanEpoch else { return }
    modelsDirectory = result.modelsDirectory
    scanError = result.appError
    let appSlugs = Set(result.appManaged.map(\.filename))
    installed = result.appManaged
      + result.huggingFaceCache.filter { !appSlugs.contains($0.filename) }
    retireOverlay(active: downloads.active)
    // GC: a download id can never re-enter `active`, so ids whose rows
    // have evicted are dead weight in the reconciled set.
    reconciledCompletions.formIntersection(Set(downloads.active.keys))
    freshness = .scanned
    recomputeAvailability(active: downloads.active)
  }

  /// Overlay retirement — runs on EVERY state edge that can change the
  /// answer (each applied scan in `refresh()`, and each `$active`
  /// emission in `reconcile(active:)`, which covers the eviction edge
  /// review v4 F1 found missing). A pending slug is kept only while
  /// BOTH hold:
  ///  - no finished scan has confirmed it (once `installed` — app-
  ///    managed OR HF-cache — reports the slug, the list owns the
  ///    classification and the overlay is redundant), and
  ///  - its download row still lingers in `active`: a scan whose
  ///    filesystem walk raced the placement can innocently miss a
  ///    just-completed file (the completion-triggered re-scan confirms
  ///    it moments later), but once the row has evicted, a missing
  ///    file means the install genuinely is not there (e.g. externally
  ///    deleted) — the overlay must not keep claiming it is, or the
  ///    phantom "Installed" would block the repairing re-download.
  private func retireOverlay(active: [UUID: ModelDownloadController.ActiveDownload]) {
    guard !pendingInstalledSlugs.isEmpty else { return }
    let installedSlugs = Set(installed.map(\.filename))
    let lingering = Set(active.values.map {
      ModelAvailability.slug(repo: $0.repo, file: $0.file)
    })
    pendingInstalledSlugs = pendingInstalledSlugs.filter {
      !installedSlugs.contains($0) && lingering.contains($0)
    }
  }

  /// Sink over `downloads.$active`. Two jobs: flip the in-flight axis
  /// (via `recomputeAvailability`'s change guard), and reconcile
  /// terminal completions into the pending-installed overlay before
  /// the row can evict.
  private func reconcile(active: [UUID: ModelDownloadController.ActiveDownload]) {
    for entry in active.values
    where entry.progress.phase == .completed && !reconciledCompletions.contains(entry.id) {
      reconciledCompletions.insert(entry.id)
      // Placement happens before the producer emits `.completed`
      // (`ModelDownloader.completeDownload`), so the file is on disk
      // RIGHT NOW — classifying it installed is honest, not hopeful.
      pendingInstalledSlugs.insert(
        ModelAvailability.slug(repo: entry.repo, file: entry.file))
      Task { await refresh() }
    }
    // Eviction edge (review v4 F1): a terminal row leaving `active` is
    // an emission with NO completion transition — retirement must run
    // here too, or a scan-race-missed slug would keep classifying
    // installed until some unrelated refresh().
    retireOverlay(active: active)
    recomputeAvailability(active: active)
  }

  /// `active` is passed explicitly because `@Published` sinks fire on
  /// `willSet` — reading `downloads.active` from inside the sink would
  /// observe the PRE-mutation dictionary and lag availability one
  /// event behind (the enqueue→"Downloading…" flip would wait for the
  /// next unrelated emission).
  private func recomputeAvailability(active: [UUID: ModelDownloadController.ActiveDownload]) {
    // Synthesize overlay rows for slugs a finished scan hasn't
    // confirmed yet. Only `filename`/`source` participate in
    // classification; the rest are renderable placeholders (the
    // overlay never reaches the table).
    let overlay = pendingInstalledSlugs.map { slug in
      InstalledModel(
        filename: slug,
        url: (modelsDirectory ?? URL(fileURLWithPath: "/")).appendingPathComponent(slug),
        sizeBytes: 0,
        modifiedAt: Date(timeIntervalSince1970: 0),
        isPartial: false)
    }
    let next = ModelAvailability(
      installed: installed + overlay,
      inFlight: active.values
        .filter { !$0.isTerminal }
        .map { (repo: $0.repo, file: $0.file) })
    if availability != next { availability = next }
  }
}
