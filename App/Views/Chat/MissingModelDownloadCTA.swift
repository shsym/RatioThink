import SwiftUI

/// Shared Download affordance for #326's two recovery surfaces — the
/// no-model send prompt and the failed(modelMissing) chat banner.
///
/// Given a `ModelDownloadTarget`, it drives the app-wide
/// `ModelDownloadController` (the SAME controller Settings → Models
/// uses, so an in-flight download is one shared queue), renders live
/// progress, and calls `onDownloaded` exactly once when the download
/// completes — the parent wires that to `startEngine` so the engine
/// boots with the now-present model.
struct MissingModelDownloadCTA: View {
  let target: ModelDownloadTarget
  /// Fired exactly once when the tracked download reaches `.completed`.
  let onDownloaded: () -> Void
  /// Live engine status, so the completed latch can drop back to Retry if
  /// the post-download `startEngine` does not take (PR#15 F1).
  let engineStatus: EngineStatus
  /// Grace window after completion before the latch reverts to Retry when
  /// the engine is still stuck. Injectable so a test need not wait the
  /// production default. The fast path is `onChange(engineStatus)`; this
  /// is the safety net for a re-failure that carries an identical status
  /// value (no `onChange` to observe).
  var reFailureGrace: Duration = .seconds(8)

  @EnvironmentObject private var downloads: ModelDownloadController
  /// Handle of the download this CTA started. Nil until the user taps
  /// Download (or after a failure/cancel reset).
  @State private var handleID: UUID?
  /// Latched on `.completed` so the row stays in its terminal "starting
  /// engine" state even after the controller evicts the finished row
  /// (~5 s linger) and so `onDownloaded` fires only once.
  @State private var didComplete = false
  /// Inline caption for a `start`-time enqueue failure (dedupe, dir
  /// create) that never produces a progress row.
  @State private var enqueueError: String?

