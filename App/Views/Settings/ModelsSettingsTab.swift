import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// *Settings → Models* — installed library + Add Model entry point.
/// Active downloads (queued by the Add sheet) surface in a "Downloading"
/// section above the installed table. ( removed the swap-skip list;
/// every model load is now always confirmed.)
struct ModelsSettingsTab: View {
  @EnvironmentObject private var downloads: ModelDownloadController
  @State private var installed: [InstalledModel] = []
  @State private var scanError: String?
  @State private var showAddSheet: Bool = false
  @State private var modelsDirectory: URL?

  /// Sticky non-fatal error from the most recent table-level action
  /// (drop import, delete, download enqueue). Replaces the old
  /// `importError` slot which mis-labeled delete failures as imports
  /// (review v2 F11). Each writer clears prior values so two unrelated
  /// errors don't blend together.
  @State private var actionError: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      header

      DownloadsInFlightSection()

      InstalledModelsTable(rows: installed,
                            error: scanError,
                            actionError: actionError,
                            onReveal: revealInFinder,
                            onDelete: deleteFile,
                            onDrop: handleDrop)
    }
    .padding(20)
    .task { await refresh() }
    .onChange(of: downloads.completionTick) { _, _ in
      Task { await refresh() }
    }
    .sheet(isPresented: $showAddSheet) {
      AddModelSheet(modelsDirectory: modelsDirectory) { outcome in
        handleSheetOutcome(outcome)
        Task { await refresh() }
      }
    }
  }

  // MARK: - Header

  private var header: some View {
    HStack(alignment: .firstTextBaseline) {
      SettingsSectionHeader(title: "Installed Models")
      Spacer()
      Button {
        showAddSheet = true
      } label: {
        Label("Add Model…", systemImage: "plus")
      }
      .accessibilityIdentifier("AddModelButton")
    }
  }

  // MARK: - Side effects

  @MainActor
  private func refresh() async {
    // Filesystem walks run off the main actor. Surface models already
    // staged in the shared HF cache (safetensors / GGUF) alongside
    // app-managed files, deduped by slug keeping the app-managed row (the
    // resolver's app-staged-first precedence). HF rows are read-only in
    // the table. On an app-dir scan failure the HF rows are KEPT and the
    // error shows as a banner above the table rather than emptying it.
    let scan = await CachedModelScan.run()
    modelsDirectory = scan.modelsDirectory
    let appSlugs = Set(scan.appManaged.map(\.filename))
    installed = scan.appManaged + scan.huggingFaceCache.filter { !appSlugs.contains($0.filename) }
    scanError = scan.appError
  }

  private func revealInFinder(_ row: InstalledModel) {
    NSWorkspace.shared.activateFileViewerSelecting([row.url])
  }

  private func deleteFile(_ row: InstalledModel) {
    let alert = NSAlert()
    alert.messageText = "Delete \(row.displayName)?"
    alert.informativeText = "The file will be moved to the Trash. This does not affect profiles that reference it."
    alert.addButton(withTitle: "Delete")
    alert.addButton(withTitle: "Cancel")
    alert.alertStyle = .warning
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    do {
      try FileManager.default.trashItem(at: row.url, resultingItemURL: nil)
      actionError = nil
    } catch {
      // Label the failure explicitly so the user knows it was a
      // delete, not the latest drop import (review v2 F11).
      actionError = "Delete '\(row.filename)' failed: \(error)"
      return
    }
    //  F10/F12: move the durable `.unverified` sidecar to the Trash
    // ALONGSIDE the GGUF — same recoverable semantics. The GGUF is
    // trashed (recoverable), so the marker must be too: a hard-remove
    // here would let a Trash-restore bring back the file WITHOUT its
    // marker, re-introducing the silent-verified downgrade (F12). A
    // missing sidecar is fine (`try?`).
    try? FileManager.default.trashItem(
      at: URL(fileURLWithPath: row.url.path + InstalledModels.unverifiedSuffix),
      resultingItemURL: nil)
    Task { await refresh() }
  }

  /// Drag-drop handler. Surfaces a per-file aggregate so partial
  /// failures don't vanish (review v2 F8). Format:
  /// "Imported 4 of 5. Failed: foo.gguf (extension); bar.gguf
  /// (already exists)."
  private func handleDrop(_ urls: [URL], _ providerErrors: [String]) {
    guard let dir = modelsDirectory else {
      actionError = "models directory not ready"
      return
    }
    var succeeded = 0
    var failures: [String] = []
    for src in urls {
      do {
        try ModelImporter.importFile(at: src, into: dir)
        succeeded += 1
      } catch let e as ModelImporter.ImportError {
        failures.append("\(src.lastPathComponent) (\(shortReason(for: e)))")
      } catch {
        failures.append("\(src.lastPathComponent) (\(error))")
      }
    }
    for providerErr in providerErrors {
      failures.append("provider error: \(providerErr)")
    }
    actionError = formatDropSummary(total: urls.count + providerErrors.count,
                                     succeeded: succeeded,
                                     failures: failures)
    Task { await refresh() }
  }

  /// Forwarded from `AddModelSheet`. `.queueDownload` was previously
  /// dropped on the floor (review v2 F1). `.imported` now carries the
  /// full batch so partial-failure aggregates from a multi-URL drop
  /// land in `actionError` instead of being eaten by the sheet's
  /// first-success dismissal (review v3 F21).
  private func handleSheetOutcome(_ outcome: AddModelSheet.Outcome) {
    switch outcome {
    case .cancelled:
      return
    case .imported(let successes, let failures):
      actionError = Self.formatImportOutcome(successes: successes,
                                              failures: failures)
    case .queueDownload(let repo, let file):
      if downloads.enqueue(repo: repo, file: file) == nil,
         let err = downloads.lastError {
        actionError = err
      } else {
        actionError = nil
      }
    }
  }

  /// Pure formatter — `nil` on a clean batch (no failures), otherwise
  /// `"Imported K of N. Failed: foo.gguf (extension); bar.gguf
  /// (already exists)"`. Extracted as a `static` so the v3 F21
  /// contract — every dropped URL ends up visible to the caller —
  /// can be unit-tested without standing up the full SwiftUI view
  /// hierarchy. The brief explicitly asked: "Test recommendation:
  /// UI test: drop 3 .gguf files where 2 fail validation; assert
  /// the parent sees both failures."
  static func formatImportOutcome(successes: [URL],
                                   failures: [AddModelSheet.BatchFailure]) -> String? {
    if failures.isEmpty { return nil }
    let parts = failures.map { "\($0.filename) (\($0.reason))" }
    return "Imported \(successes.count) of \(successes.count + failures.count). Failed: "
      + parts.joined(separator: "; ")
  }

  private func formatDropSummary(total: Int,
                                  succeeded: Int,
                                  failures: [String]) -> String? {
    if failures.isEmpty {
      return nil
    }
    var line = "Imported \(succeeded) of \(total)."
    if !failures.isEmpty {
      line += " Failed: " + failures.joined(separator: "; ")
    }
    return line
  }

  private func shortReason(for err: ModelImporter.ImportError) -> String {
    switch err {
    case .notAFile:          return "not a regular file"
    case .wrongExtension:    return "extension"
    case .destinationExists: return "already exists"
    case .copyFailed:        return "copy failed"
    }
  }
}

