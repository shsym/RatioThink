import Foundation
import Combine
import os

/// Protocol seam over `ModelDownloader` so the controller can be unit-
/// tested without standing up a real `URLSession` (review v4 F33).
/// Production callers stay on the concrete class via the default
/// initializer; tests inject a stub.
public protocol ModelDownloading: AnyObject, Sendable {
  func start(repo: String, file: String) -> Result<DownloadHandle, DownloadError>
  func cancel(handle: DownloadHandle) -> DownloadError?
  func progress(for handle: DownloadHandle) -> AsyncStream<DownloadProgress>
}

extension ModelDownloader: ModelDownloading {}

/// Observable wrapper around `ModelDownloader` for the App side.
///
/// `AddModelSheet` emits `.queueDownload(repo:, file:)` outcomes that
/// `ModelsSettingsTab` previously dropped on the floor (review v2 F1).
/// This controller takes that outcome and actually starts a download:
///   1. Calls `ModelDownloader.start(repo:file:)`.
///   2. Subscribes to the per-handle `AsyncStream<DownloadProgress>`
///      and republishes a `[UUID: ActiveDownload]` snapshot for the UI.
///   3. Holds a one-shot `lastError` slot for `.start` failures that
///      never produce a progress stream (dedupe, dir creation, etc).
///
/// Lifetime: a single instance per `RatioThinkApp` lives in the SwiftUI env
/// so an in-flight download survives closing and reopening the
/// Settings sheet.
@MainActor
public final class ModelDownloadController: ObservableObject {

  /// One in-flight or recently-finished download. Kept around for
  /// ~5 seconds after a terminal phase so the UI shows the outcome
  /// (`completed` / `cancelled` / `failed`) before the row disappears.
  public struct ActiveDownload: Identifiable, Equatable {
    public let id: UUID
    public let repo: String
    public let file: String
    public var progress: DownloadProgress
    /// Set on `.failed`, surfaced as the row's caption.
    public var errorMessage: String?

    public var isTerminal: Bool {
      switch progress.phase {
      case .completed, .cancelled, .failed: return true
      case .starting, .downloading, .verifying: return false
      }
    }
  }

  /// `start`-time errors that bypass the progress stream — surfaced in
  /// the Settings UI's action-error slot rather than as a stuck row.
  public enum StartError: Error, CustomStringConvertible, Equatable {
    case downloaderFailed(String)

    public var description: String {
      switch self {
      case .downloaderFailed(let m): return "Could not start download: \(m)"
      }
    }
  }

  @Published public private(set) var active: [UUID: ActiveDownload] = [:]
  @Published public private(set) var lastError: String?
  /// Tick incremented every time a download reaches `.completed` so
  /// the Settings tab can re-scan the installed-models directory
  /// without subscribing to `active` directly.
  @Published public private(set) var completionTick: Int = 0

  private let downloader: ModelDownloading
  private let terminalRowLingerSeconds: UInt64
  private static let log = Logger(subsystem: "com.ratiothink.app", category: "downloads")

  public init(downloader: ModelDownloading = ModelDownloader(),
              terminalRowLingerSeconds: UInt64 = 5) {
    self.downloader = downloader
    self.terminalRowLingerSeconds = terminalRowLingerSeconds
  }

  /// Kick off a download. Returns the handle UUID on success so a
  /// caller can correlate; returns `nil` and writes `lastError`
  /// when `start` itself errors (e.g. dedupe collision, dir create).
  @discardableResult
  public func enqueue(repo: String, file: String) -> UUID? {
    let result = downloader.start(repo: repo, file: file)
    switch result {
    case .failure(let err):
      let msg = String(describing: err)
      lastError = "start(repo: \(repo), file: \(file)) failed: \(msg)"
      Self.log.error("ModelDownloadController enqueue failed: \(msg, privacy: .public)")
      Diag.app.event("download.fail", [("phase", "start"), ("file", file),
                                       ("reason", DiagnosticLog.redactHome(msg))])
      return nil

    case .success(let handle):
      lastError = nil
      let initial = DownloadProgress(handleID: handle.id,
                                      phase: .starting,
                                      bytesReceived: 0,
                                      bytesExpected: nil,
                                      etaSeconds: nil)
      active[handle.id] = ActiveDownload(id: handle.id,
                                          repo: handle.repo,
                                          file: handle.file,
                                          progress: initial,
                                          errorMessage: nil)
      Diag.app.event("download.start", [("repo", repo), ("file", file)])
      let stream = downloader.progress(for: handle)
      Task { [weak self] in
        await self?.consume(stream: stream, handle: handle)
      }
      return handle.id
    }
  }

