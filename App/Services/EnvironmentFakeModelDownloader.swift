import Foundation

final class EnvironmentFakeModelDownloader: ModelDownloading, @unchecked Sendable {
  private let environment: [String: String]
  private let lock = NSLock()
  private var continuations: [UUID: AsyncStream<DownloadProgress>.Continuation] = [:]
  private var cancelledHandles: Set<UUID> = []

  init(environment: [String: String] = ProcessInfo.processInfo.environment) {
    self.environment = environment
  }

  func start(repo: String, file: String) -> Result<DownloadHandle, DownloadError> {
    .success(DownloadHandle(repo: repo, file: file))
  }

  /// #218: honor cancel so the GUI cancel → "Discard?" confirm →
  /// `.cancelled` flow is observable. The production `ModelDownloader`
  /// emits `.cancelled` synchronously on a hard cancel; this double
  /// mirrors that by yielding a terminal `.cancelled` to the live
  /// progress stream (the fake otherwise holds at `.downloading`).
  func cancel(handle: DownloadHandle) -> DownloadError? {
    lock.lock()
    cancelledHandles.insert(handle.id)
    let continuation = continuations[handle.id]
    lock.unlock()
    continuation?.yield(DownloadProgress(
      handleID: handle.id,
      phase: .cancelled,
      bytesReceived: 25_000_000,
      bytesExpected: 100_000_000,
      etaSeconds: nil,
      verification: .notApplicable
    ))
    continuation?.finish()
    return nil
  }

  func progress(for handle: DownloadHandle) -> AsyncStream<DownloadProgress> {
    AsyncStream { continuation in
      lock.lock()
      continuations[handle.id] = continuation
      let alreadyCancelled = cancelledHandles.contains(handle.id)
      lock.unlock()
      if alreadyCancelled {
        continuation.yield(DownloadProgress(
          handleID: handle.id,
          phase: .cancelled,
          bytesReceived: 25_000_000,
          bytesExpected: 100_000_000,
          etaSeconds: nil,
          verification: .notApplicable
        ))
        continuation.finish()
        return
      }
      continuation.onTermination = { [weak self] _ in
        guard let self else { return }
        self.lock.lock()
        self.continuations[handle.id] = nil
        self.lock.unlock()
      }
      Task { [weak self] in
        guard let self else { return }
        continuation.yield(DownloadProgress(
          handleID: handle.id,
          phase: .starting,
          bytesReceived: 0,
          bytesExpected: 100_000_000,
          etaSeconds: 60
        ))
        try? await Task.sleep(nanoseconds: 150_000_000)
        if self.isCancelled(handle.id) { return }
        continuation.yield(DownloadProgress(
          handleID: handle.id,
          phase: .downloading,
          bytesReceived: 25_000_000,
          bytesExpected: 100_000_000,
          etaSeconds: 60
        ))
        if let failure = self.environment["PIE_TEST_FAKE_DOWNLOAD_FAILURE"],
           !failure.isEmpty {
          try? await Task.sleep(nanoseconds: 150_000_000)
          if self.isCancelled(handle.id) { return }
          continuation.yield(DownloadProgress(
            handleID: handle.id,
            phase: .failed,
            bytesReceived: 25_000_000,
            bytesExpected: 100_000_000,
            etaSeconds: nil,
            verification: .notApplicable,
            failureReason: failure
          ))
          continuation.finish()
          return
        }
        // #326: opt-in completion so a test can drive the
        // download → onDownloaded → auto-start latch. Without this flag
        // the stream stays open at `.downloading` (the prior behavior).
        if environment["PIE_TEST_FAKE_DOWNLOAD_COMPLETE"] == "1" {
          try? await Task.sleep(nanoseconds: 150_000_000)
          continuation.yield(DownloadProgress(
            handleID: handle.id,
            phase: .completed,
            bytesReceived: 100_000_000,
            bytesExpected: 100_000_000,
            etaSeconds: 0,
            verification: .verified
          ))
          continuation.finish()
        }
        // Otherwise hold at `.downloading` (no terminal) so the row stays
        // cancelable until `cancel(handle:)` yields `.cancelled`.
      }
    }
  }

  private func isCancelled(_ id: UUID) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelledHandles.contains(id)
  }
}
