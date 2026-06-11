import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// *Settings → Models* — installed library + Add Model entry point.
/// Active downloads (queued by the Add sheet) surface in a "Downloading"
/// section above the installed table. ( removed the swap-skip list;
/// every model load is now always confirmed.)
struct ModelsSettingsTab: View {
  @EnvironmentObject private var downloads: ModelDownloadController
  /// The one live source of truth for local model availability (#514
  /// rescope): scan results, modelsDirectory, scanError, freshness,
  /// and the classification the Add sheet + duplicate guard consume.
  @EnvironmentObject private var library: ModelLibraryStore
  @EnvironmentObject private var profileStore: ProfileStore
  @State private var showAddSheet: Bool = false

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

      InstalledModelsTable(rows: library.installed,
                            error: library.scanError,
                            actionError: actionError,
                            isScanned: library.freshness == .scanned,
                            onReveal: revealInFinder,
                            onDelete: deleteFile,
                            onDrop: handleDrop)

      MemoryGuardrailSection()
    }
    .padding(20)
    // Pin the pane to the top of the tab. Without this the VStack only
    // expands to fill the 520-tall Settings pane in states that contain
    // a greedy child (the populated `Table`); the empty, loading, and
    // error states size to their content and TabView centers the whole
    // block vertically — the "model content floats mid-pane" misalignment.
    // `.topLeading` keeps every state top-anchored, matching ProfilesSettingsTab.
    // Frame goes AFTER `.padding(20)` so the inset stays inside the greedy
    // frame; before it, the filled frame + outer padding would overflow the pane.
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .task { await library.refresh() }
    // No completionTick plumbing: the store reconciles download
    // completions itself (overlay + self-triggered rescan).
    .sheet(isPresented: $showAddSheet) {
      AddModelSheet(modelsDirectory: library.modelsDirectory) { outcome in
        handleSheetOutcome(outcome)
        Task { await library.refresh() }
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

  private func revealInFinder(_ row: InstalledModel) {
    NSWorkspace.shared.activateFileViewerSelecting([row.url])
  }

  private func deleteFile(_ row: InstalledModel) {
    let affected = profileStore.profilesReferencingModel(row.filename)
    let alert = NSAlert()
    alert.messageText = "Delete \(row.displayName)?"
    if affected.isEmpty {
      alert.informativeText = "The file will be moved to the Trash."
    } else {
      alert.informativeText = Self.deleteReferencedModelMessage(
        row: row,
        affectedProfiles: affected
      )
    }
    alert.addButton(withTitle: affected.isEmpty ? "Delete" : "Delete and Clear Defaults")
    alert.addButton(withTitle: "Cancel")
    alert.alertStyle = .warning
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    do {
      try Self.deleteInstalledModel(row: row, profileStore: profileStore)
      actionError = nil
    } catch {
      // Label the failure explicitly so the user knows it was a
      // delete, not the latest drop import (review v2 F11).
      actionError = "Delete '\(row.filename)' failed: \(error)"
      return
    }
    Task { await library.refresh() }
  }

  static func deleteInstalledModel(
    row: InstalledModel,
    profileStore: ProfileStore,
    trashModel: (URL) throws -> Void = { url in
      try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    },
    trashSidecar: (URL) throws -> Void = { url in
      try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
  ) throws {
    try profileStore.withClearedModelDefaults(referencing: row.filename) {
      try trashModel(row.url)
    }
    // #469: complete the active-model marker's lifecycle at the delete choke
    // point. The marker has precedence over the profile default in
    // `HelperResumeAction`, so if the deleted model was the marker, a later
    // menu-bar Resume / crash auto-relaunch would resolve the now-missing model
    // ahead of the still-valid profile default and dead-end on `modelMissing`.
    // Clearing it here lets Resume fall through to the profile default.
    // Best-effort (`try?`): `clearActiveModelID` logs on failure, and
    // `HelperResumeAction`'s marker-miss retry is the backstop for any marker
    // that goes stale outside this path (external deletion / HF-cache eviction).
    if profileStore.activeModelID == row.filename {
      try? profileStore.clearActiveModelID()
    }
    //  F10/F12: move the durable `.unverified` sidecar to the Trash
    // ALONGSIDE the GGUF — same recoverable semantics. The GGUF is
    // trashed (recoverable), so the marker must be too: a hard-remove
    // here would let a Trash-restore bring back the file WITHOUT its
    // marker, re-introducing the silent-verified downgrade (F12). A
    // missing sidecar is fine (`try?`).
    try? trashSidecar(URL(fileURLWithPath: row.url.path + InstalledModels.unverifiedSuffix))
  }

  static func deleteReferencedModelMessage(
    row: InstalledModel,
    affectedProfiles: [ProfileModelReference]
  ) -> String {
    let count = affectedProfiles.count
    let names = affectedProfiles.map(\.name).joined(separator: ", ")
    let profileWord = count == 1 ? "profile uses" : "profiles use"
    let defaultsWord = count == 1 ? "default" : "defaults"
    return "\(count) \(profileWord) this model as its default: \(names). The file will be moved to the Trash and those profile \(defaultsWord) will be cleared. Profiles with no default will show Choose/Download actions the next time you use them; a running engine is not stopped."
  }

  /// Drag-drop handler. Surfaces a per-file aggregate so partial
  /// failures don't vanish (review v2 F8). Format:
  /// "Imported 4 of 5. Failed: foo.gguf (extension); bar.gguf
  /// (already exists)."
  private func handleDrop(_ urls: [URL], _ providerErrors: [String]) {
    guard let dir = library.modelsDirectory else {
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
    Task { await library.refresh() }
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
      // #514: duplicate prevention happens HERE, before enqueue — the
      // downloader's overwrite semantics are not the user-facing
      // guard. `library.availability` is the store's LIVE truth on
      // every axis (in-flight set, completion overlay, scan results).
      switch Self.duplicateAddDecision(
        repo: repo, file: file,
        availability: library.availability,
        modelsDirectory: library.modelsDirectory) {
      case .blocked(let reason):
        actionError = reason
        return
      case .proceed:
        break
      }
      // A nil enqueue is unconditionally an error: `start` failed and
      // no progress stream exists, so without a message the click
      // reads as silent success. The fallback copy covers a (today
      // unreachable) failure that didn't populate `lastError`.
      if downloads.enqueue(repo: repo, file: file) == nil {
        actionError = Self.enqueueFailureMessage(downloads.lastError)
      } else {
        actionError = nil
      }
    }
  }

  /// `downloads.enqueue == nil` copy — the producer's reason when it
  /// gave one, an explicit failure line otherwise (never silence).
  static func enqueueFailureMessage(_ lastError: String?) -> String {
    lastError ?? "Download could not be queued."
  }

  /// Outcome of the pre-enqueue duplicate guard (review v1 F4 — the
  /// classify-or-enqueue decision, extracted so both branches are
  /// directly unit-testable without the SwiftUI view).
  enum AddDecision: Equatable {
    case proceed
    case blocked(String)
  }

  /// #514 duplicate guard, decided BEFORE `downloads.enqueue`.
  ///
  /// Two layers:
  ///  1. The `ModelAvailability` classification fed by
  ///     `ModelLibraryStore` — live on every axis the app can know
  ///     about (non-terminal downloads, the completion overlay, the
  ///     latest scan, and the explicit first-scan state).
  ///  2. A targeted filesystem check on the exact destination
  ///     `<modelsRoot>/<repo>/<file>` (the ticket's detection-strategy
  ///     backstop). KEPT as defense-in-depth after the store rescope:
  ///     the store structurally closes the pre-first-scan and
  ///     post-completion windows, but a file placed EXTERNALLY between
  ///     scans (Finder copy, another tool) is invisible to any
  ///     in-process bookkeeping until the next walk — this one cheap
  ///     `stat` at the decision point catches it. Consistent with the
  ///     F1 partial policy: a destination with a `.partial` sibling is
  ///     a broken install, NOT a duplicate — the re-download repairs
  ///     it, so it proceeds. A DIRECTORY at the destination path is
  ///     not an installed model and proceeds (cycle-607 minor). When
  ///     the caller has no scanned `modelsDirectory` yet, the backstop
  ///     resolves the same models root itself (cycle-607 minor) —
  ///     injectable so tests stay hermetic.
  static func duplicateAddDecision(
    repo: String,
    file: String,
    availability: ModelAvailability,
    modelsDirectory: URL?,
    fallbackModelsDirectory: () -> URL? = { try? PieDirs.models() },
    fileManager: FileManager = .default
  ) -> AddDecision {
    let slug = ModelAvailability.slug(repo: repo, file: file)
    if let blocked = availability.status(repo: repo, file: file).blockedReason(slug: slug) {
      return .blocked(blocked)
    }
    if let dir = modelsDirectory ?? fallbackModelsDirectory() {
      let dest = dir.appendingPathComponent(slug)
      var isDirectory: ObjCBool = false
      if fileManager.fileExists(atPath: dest.path, isDirectory: &isDirectory),
         !isDirectory.boolValue,
         !fileManager.fileExists(atPath: dest.path + InstalledModels.partialSuffix) {
        return .blocked(
          ModelAvailability.Status.installedAppManaged.blockedReason(slug: slug)
            ?? "'\(slug)' is already installed.")
      }
    }
    return .proceed
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

  /// #218: cancelling a download is a hard cancel (partial progress is
  /// discarded, no resume), so the trailing "Cancel" arms an inline
  /// confirm rather than firing immediately — matching the deliberate
  /// inline-confirm pattern used by the model-load popover (#359), and
  /// avoiding a system dialog (the app uses none).
  @State private var confirmingCancel = false

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
        cancelControl
      }
    }
    .padding(.vertical, 4)
    // A download that reaches a terminal phase under the armed confirm
    // (e.g. it completed first) shouldn't keep the prompt armed.
    .onChange(of: entry.isTerminal) { _, terminal in
      if terminal { confirmingCancel = false }
    }
  }

  @ViewBuilder
  private var cancelControl: some View {
    if confirmingCancel {
      HStack(spacing: 6) {
        Text("Discard?")
          .font(.caption)
          .foregroundStyle(.secondary)
        Button("Keep") { confirmingCancel = false }
          .buttonStyle(.borderless)
          .accessibilityIdentifier("DownloadRow-KeepDownloading")
        Button("Discard", role: .destructive) {
          confirmingCancel = false
          onCancel()
        }
        .buttonStyle(.borderless)
        .help("Stops the download and discards partial progress (no resume).")
        .accessibilityIdentifier("DownloadRow-ConfirmCancel")
      }
    } else {
      Button("Cancel") { confirmingCancel = true }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("DownloadRow-Cancel")
    }
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
  /// `false` until the store's first scan has applied. An empty row
  /// list before that means "haven't looked yet", not "no models" —
  /// rendering the no-models empty state then would be a false claim
  /// (#514 rescope, freshness axis).
  let isScanned: Bool
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
        if error == nil {
          if isScanned {
            emptyState
          } else {
            scanningState
          }
        }
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
              } else if let reason = row.unsupportedReason {
                // #349: a discovered-but-unlaunchable row (a collapsed
                // split-GGUF shard set) carries `unsupportedReason`. The
                // profile picker + LaunchSpecResolver already refuse it;
                // surface it here too so the inventory view doesn't show it
                // as a normal, loadable model. `nosign` (distinct from the
                // partial/unverified warnings) reads as "the engine can't
                // load this", with the reason in the tooltip.
                Image(systemName: "nosign")
                  .foregroundStyle(.orange)
                  .help(reason)
                  .accessibilityIdentifier("InstalledRow-Unsupported-\(row.id)")
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
                  .help("Discovered in the shared Hugging Face cache. Managed outside Rational — reveal in Finder to inspect.")
                  .accessibilityIdentifier("InstalledRow-HFCache-\(row.id)")
              }
              if let warning = row.supportWarning {
                Label("Unverified", systemImage: "exclamationmark.triangle.fill")
                  .labelStyle(.titleAndIcon)
                  .font(.caption2)
                  .foregroundStyle(.orange)
                  .padding(.horizontal, 5)
                  .padding(.vertical, 1)
                  .background(Capsule().fill(Color.orange.opacity(0.15)))
                  .help(warning)
                  .accessibilityIdentifier("InstalledRow-SupportWarning-\(row.id)")
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
                    ? "Cached Hugging Face models are managed outside Rational"
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

  /// Pre-first-scan placeholder: distinguishable from the no-models
  /// empty state so the UI never claims "No models installed yet"
  /// before it has actually looked.
  private var scanningState: some View {
    VStack(spacing: 8) {
      ProgressView().controlSize(.small)
      Text("Scanning for models…")
        .font(.callout)
        .foregroundStyle(.tertiary)
    }
    .frame(maxWidth: .infinity, minHeight: 140)
    .accessibilityIdentifier("InstalledModelsScanning")
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

// MARK: - Memory guardrail dial

/// Operator control for the RAM-aware model-size guardrail fraction.
/// Persists via `GuardrailSettings` (a file in the support root) so the
/// Helper's launch-time guardrail reads the same value across the
/// sandbox boundary. Only `fraction` is exposed; the reserve term stays
/// a `ModelMemoryGuardrail.Policy` constant for v1. The live preview
/// recomputes this Mac's ceiling as the dial moves.
///
/// NOTE: this section is the model-size guardrail dial only. The
/// HF-cache model *discovery* list (`HFCacheCatalog`) lands separately;
/// when that merges it adds its own section here and does not touch this
/// one — they share only the `Models` settings tab as a host.
private struct MemoryGuardrailSection: View {
  @State private var fraction: Double = GuardrailSettings.defaultFraction
  @State private var saveError: String?

  private enum FractionChoice: Hashable {
    case preset(Double)
    case custom
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      SettingsSectionHeader(title: "Memory guardrail")
      Text("Largest model Rational will load, as a fraction of this Mac's memory after reserving headroom for the system. Higher is riskier under memory pressure.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      Picker("Preset", selection: choiceBinding) {
        ForEach(GuardrailSettings.presets, id: \.value) { preset in
          Text(preset.label).tag(FractionChoice.preset(preset.value))
        }
        Text("Custom").tag(FractionChoice.custom)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .accessibilityIdentifier("GuardrailFractionPresetPicker")

      // A plain linear Slider over the supported fraction range (snapped to
      // the 0.05 grid by `step`), flanked by the range ends and a live
      // percent readout. Percent (e.g. "65%") reads far clearer than the
      // raw "0.65" and matches how the limit preview frames the value.
      HStack(spacing: 12) {
        Text(GuardrailSettings.percentLabel(GuardrailSettings.minFraction))
          .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
        Slider(value: sliderBinding,
               in: GuardrailSettings.minFraction...GuardrailSettings.maxFraction,
               step: GuardrailSettings.step)
          .accessibilityIdentifier("GuardrailFractionSlider")
          .accessibilityLabel("Memory guardrail fraction")
          .accessibilityValue(GuardrailSettings.percentLabel(fraction))
        Text(GuardrailSettings.percentLabel(GuardrailSettings.maxFraction))
          .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
        Text(GuardrailSettings.percentLabel(fraction))
          .monospacedDigit()
          .frame(width: 48, alignment: .trailing)
          // The slider already announces its value to VoiceOver; hide the
          // duplicate visual readout so it isn't read twice.
          .accessibilityHidden(true)
      }

      Text(limitPreview)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("GuardrailLimitPreview")

      if let saveError {
        Text(saveError).font(.callout).foregroundStyle(.red)
      }
    }
    .onAppear(perform: load)
  }

  /// Highlights the matching preset, or "Custom" for an off-preset
  /// value. Selecting a preset sets the fraction; selecting "Custom"
  /// keeps the current stepper value (no-op).
  private var choiceBinding: Binding<FractionChoice> {
    Binding(
      get: { GuardrailSettings.matchingPreset(fraction).map(FractionChoice.preset) ?? .custom },
      set: { choice in
        if case .preset(let value) = choice { setFraction(value) }
      }
    )
  }

  private var sliderBinding: Binding<Double> {
    Binding(get: { fraction }, set: { setFraction($0) })
  }

  private var limitPreview: String {
    guard let physical = SystemMemory.physicalBytes() else {
      return "This Mac's memory couldn't be read — the guardrail uses a conservative default."
    }
    let policy = ModelMemoryGuardrail.Policy.recommended(
      physicalMemoryBytes: physical, fraction: fraction)
    var line = "Max model on this Mac: \(InstalledModels.formattedSize(policy.maxResolvedModelBytes))"
    if let derivation = policy.derivationSummary {
      line += "  (\(derivation))"
    }
    return line
  }

  private func load() {
    guard let root = try? PieDirs.applicationSupport() else { return }
    fraction = GuardrailSettings.loadFraction(root: root)
  }

  private func setFraction(_ value: Double) {
    // Snap to the 0.05 grid so presets stay exact and the JSON stays clean.
    let snapped = (value / GuardrailSettings.step).rounded() * GuardrailSettings.step
    let clamped = GuardrailSettings.clamp(snapped)
    fraction = clamped
    do {
      let root = try PieDirs.applicationSupport()
      try GuardrailSettings.saveFraction(clamped, root: root)
      saveError = nil
    } catch {
      saveError = "Could not save guardrail setting: \(error)"
    }
  }
}