  /// Cancel an in-flight download. No-op if the handle is unknown
  /// (already finished / cancelled). A non-nil producer error is
  /// promoted into both `entry.errorMessage` *and* the global
  /// `lastError` slot so the Cancel button does not appear to do
  /// nothing (review v3 F23). Previously we only logged.
  ///
  /// Race short-circuit: `.unknownHandle` and `.cancelled` are the
  /// natural outcomes of the producer winning the placement race
  /// (user clicks Cancel one heartbeat before `.completed` /
  /// `.failed`). They are NOT real failures — the row will reach a
  /// terminal phase via the AsyncStream momentarily — so we return
  /// silently rather than overwriting `errorMessage` with a
  /// misleading "cancel failed" caption that would otherwise ride
  /// onto a successfully `.completed` row (review v4 F31).
  ///
  /// Real cancel errors (anything other than the race cases above)
  /// synthesize a terminal `.failed` phase via `apply()` so the
  /// row stops rendering with `isTerminal == false` — otherwise
  /// the Cancel button stays clickable and the user re-fires the
  /// same failure indefinitely (review v5 F37). `scheduleEviction`
  /// is invoked by `apply()` via its terminal-phase branch.
  public func cancel(id: UUID) {
    guard let entry = active[id] else { return }
    let handle = DownloadHandle(id: id, repo: entry.repo, file: entry.file)
    guard let err = downloader.cancel(handle: handle) else { return }
    switch err {
    case .unknownHandle, .cancelled:
      Self.log.debug("cancel(\(id, privacy: .public)) lost placement race: \(String(describing: err), privacy: .public) — leaving row to AsyncStream terminal")
      return
    default:
      break
    }
    let msg = "cancel failed: \(String(describing: err))"
    Self.log.notice("cancel(\(id, privacy: .public)) \(msg, privacy: .public)")
    // Synthesize a terminal `.failed` so the row is not stuck
    // mid-flight after a real cancel failure (review v5 F37).
    // Reusing `apply()` keeps the phase / errorMessage / eviction
    // wiring in one place — the producer-side reason path.
    let synthetic = DownloadProgress(
      handleID: id,
      phase: .failed,
      bytesReceived: entry.progress.bytesReceived,
      bytesExpected: entry.progress.bytesExpected,
      etaSeconds: nil,
      verification: .notApplicable,
      failureReason: msg)
    apply(synthetic, handle: handle)
    lastError = msg
  }

  /// Clear the one-shot start-error slot. Called when the UI dismisses
  /// the message so the next failure can re-publish.
  public func clearLastError() {
    lastError = nil
  }

  // MARK: - Test seams (internal)

  /// Test-only hook used by `ModelDownloadControllerTests` to drive
  /// `apply` + `consume` without standing up a real `ModelDownloader`.
  /// Internal-only — kept off the public surface so external callers
  /// cannot fake a phase the producer never emitted.
  func _testOnly_apply(_ progress: DownloadProgress, handle: DownloadHandle) {
    apply(progress, handle: handle)
  }

  func _testOnly_consume(stream: AsyncStream<DownloadProgress>,
                         handle: DownloadHandle) async {
    await consume(stream: stream, handle: handle)
  }

  // MARK: - private

  private func consume(stream: AsyncStream<DownloadProgress>,
                       handle: DownloadHandle) async {
    var lastSeenPhase: DownloadProgress.Phase = .starting
    for await progress in stream {
      lastSeenPhase = progress.phase
      apply(progress, handle: handle)
    }
    // Stream ended. If the producer never emitted a terminal phase
    // (XPC disconnect, `downloader.invalidate()`, helper crash), the
    // row would otherwise sit forever as "starting…" — review v3
    // F25. Synthesize a terminal `.failed` with an explicit reason
    // so the UI shows the row reached an end-state and
    // `scheduleEviction` actually evicts it on the linger timer.
    if !lastSeenPhase.isTerminal {
      let synthetic = DownloadProgress(
        handleID: handle.id,
        phase: .failed,
        bytesReceived: active[handle.id]?.progress.bytesReceived ?? 0,
        bytesExpected: active[handle.id]?.progress.bytesExpected,
        etaSeconds: nil,
        verification: .notApplicable,
        failureReason: "stream closed before producer emitted a terminal phase")
      apply(synthetic, handle: handle)
    }
    scheduleEviction(of: handle.id)
  }