  /// The tracked download's live snapshot, if still present in the
  /// controller.
  private var entry: ModelDownloadController.ActiveDownload? {
    handleID.flatMap { downloads.active[$0] }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      content
      if let enqueueError {
        Text(enqueueError)
          .font(.caption)
          .foregroundStyle(.red)
      }
    }
    .onChange(of: entry?.progress.phase) { _, phase in
      if phase == .completed, !didComplete {
        didComplete = true
        onDownloaded()
      }
    }
    .onChange(of: engineStatus) { _, _ in
      // PR#15 F1: the engine re-entered failed(modelMissing) after we
      // latched completion — the start did not take. Drop the green
      // latch back to a Retry/Download affordance (a re-download also
      // re-stages a corrupt/partial artifact).
      if MissingModelRecovery.completedLatchShouldReset(
        didComplete: didComplete, engineStatus: engineStatus) {
        resetToRetry()
      }
    }
    .task(id: didComplete) {
      // Safety net for a re-failure carrying an identical status value
      // (no `onChange` fires): a successful start unmounts this banner
      // (engine leaves failed(modelMissing)) and cancels this task; if
      // we are still mounted + latched after the grace window, the start
      // did not take — revert to Retry.
      guard didComplete else { return }
      try? await Task.sleep(for: reFailureGrace)
      guard !Task.isCancelled, didComplete else { return }
      resetToRetry()
    }
    .onAppear {
      guard handleID == nil, !didComplete else { return }
      if let existing = inFlightHandleForTarget() {
        // Reflect a download for this target already in flight (started by
        // the sibling surface or Settings → Models) — the controller is
        // shared app-wide — instead of offering a redundant Download.
        handleID = existing
      } else if isTargetInstalled() {
        // PR#15 F5: a sibling surface already finished + evicted this
        // download. Reflect "done" and (idempotently — startEngine
        // swallows .alreadyRunning) ensure the engine is kicked, rather
        // than re-offering a redundant Download.
        didComplete = true
        onDownloaded()
      }
    }
  }

  private func resetToRetry() {
    didComplete = false
    handleID = nil
  }

  @ViewBuilder
  private var content: some View {
    if didComplete {
      Label("Downloaded — starting engine…", systemImage: "checkmark.circle.fill")
        .font(.callout)
        .foregroundStyle(.green)
        .accessibilityIdentifier("missingModel.completed")
    } else if let entry, !entry.isTerminal {
      progressRow(entry)
    } else if let entry, entry.progress.phase == .failed {
      failedRow(entry)
    } else {
      downloadButton
    }
  }

  private var downloadButton: some View {
    Button(action: startDownload) {
      Label(downloadLabel, systemImage: "arrow.down.circle")
    }
    .buttonStyle(.borderedProminent)
    .accessibilityIdentifier("missingModel.download")
  }

  private var downloadLabel: String {
    if let size = target.approximateSizeBytes {
      return "Download \(target.displayName) (\(InstalledModels.formattedSize(size)))"
    }
    return "Download \(target.displayName)"
  }

  private func progressRow(_ entry: ModelDownloadController.ActiveDownload) -> some View {
    HStack(spacing: 10) {
      if entry.progress.phase == .verifying {
        ProgressView().controlSize(.small)
        Text("Verifying…").font(.caption).foregroundStyle(.secondary)
      } else if let total = entry.progress.bytesExpected, total > 0 {
        let frac = max(0, min(1, Double(entry.progress.bytesReceived) / Double(total)))
        ProgressView(value: frac).frame(width: 160)
        Text("\(InstalledModels.formattedSize(entry.progress.bytesReceived)) / \(InstalledModels.formattedSize(total))")
          .font(.caption).monospacedDigit().foregroundStyle(.secondary)
      } else {
        ProgressView().controlSize(.small)
        Text("Downloading \(target.displayName)…").font(.caption).foregroundStyle(.secondary)
      }
      Button("Cancel") {
        if let id = handleID { downloads.cancel(id: id) }
      }
      .buttonStyle(.borderless)
      .accessibilityIdentifier("missingModel.cancel")
    }
    // NOTE: no `.accessibilityIdentifier` on this row container — like the
    // `NoModelLoadedPrompt` container, it would propagate down and override
    // the embedded "missingModel.cancel" button's identifier (making the
    // in-flight Cancel unqueryable). The row's controls carry their own ids.
  }

  private func failedRow(_ entry: ModelDownloadController.ActiveDownload) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
      Text(entry.errorMessage ?? "Download failed")
        .font(.caption).foregroundStyle(.secondary)
        .lineLimit(2).truncationMode(.tail)
      Button("Retry", action: startDownload)
        .buttonStyle(.bordered)
        .accessibilityIdentifier("missingModel.retry")
    }
  }

  private func startDownload() {
    enqueueError = nil
    didComplete = false
    // Adopt an in-flight download for the same target rather than
    // tripping the downloader's dedupe (which would return nil + a
    // confusing "already downloading" error).
    if let existing = inFlightHandleForTarget() {
      handleID = existing
      return
    }
    if let id = downloads.enqueue(repo: target.repo, file: target.file) {
      handleID = id
    } else {
      // `enqueue` returned nil — surface the controller's reason instead
      // of looking like the button did nothing.
      handleID = nil
      enqueueError = downloads.lastError ?? "Could not start download"
    }
  }

  /// Handle id of a non-terminal download already running for this
  /// target, if any. Lets every surface bound to the shared controller
  /// (this CTA, its sibling, Settings → Models) reflect one queue.
  private func inFlightHandleForTarget() -> UUID? {
    downloads.active.values.first {
      $0.repo == target.repo && $0.file == target.file && !$0.isTerminal
    }?.id
  }

  /// Whether this target's file is already staged on disk. The download
  /// writes `<modelsRoot>/<repo>/<file>`, which `joinModelPath` resolves
  /// from the `<repo>/<file>` slug — the same check the no-model prompt
  /// uses (PR#15 F5).
  private func isTargetInstalled() -> Bool {
    ChatScaffoldView.isModelInstalled("\(target.repo)/\(target.file)")
  }
}
