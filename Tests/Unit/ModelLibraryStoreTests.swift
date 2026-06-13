import XCTest
import Combine
@testable import RatioThink

/// #514 rescope — `ModelLibraryStore` is the one live source of truth
/// for local model availability. These tests pin its three structural
/// guarantees:
///  - explicit first-scan freshness ("no models" ≠ "not scanned yet"),
///  - scanError propagation without losing HF rows,
///  - completion reconciliation: from the instant a download reaches
///    `.completed`, availability classifies the slug installed with NO
///    window in which it flips back to Add — even while the rescan has
///    not yet confirmed the placed file.
@MainActor
final class ModelLibraryStoreTests: XCTestCase {

  private let repo = "Qwen/Qwen3-0.6B-GGUF"
  private let file = "Qwen3-0.6B-Q8_0.gguf"
  private var slug: String { "\(repo)/\(file)" }

  // MARK: - fixtures

  private func row(_ filename: String,
                   source: CachedModelSource = .appManaged) -> InstalledModel {
    InstalledModel(filename: filename,
                   url: URL(fileURLWithPath: "/tmp/\(filename)"),
                   sizeBytes: 1,
                   modifiedAt: Date(timeIntervalSince1970: 0),
                   isPartial: false,
                   source: source)
  }

  private func emptyScan() -> CachedModelScan.Result {
    CachedModelScan.Result(modelsDirectory: URL(fileURLWithPath: "/tmp/models"),
                           appManaged: [], appError: nil, huggingFaceCache: [])
  }

  /// Mutable canned-scan slot the store's injected closure reads —
  /// lets a test change "what the filesystem says" mid-scenario.
  private final class ScanBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: CachedModelScan.Result
    init(_ initial: CachedModelScan.Result) { stored = initial }
    var result: CachedModelScan.Result {
      get { lock.lock(); defer { lock.unlock() }; return stored }
      set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
  }