  private func apply(_ progress: DownloadProgress, handle: DownloadHandle) {
    // Capture the prior phase BEFORE we overwrite `entry.progress`
    // so the F32 recovery-clear logic below can see the transition.
    let priorPhase: DownloadProgress.Phase? = active[handle.id]?.progress.phase

    var entry = active[handle.id] ?? ActiveDownload(id: handle.id,
                                                     repo: handle.repo,
                                                     file: handle.file,
                                                     progress: progress,
                                                     errorMessage: nil)
    entry.progress = progress

    switch progress.phase {
    case .failed:
      // Carry the producer's actual reason instead of inventing a
      // generic "download failed" string (review v3 F24). The fallback
      // branch should be unreachable now that
      // `ModelDownloader.finishFailed` stamps a reason and the stream-
      // end synthesis path forges one — a `.fault` log here surfaces
      // any future producer that emits `.failed` without populating
      // `failureReason`, since the reviewer's preferred
      // `Phase.failed(reason:)` associated-value form was rejected on
      // wire-compat grounds (DownloadProgress is sent over XPC and
      // Phase's String-rawValue Codable conformance is load-bearing).
      if progress.failureReason == nil {
        Self.log.fault("DownloadProgress.failed emitted without failureReason — producer contract violation for handle \(handle.id, privacy: .public)")
      }
      entry.errorMessage = progress.failureReason
        ?? entry.errorMessage
        ?? "download failed (no reason emitted by producer)"

    case .completed:
      // F32: a stale errorMessage from a prior `.failed` (or from a
      // race-loser cancel that slipped through pre-F31) must not
      // ride onto a successful completion row. Clear unconditionally.
      entry.errorMessage = nil

    case .starting, .downloading, .verifying:
      // F32: clear on the first non-terminal phase after a prior
      // `.failed` so a retry-and-recover sequence doesn't carry the
      // old red caption forward.
      if priorPhase == .failed {
        entry.errorMessage = nil
      }

    case .cancelled:
      // Preserve any caption that was set (e.g. a real cancel error)
      // — the row is about to evict.
      break
    }

    active[handle.id] = entry
    if entry.isTerminal {
      if progress.phase == .completed {
        completionTick &+= 1
      }
      // Durable breadcrumb on the terminal transition only — guarded by the
      // prior-phase change so the per-tick `apply` calls don't duplicate it.
      if priorPhase != progress.phase {
        switch progress.phase {
        case .completed:
          Diag.app.event("download.finish", [("file", handle.file)])
        case .failed:
          Diag.app.event("download.fail", [("file", handle.file),
            ("reason", DiagnosticLog.redactHome(entry.errorMessage ?? "unknown"))])
        case .starting, .downloading, .verifying, .cancelled:
          break
        }
      }
      scheduleEviction(of: handle.id)
    }
  }

  private func scheduleEviction(of id: UUID) {
    Task { [weak self, terminalRowLingerSeconds] in
      try? await Task.sleep(nanoseconds: terminalRowLingerSeconds * 1_000_000_000)
      await MainActor.run {
        // Only evict if the row is still terminal — a retry could have
        // overwritten it with a fresh `.starting`.
        if let entry = self?.active[id], entry.isTerminal {
          self?.active.removeValue(forKey: id)
        }
      }
    }
  }
}

extension DownloadProgress.Phase {
  /// `true` for phases that the controller treats as end-states for a
  /// download entry (no more progress will arrive). Used by the
  /// stream-end synthesis path (review v3 F25) so we only forge a
  /// `.failed` when the producer didn't already finish.
  var isTerminal: Bool {
    switch self {
    case .completed, .cancelled, .failed: return true
    case .starting, .downloading, .verifying: return false
    }
  }
}