// MARK: - Downloads-in-flight

/// Compact status table for every active `ModelDownloadController`
/// entry. Hidden when `active` is empty so the Models tab stays calm
/// in the steady state.
private struct DownloadsInFlightSection: View {
  @EnvironmentObject private var downloads: ModelDownloadController

  var body: some View {
    let rows = downloads.active.values.sorted { $0.file < $1.file }
    if rows.isEmpty {
      EmptyView()
    } else {
      VStack(alignment: .leading, spacing: 6) {
        SettingsSectionHeader(title: "Downloading")
        ForEach(rows) { row in
          DownloadRow(entry: row) {
            downloads.cancel(id: row.id)
          }
        }
        if let err = downloads.lastError {
          Text(err)
            .font(.callout)
            .foregroundStyle(.red)
        }
      }
      .padding(10)
      .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }
  }
}

private struct DownloadRow: View {
  let entry: ModelDownloadController.ActiveDownload
  let onCancel: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text(entry.file).monospaced().lineLimit(1).truncationMode(.middle)
        Text(entry.repo).font(.caption).foregroundStyle(.secondary)
          .lineLimit(1).truncationMode(.middle)
        if let msg = entry.errorMessage {
          Text(msg).font(.caption).foregroundStyle(.red)
        }
      }
      Spacer()
      progressView
      if !entry.isTerminal {
        Button("Cancel", action: onCancel)
          .buttonStyle(.borderless)
      }
    }
    .padding(.vertical, 4)
  }

  @ViewBuilder
  private var progressView: some View {
    switch entry.progress.phase {
    case .completed:
      //  F1: a `.completed` download is NOT necessarily integrity-
      // checked. A resumed Xet download skips the resolve 302, so the
      // X-Linked-Etag is never captured and `completeDownload` finishes
      // `.notAdvertised` (sha256 verification skipped). Surfacing that
      // as the same green "Done" as a `.verified` download hides a
      // skipped integrity check behind a success badge — exactly the
      // silent-fallback the project forbids. Render a distinct
      // "Unverified" badge for anything other than `.verified`.
      if entry.progress.verification == .verified {
        Label("Done", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
          .accessibilityIdentifier("ModelRow-State-Done")
      } else {
        Label("Unverified", systemImage: "exclamationmark.shield.fill")
          .foregroundStyle(.orange)
          .help("Downloaded but sha256 could not be verified (no X-Linked-Etag advertised — e.g. a resumed download). The file was installed without an integrity check.")
          .accessibilityIdentifier("ModelRow-State-Unverified")
      }
    case .cancelled:
      Label("Cancelled", systemImage: "xmark.circle").foregroundStyle(.secondary)
    case .failed:
      Label("Failed", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
    case .verifying:
      Label("Verifying", systemImage: "checkmark.shield").foregroundStyle(.secondary)
    case .starting:
      ProgressView().controlSize(.small)
    case .downloading:
      VStack(alignment: .trailing, spacing: 2) {
        if let total = entry.progress.bytesExpected, total > 0 {
          let frac = max(0, min(1, Double(entry.progress.bytesReceived) / Double(total)))
          ProgressView(value: frac).frame(width: 100)
          Text("\(InstalledModels.formattedSize(entry.progress.bytesReceived)) / \(InstalledModels.formattedSize(total))")
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        } else {
          ProgressView().controlSize(.small)
        }
      }
    }
  }
}

// MARK: - Installed table

private struct InstalledModelsTable: View {
  let rows: [InstalledModel]
  let error: String?
  let actionError: String?
  let onReveal: (InstalledModel) -> Void
  let onDelete: (InstalledModel) -> Void
  let onDrop: ([URL], [String]) -> Void

  @State private var isTargeted: Bool = false

  var body: some View {
    VStack(spacing: 8) {
      // The scan error is a banner ABOVE the table, not a replacement for
      // it — an app-dir failure must not hide healthy HF-cache rows that
      // were discovered independently.
      if let error {
        Text(error)
          .foregroundStyle(.red)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      if rows.isEmpty {
        if error == nil { emptyState }
      } else {
        Table(rows) {
          TableColumn("Name") { row in
            HStack(spacing: 6) {
              if row.metadataUnreadable {
                Image(systemName: "questionmark.circle.fill")
                  .foregroundStyle(.orange)
                  .help("File metadata unreadable — size and date are unavailable. Reveal in Finder to inspect.")
              } else if row.isPartial {
                Image(systemName: "exclamationmark.triangle.fill")
                  .foregroundStyle(.orange)
                  .help("Download incomplete (.partial sibling present)")
              } else if row.isUnverified {
                //  F10: durable unverified marker — the file was
                // installed without a sha256 integrity check.
                Image(systemName: "exclamationmark.shield.fill")
                  .foregroundStyle(.orange)
                  .help("Installed without a verified sha256 (no X-Linked-Etag advertised — e.g. a resumed download). Integrity was not checked.")
                  .accessibilityIdentifier("InstalledRow-Unverified-\(row.id)")
              }
              Text(row.displayName).lineLimit(1).truncationMode(.middle)
              if row.source == .huggingFaceCache {
                // Cached HF models are read-only here (the app does not
                // own ~/.cache/huggingface). Tag them so the user
                // understands why Delete is unavailable.
                Text("HF cache")
                  .font(.caption2)
                  .foregroundStyle(.secondary)
                  .padding(.horizontal, 5)
                  .padding(.vertical, 1)
                  .background(Capsule().fill(Color.secondary.opacity(0.15)))
                  .help("Discovered in the shared Hugging Face cache. Managed outside RatioThink — reveal in Finder to inspect.")
                  .accessibilityIdentifier("InstalledRow-HFCache-\(row.id)")
              }
            }
          }
          TableColumn("Size") { row in
            if row.metadataUnreadable {
              Text("—").foregroundStyle(.tertiary).help("size unavailable")
            } else {
              Text(InstalledModels.formattedSize(row.sizeBytes))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
          }
          .width(min: 70, ideal: 80)
          TableColumn("Modified") { row in
            if row.metadataUnreadable {
              Text("—").foregroundStyle(.tertiary).help("modification date unavailable")
            } else {
              Text(row.modifiedAt, format: .dateTime.year().month().day().hour().minute())
                .foregroundStyle(.secondary)
            }
          }
          .width(min: 130, ideal: 150)
          TableColumn("") { row in
            HStack(spacing: 4) {
              Button { onReveal(row) } label: {
                Image(systemName: "folder")
              }
              .buttonStyle(.borderless)
              .help("Reveal in Finder")
              Button(role: .destructive) { onDelete(row) } label: {
                Image(systemName: "trash")
              }
              .buttonStyle(.borderless)
              // HF-cache rows are read-only — the app does not manage the
              // shared cache, so deletion is out of scope.
              .disabled(row.source == .huggingFaceCache)
              .help(row.source == .huggingFaceCache
                    ? "Cached Hugging Face models are managed outside RatioThink"
                    : "Move to Trash")
            }
          }
          .width(min: 50, ideal: 60)
        }
        .frame(minHeight: 140)
      }

      if let actionError {
        Text(actionError)
          .foregroundStyle(.red)
          .frame(maxWidth: .infinity, alignment: .leading)
          .font(.callout)
      }
    }
    .padding(8)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(isTargeted ? Color.accentColor : Color.secondary.opacity(0.2),
                      style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: isTargeted ? [6] : []))
    )
    .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
      DroppedURLs.resolve(providers) { res in
        onDrop(res.urls, res.errors)
      }
      return true
    }
  }

  private var emptyState: some View {
    VStack(spacing: 8) {
      Image(systemName: "shippingbox")
        .font(.system(size: 28))
        .foregroundStyle(.tertiary)
      Text("No models installed yet")
        .foregroundStyle(.secondary)
      Text("Click *Add Model…* or drag a .gguf file here.")
        .font(.callout)
        .foregroundStyle(.tertiary)
    }
    .frame(maxWidth: .infinity, minHeight: 140)
  }
}