  /// `ModelDownloading` stub: hands out handles and a caller-driven
  /// progress stream so a test can emit `.completed` on demand.
  private final class StubDownloader: ModelDownloading, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<DownloadProgress>.Continuation] = [:]

    func start(repo: String, file: String) -> Result<DownloadHandle, DownloadError> {
      .success(DownloadHandle(id: UUID(), repo: repo, file: file))
    }
    func cancel(handle: DownloadHandle) -> DownloadError? { nil }
    func progress(for handle: DownloadHandle) -> AsyncStream<DownloadProgress> {
      AsyncStream { continuation in
        lock.lock(); continuations[handle.id] = continuation; lock.unlock()
      }
    }
    func emit(_ progress: DownloadProgress, for id: UUID) {
      lock.lock(); let c = continuations[id]; lock.unlock()
      c?.yield(progress)
    }
    func finish(_ id: UUID) {
      lock.lock(); let c = continuations[id]; lock.unlock()
      c?.finish()
    }
  }

  private func waitUntil(timeout: TimeInterval = 5,
                         _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
  }

  // MARK: - freshness

  func test_first_scan_freshness_and_dedupe() async {
    let box = ScanBox(CachedModelScan.Result(
      modelsDirectory: URL(fileURLWithPath: "/tmp/models"),
      appManaged: [row(slug)],
      appError: nil,
      huggingFaceCache: [row(slug, source: .huggingFaceCache),
                         row("acme/other", source: .huggingFaceCache)]))
    let store = ModelLibraryStore(downloads: ModelDownloadController(),
                                  scan: { box.result })

    XCTAssertEqual(store.freshness, .notScanned,
                   "before any scan, consumers must be able to tell 'not "
                   + "scanned yet' from 'no models'")
    await store.refresh()
    XCTAssertEqual(store.freshness, .scanned)
    XCTAssertEqual(store.modelsDirectory?.path, "/tmp/models")
    // Dedupe keeps the app-managed row (migrated from the old
    // ModelsSettingsTab.refresh()).
    XCTAssertEqual(store.installed.map(\.filename), [slug, "acme/other"])
    XCTAssertEqual(store.installed.first?.source, .appManaged)
    XCTAssertEqual(store.availability.status(repo: repo, file: file),
                   .installedAppManaged)
  }

  func test_scan_error_propagates_and_keeps_hf_rows() async {
    let box = ScanBox(CachedModelScan.Result(
      modelsDirectory: nil,
      appManaged: [],
      appError: "Could not prepare the models directory: boom",
      huggingFaceCache: [row(slug, source: .huggingFaceCache)]))
    let store = ModelLibraryStore(downloads: ModelDownloadController(),
                                  scan: { box.result })

    await store.refresh()
    XCTAssertEqual(store.freshness, .scanned)
    XCTAssertNotNil(store.scanError)
    XCTAssertEqual(store.installed.map(\.filename), [slug],
                   "an app-dir failure must not hide HF-cache rows")
    XCTAssertEqual(store.availability.status(repo: repo, file: file),
                   .availableInHFCache)
  }

  // MARK: - completion reconciliation (the flicker window)

  func test_completion_reconciliation_closes_flicker_window() async throws {
    let stub = StubDownloader()
    // Long linger so eviction never races this test; the window under
    // test is availability, which excludes terminal rows regardless.
    let downloads = ModelDownloadController(downloader: stub,
                                            terminalRowLingerSeconds: 600)
    // The injected scan keeps reporting an EMPTY library — the rescan
    // the completion triggers cannot be what keeps the slug installed.
    let box = ScanBox(emptyScan())
    let store = ModelLibraryStore(downloads: downloads, scan: { box.result })
    await store.refresh()

    let id = try XCTUnwrap(downloads.enqueue(repo: repo, file: file))
    let sawDownloading = await waitUntil {
      store.availability.status(repo: self.repo, file: self.file) == .downloading
    }
    XCTAssertTrue(sawDownloading, "enqueued download must classify as downloading")

    stub.emit(DownloadProgress(handleID: id, phase: .completed,
                               bytesReceived: 1, bytesExpected: 1,
                               etaSeconds: nil), for: id)
    stub.finish(id)

    // From the moment `.completed` lands, the slug must classify
    // installed — the terminal row no longer counts as downloading,
    // and the (still-empty) scan can't vouch for it: only the store's
    // completion overlay closes this window.
    let sawInstalled = await waitUntil {
      store.availability.status(repo: self.repo, file: self.file) == .installedAppManaged
    }
    XCTAssertTrue(sawInstalled,
                  "completed download must classify installed immediately, with no "
                  + "flip back to availableToDownload while the rescan lags; got "
                  + "\(store.availability.status(repo: repo, file: file))")

    // And it must STAY installed across further empty-scan refreshes
    // while the download row lingers (scan walk could have raced the
    // placement).
    await store.refresh()
    XCTAssertEqual(store.availability.status(repo: repo, file: file),
                   .installedAppManaged)
  }

  func test_overlay_retires_on_eviction_when_scan_never_confirms() async throws {
    // Review v4 F1/F2 — the eviction edge. The scan NEVER reports the
    // file (models an externally deleted install, or a scan walk that
    // raced placement and was never re-run): while the terminal row
    // lingers the overlay honestly classifies installed, but the
    // moment the row evicts, the phantom must retire so the repairing
    // re-download is not blocked.
    let stub = StubDownloader()
    let downloads = ModelDownloadController(downloader: stub,
                                            terminalRowLingerSeconds: 1)
    let box = ScanBox(emptyScan())
    let store = ModelLibraryStore(downloads: downloads, scan: { box.result })
    await store.refresh()

    let id = try XCTUnwrap(downloads.enqueue(repo: repo, file: file))
    stub.emit(DownloadProgress(handleID: id, phase: .completed,
                               bytesReceived: 1, bytesExpected: 1,
                               etaSeconds: nil), for: id)
    stub.finish(id)

    // Linger window: overlay claims installed (positive control for
    // the assertion below — proves retirement is what flips it back).
    let sawInstalled = await waitUntil {
      store.availability.status(repo: self.repo, file: self.file) == .installedAppManaged
    }
    XCTAssertTrue(sawInstalled, "overlay must classify installed while the row lingers")

    // Eviction (linger 1s): the row leaves `active`, retirement runs
    // on that emission, and — with no scan ever confirming the file —
    // the slug must return to addable, with nothing else triggering a
    // refresh.
    let retired = await waitUntil(timeout: 10) {
      store.availability.status(repo: self.repo, file: self.file) == .availableToDownload
    }
    XCTAssertTrue(retired,
                  "an unconfirmed overlay slug must retire when its download row "
                  + "evicts — a phantom Installed would block the repairing "
                  + "re-download (review v4 F1)")
    XCTAssertEqual(
      ModelsSettingsTab.duplicateAddDecision(
        repo: repo, file: file,
        availability: store.availability,
        modelsDirectory: nil,
        fallbackModelsDirectory: { nil }),
      .proceed,
      "after retirement the duplicate guard must allow the re-download")
  }

  func test_overlay_retires_to_scan_truth_once_confirmed() async throws {
    let stub = StubDownloader()
    let downloads = ModelDownloadController(downloader: stub,
                                            terminalRowLingerSeconds: 600)
    let box = ScanBox(emptyScan())
    let store = ModelLibraryStore(downloads: downloads, scan: { box.result })
    await store.refresh()

    let id = try XCTUnwrap(downloads.enqueue(repo: repo, file: file))
    stub.emit(DownloadProgress(handleID: id, phase: .completed,
                               bytesReceived: 1, bytesExpected: 1,
                               etaSeconds: nil), for: id)
    stub.finish(id)
    let sawInstalled = await waitUntil {
      store.availability.status(repo: self.repo, file: self.file) == .installedAppManaged
    }
    XCTAssertTrue(sawInstalled)

    // The next scan reports the placed file: the installed LIST takes
    // over from the overlay (table-facing rows now include it) and
    // availability stays installed throughout.
    box.result = CachedModelScan.Result(
      modelsDirectory: URL(fileURLWithPath: "/tmp/models"),
      appManaged: [row(slug)], appError: nil, huggingFaceCache: [])
    await store.refresh()
    XCTAssertEqual(store.installed.map(\.filename), [slug])
    XCTAssertEqual(store.availability.status(repo: repo, file: file),
                   .installedAppManaged)
  }
}
