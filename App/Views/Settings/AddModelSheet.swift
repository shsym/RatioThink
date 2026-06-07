import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// *Settings → Models → Add Model…* sheet. Three sources in one
/// surface (per ): Hugging Face search, curated catalog,
/// and drag-drop / file-picker import of a local GGUF.
///
/// The sheet does not perform downloads itself — those go through the
/// XPC helper's `ModelDownloader`. Until Phase 6 wires that, the HF
/// and curated panes surface the *intent* (selected repo+file) and
/// return it via the `onClose` callback so the table can refresh once
/// the helper-side download completes. The drop pane uses
/// `ModelImporter` which is synchronous and self-contained.
struct AddModelSheet: View {
  let modelsDirectory: URL?
  let onClose: (Outcome) -> Void

  /// One row in `Outcome.imported(successes:failures:)` — preserves
  /// both the filename the user dropped and the reason a single
  /// `ModelImporter.importFile` call rejected it. Used so multi-file
  /// drops can surface an aggregate in `ModelsSettingsTab.actionError`
  /// instead of dismissing on first success (review v3 F21).
  struct BatchFailure: Equatable {
    let filename: String
    let reason: String
  }

  /// Pure emit-gate for the multi-URL drop path: returns `true`
  /// whenever ANY URL was processed (success OR failure). Extracted
  /// so review v4 F30's gate fix is directly unit-testable
  /// (review v5 F38) without driving a real SwiftUI `onDrop`
  /// closure. The previous `test_all_failure_drop_still_emits…`
  /// only validated the formatter, not the gate.
  static func shouldEmitBatch(successes: [URL], failures: [BatchFailure]) -> Bool {
    !successes.isEmpty || !failures.isEmpty
  }

  /// Done / Esc dismissal mapping. Pre-F43, both routed straight
  /// through `.cancelled`, which the parent (`handleSheetOutcome`)
  /// early-returns on — destroying the sheet's `@State
  /// localFileError` and silently losing any caption from a failed
  /// Choose File… pick. F43 routes a captured caption through the
  /// `.imported(successes: [], failures: [...])` aggregate so it
  /// lands in `ModelsSettingsTab.actionError` like every other
  /// import diagnostic. Extracted `static` so the contract is
  /// directly unit-testable.
  static func doneOutcome(localFileError: String?) -> Outcome {
    if let reason = localFileError {
      return .imported(
        successes: [],
        failures: [BatchFailure(filename: "(file picker)", reason: reason)])
    }
    return .cancelled
  }

  /// What the sheet returned. Plumbing-only for now — Phase 6 wires
  /// the `.queueDownload` case into the helper RPC. Drag-drop and
  /// `Choose File…` imports fall through `.imported` so the caller
  /// can re-scan immediately and surface partial-failure aggregates.
  enum Outcome: Equatable {
    case cancelled
    case imported(successes: [URL], failures: [BatchFailure])
    case queueDownload(repo: String, file: String)
  }

  @Environment(\.dismiss) private var dismiss
  @State private var selectedSource: Source = .curated
  /// Caption for the Local file pane. Owned at sheet scope so it
  /// survives the `Group { switch selectedSource }` tear-down when
  /// the user clicks Curated / Search Hugging Face to investigate
  /// alternatives and then returns (review v6 F40). Previously this
  /// lived as `@State` inside `LocalFilePane`; SwiftUI evicts that
  /// storage on the pane swap and a failed Choose File… caption
  /// vanished silently.
  @State private var localFileError: String?
  /// Whole Hugging Face search session: query, results, expanded
  /// rows, per-row file listings, per-row errors, top-level status,
  /// schema-drift counts. Lifted to sheet scope so the entire
  /// session survives Picker swaps (review v7 F44). Pre-F44 these
  /// were eight separate `@State` fields on `HuggingFaceSearchPane`
  /// that all evicted when the user toggled to Local / Curated
  /// and back — query field cleared, results list empty, F22 drift
  /// banner reset, F3 per-row errors gone.
  @State private var hfSession: HFSession = HFSession()

  private enum Source: String, CaseIterable, Identifiable {
    case curated
    case search
    case local
    var id: String { rawValue }
    var title: String {
      switch self {
      case .curated: return "Curated"
      case .search:  return "Search Hugging Face"
      case .local:   return "Local file"
      }
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      // Sheet header
      HStack {
        Text("Add Model")
          .font(.title3)
          .bold()
        Spacer()
        Picker("", selection: $selectedSource) {
          ForEach(Source.allCases) { src in
            Text(src.title).tag(src)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 360)
      }
      .padding(16)
      Divider()

      // Pane
      Group {
        switch selectedSource {
        case .curated:
          CuratedCatalogPane(onPick: queueDownload)
        case .search:
          HuggingFaceSearchPane(onPick: queueDownload,
                                session: $hfSession)
        case .local:
          LocalFilePane(modelsDirectory: modelsDirectory,
                        error: $localFileError,
                        onBatch: importedBatch)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      Divider()
      // Footer
      HStack {
        Spacer()
        Button("Done") {
          // F43: route any captured Choose File… caption through
          // `.imported(successes: [], failures: …)` so it lands in
          // `actionError`. `.cancelled` early-returns in the parent
          // and would silently lose the diagnostic on dismiss.
          onClose(AddModelSheet.doneOutcome(localFileError: localFileError))
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
      }
      .padding(12)
    }
    .frame(width: 640, height: 480)
    .accessibilityIdentifier("AddModelSheet")
  }

  private func queueDownload(_ repo: String, _ file: String) {
    onClose(.queueDownload(repo: repo, file: file))
    dismiss()
  }

  /// Called once by `LocalFilePane` with the full batch outcome — for
  /// both single `Choose File…` actions and multi-URL drops. Calling
  /// `dismiss()` exactly once at this seam is what fixes review v3
  /// F21: the old `imp(_:)` path dismissed on first success and tore
  /// down the view before subsequent loop iterations could report
  /// their failure.
  private func importedBatch(successes: [URL], failures: [BatchFailure]) {
    onClose(.imported(successes: successes, failures: failures))
    dismiss()
  }
}

// MARK: - Curated pane

private struct CuratedCatalogPane: View {
  let onPick: (_ repo: String, _ file: String) -> Void

  var body: some View {
    ScrollView {
      LazyVStack(spacing: 8) {
        ForEach(CuratedModelCatalog.all) { model in
          CuratedRow(model: model) {
            onPick(model.huggingFaceRepo, model.huggingFaceFile)
          }
        }
      }
      .padding(16)
    }
  }
}

private struct CuratedRow: View {
  let model: CuratedModel
  let onAdd: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(model.displayName).font(.headline)
          if model.id == CuratedModelCatalog.recommendedModelID {
            Text("Recommended")
              .font(.caption.bold())
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(Capsule().fill(Color.accentColor.opacity(0.15)))
              .accessibilityIdentifier("CuratedRecommended-\(model.id)")
          }
        }
        Text("\(model.publisher) · \(formattedParams) · \(model.quantization)")
          .font(.callout)
          .foregroundStyle(.secondary)
        Text(model.summary)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer()
      VStack(alignment: .trailing, spacing: 6) {
        Text(InstalledModels.formattedSize(model.approximateSizeBytes))
          .foregroundStyle(.secondary)
          .monospacedDigit()
        Button("Add") { onAdd() }
          .buttonStyle(.borderedProminent)
          .accessibilityIdentifier("CuratedAdd-\(model.id)")
      }
    }
    .padding(10)
    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
  }

  private var formattedParams: String {
    if model.parameterCountBillions >= 1 {
      return String(format: "%.1fB params", model.parameterCountBillions)
    }
    return String(format: "%.0fM params", model.parameterCountBillions * 1000)
  }
}

// MARK: - HF search pane

/// Sheet-owned snapshot of the HF search pane's session. Pre-F44 the
/// equivalent eight `@State` fields lived inside
/// `HuggingFaceSearchPane`; SwiftUI tore them down whenever the user
/// toggled the Source Picker, losing the user's query, results, and
/// per-row diagnostics. Hoisting to a single `@State` on
/// `AddModelSheet` and passing as `@Binding` makes the session
/// outlive every pane tear-down (review v7 F44). The brief admitted
/// `expanded`/`fileErrors` are debatable — included here so an
/// already-expanded row with a loaded file list (or an error) stays
/// in its observed state across the swap.
struct HFSession {
  var query: String = ""
  var results: [HFSearchResult] = []
  var files: [String: [HFRepoFile]] = [:]
  var expanded: Set<String> = []
  /// Per-row file-listing error, keyed by repo. Distinct from the
  /// top-level `status` so a `listFiles` failure surfaces *inside*
  /// the expanded row instead of being swallowed by the post-results
  /// `else` branch (review v2 F3).
  var fileErrors: [String: String] = [:]
  var status: String?
  /// Schema-drift banner: non-zero when the most recent `search()`
  /// returned `droppedCount > 0`. Cleared on every new query so a
  /// drifted run is not "remembered" across recoveries (review v3
  /// F22).
  var droppedCount: Int = 0
  var rawCount: Int = 0
}

/// Internal (not `private`) so `Tests/Unit/` can construct the pane
/// with a synthesised session binding and pin the F44 contract: the
/// session storage must live on the parent so it survives the
/// Picker swap.
struct HuggingFaceSearchPane: View {
  let onPick: (_ repo: String, _ file: String) -> Void
  /// Bound to `AddModelSheet.hfSession`. A `@Binding` (not `@State`)
  /// is what makes the entire search session survive when SwiftUI
  /// tears down this view during a Source-tab swap (review v7 F44).
  @Binding var session: HFSession
  /// `inFlight` is pane-local. Its lifecycle is tied to the pane
  /// instance — `.onDisappear` cancels it when the user navigates
  /// away. Tasks that survive the cancellation handshake are gated
  /// out by the epoch comparison below before they can clobber the
  /// shared session (review v8 F47).
  @State private var inFlight: Task<Void, Never>?
  /// Monotonically incremented at every `runSearch`. Each in-flight
  /// task captures the value at start; on completion it writes to
  /// the shared session only if its captured epoch still matches.
  /// Within a single pane instance this filters every stale task
  /// — a second click of Search bumps the counter and the first
  /// task's gate fires (review v8 F47). The Task itself is also
  /// cancelled, but cancellation handshakes aren't synchronous and
  /// the producer may still emit one final write; the epoch check
  /// is the deterministic backstop.
  @State private var searchEpoch: Int = 0
  /// Per-repo `listFiles` tasks. Keyed by repo so a re-expand of
  /// the same row cancels the prior fetch instead of stacking two
  /// writes against the same `session.files[repo]` slot (review v8
  /// F49). Entries are removed when the task lands (success or
  /// failure). `.onDisappear` cancels every entry so a Picker swap
  /// mid-listFiles doesn't leave a Task writing into the shared
  /// session after the pane has been torn down.
  @State private var fileTasks: [String: Task<Void, Never>] = [:]

  private let client = HuggingFaceSearchClient()

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        TextField("Search GGUF repos on Hugging Face…", text: $session.query)
          .textFieldStyle(.roundedBorder)
          .accessibilityIdentifier("HFSearchField")
          .onSubmit(runSearch)
        Button("Search", action: runSearch)
          .keyboardShortcut(.defaultAction)
          .disabled(session.query.trimmingCharacters(in: .whitespaces).isEmpty)
      }
      .padding(12)

      Divider()
      if session.droppedCount > 0 {
        HStack(spacing: 6) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
          Text("Showing \(session.results.count) of \(session.rawCount) results — \(session.droppedCount) entry\(session.droppedCount == 1 ? "" : "s") could not be parsed (possible Hugging Face schema drift).")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .accessibilityIdentifier("HFSchemaDriftBanner")
      }
      if let status = session.status {
        Text(status)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 6) {
            ForEach(session.results) { row in
              SearchRow(
                row: row,
                expanded: session.expanded.contains(row.repo),
                files: session.files[row.repo] ?? [],
                isLoadingFiles: session.expanded.contains(row.repo)
                  && session.files[row.repo] == nil
                  && session.fileErrors[row.repo] == nil,
                fileError: session.fileErrors[row.repo],
                onToggle: { toggle(row.repo) },
                onPickFile: { file in onPick(row.repo, file) }
              )
            }
            if session.results.isEmpty {
              Text("Type a query and press Return to search.")
                .foregroundStyle(.tertiary)
                .padding()
            }
          }
          .padding(12)
        }
      }
    }
    .onDisappear {
      // Tie task lifecycle to the pane: Picker swap removes the
      // pane from the hierarchy, this fires, and every in-flight
      // network task is cancelled before it can write into the
      // shared `session` storage that now belongs to a different
      // pane (review v8 F47/F49). Cancelled tasks still race against
      // their write blocks, but the epoch and the `fileTasks` map
      // membership check below filter those out.
      inFlight?.cancel()
      inFlight = nil
      for task in fileTasks.values { task.cancel() }
      fileTasks.removeAll()
    }
  }

  private func runSearch() {
    let trimmed = session.query.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return }
    inFlight?.cancel()
    // F49 cross-search leak: pending listFiles tasks from the
    // *previous* search must be cancelled here, not just on
    // collapse / pane teardown. Without this, a user who expands
    // repo "A" under query Q1 and then runs query Q2 (which
    // happens to return a repo also named "A" from a different
    // org) would see the older listing land into `session.files
    // ["A"]` after the reset, then on expanding the new "A" the
    // `alreadyLoaded == true` short-circuit hides the cross-
    // session contamination. Cancelling at the top of runSearch
    // makes the `if Task.isCancelled` checks inside the listFiles
    // closure short-circuit the write before it can land.
    for task in fileTasks.values { task.cancel() }
    fileTasks.removeAll()
    searchEpoch &+= 1
    let epoch = searchEpoch
    var s = session
    s.status = "Searching…"
    s.expanded.removeAll()
    s.files.removeAll()
    // F48: also reset per-row errors. The prior runSearch left
    // `fileErrors` populated, so a row that errored under query A
    // would re-render its red caption against query B's results
    // until the user re-expanded it.
    s.fileErrors.removeAll()
    s.droppedCount = 0
    s.rawCount = 0
    session = s
    inFlight = Task {
      do {
        let response = try await client.search(query: trimmed)
        if Task.isCancelled { return }
        await MainActor.run {
          // F47 deterministic gate: drop the write if a newer
          // search has started. The Task.isCancelled belt-and-
          // suspenders covers the case where `.onDisappear`
          // cancelled this Task between the post-await check and
          // the MainActor hop actually running.
          if Task.isCancelled { return }
          guard epoch == searchEpoch else { return }
          var s = session
          s.results = response.results
          s.droppedCount = response.droppedCount
          s.rawCount = response.rawCount
          s.status = response.results.isEmpty
            ? "No GGUF repos match \"\(trimmed)\"."
            : nil
          session = s
        }
      } catch {
        if Task.isCancelled { return }
        await MainActor.run {
          if Task.isCancelled { return }
          guard epoch == searchEpoch else { return }
          var s = session
          s.results = []
          s.droppedCount = 0
          s.rawCount = 0
          s.status = "Search failed: \(error)"
          session = s
        }
      }
    }
  }

  private func toggle(_ repo: String) {
    if session.expanded.contains(repo) {
      session.expanded.remove(repo)
      // Collapsing a row cancels its in-flight listFiles —
      // otherwise the row would re-render with the late result
      // the next time it's expanded, ignoring whatever fresh
      // state the user established in the meantime (review v8
      // F49).
      fileTasks[repo]?.cancel()
      fileTasks.removeValue(forKey: repo)
      return
    }
    var s = session
    s.expanded.insert(repo)
    // Clear any prior error for this repo so a re-expand triggers a
    // fresh attempt rather than re-rendering the stale failure.
    s.fileErrors.removeValue(forKey: repo)
    let alreadyLoaded = s.files[repo] != nil
    session = s
    guard !alreadyLoaded else { return }
    // Defensive: a previous listFiles for this repo may still be
    // in flight (rapid toggle, or expanded → collapsed → expanded
    // before the first network round-trip). Cancel before we
    // store the replacement so the older task can't write into
    // the same `session.files[repo]` slot after we've taken over
    // (review v8 F49).
    fileTasks[repo]?.cancel()
    // Capture the current search epoch. If a new `runSearch`
    // fires while this listFiles is in flight, the closure's
    // captured `epoch` will no longer match `searchEpoch` and
    // the gate inside MainActor.run discards the write — even
    // if the cancellation handshake hasn't completed yet. This
    // is the deterministic backstop for F49's cross-search
    // contamination scenario.
    let epoch = searchEpoch
    let task = Task {
      do {
        let list = try await client.listFiles(in: repo)
        if Task.isCancelled { return }
        await MainActor.run {
          // Re-check inside the MainActor hop — the outer Task can
          // be cancelled between the post-await check and the
          // MainActor closure actually running. Without this, a
          // racing `.onDisappear` (pane swap) would let the late
          // write land in a session that now belongs to a fresh
          // pane (review v8 F49).
          if Task.isCancelled { return }
          guard epoch == searchEpoch else { return }
          var s = session
          s.files[repo] = list
          s.fileErrors.removeValue(forKey: repo)
          session = s
          fileTasks.removeValue(forKey: repo)
        }
      } catch {
        if Task.isCancelled { return }
        await MainActor.run {
          if Task.isCancelled { return }
          guard epoch == searchEpoch else { return }
          // Per-row slot — visible inside the expanded SearchRow.
          // Previously written to `status`, which is hidden by the
          // post-results `else` branch (review v2 F3).
          var s = session
          s.fileErrors[repo] = "Could not list files: \(error)"
          s.files.removeValue(forKey: repo)
          session = s
          fileTasks.removeValue(forKey: repo)
        }
      }
    }
    fileTasks[repo] = task
  }
}

private struct SearchRow: View {
  let row: HFSearchResult
  let expanded: Bool
  let files: [HFRepoFile]
  /// `true` only while `listFiles` is in flight — distinct from
  /// "loaded zero files" (`files.isEmpty && !isLoadingFiles &&
  /// fileError == nil`) and from "errored" (`fileError != nil`).
  let isLoadingFiles: Bool
  let fileError: String?
  let onToggle: () -> Void
  let onPickFile: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Button(action: onToggle) {
        HStack {
          Image(systemName: expanded ? "chevron.down" : "chevron.right")
            .foregroundStyle(.secondary)
          Text(row.repo).monospaced()
          Spacer()
          Text("↓ \(row.downloads)").foregroundStyle(.secondary).monospacedDigit()
          Text("♡ \(row.likes)").foregroundStyle(.secondary).monospacedDigit()
        }
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("HFSearchRow-\(row.repo)")

      if expanded {
        expandedBody
      }
    }
    .padding(6)
    .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.05)))
  }

  @ViewBuilder
  private var expandedBody: some View {
    if let fileError {
      Text(fileError)
        .font(.callout)
        .foregroundStyle(.red)
        .padding(.leading, 22)
        .accessibilityIdentifier("HFFileError-\(row.repo)")
    } else if isLoadingFiles {
      Text("Loading files…")
        .font(.callout)
        .foregroundStyle(.tertiary)
        .padding(.leading, 22)
    } else if files.isEmpty {
      Text("No .gguf files in this repo.")
        .font(.callout)
        .foregroundStyle(.tertiary)
        .padding(.leading, 22)
    } else {
      VStack(spacing: 2) {
        ForEach(files) { f in
          HStack {
            Text(f.path).monospaced().font(.callout)
            Spacer()
            if let size = f.sizeBytes {
              Text(InstalledModels.formattedSize(size))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .font(.callout)
            }
            Button("Add") { onPickFile(f.path) }
              .buttonStyle(.borderless)
          }
          .padding(.vertical, 2)
          .padding(.leading, 22)
        }
      }
    }
  }
}

// MARK: - Local file pane

/// Internal (not `private`) so `Tests/Unit/` can construct the pane
/// with a synthesised binding and pin the F40 contract: the caption
/// storage must live on the parent so it survives the Picker swap.
struct LocalFilePane: View {
  let modelsDirectory: URL?
  /// Bound to `AddModelSheet.localFileError`. A `@Binding` (not
  /// `@State`) is what makes the caption survive when SwiftUI tears
  /// down this view during a Source-tab swap (review v6 F40).
  @Binding var error: String?
  /// Called exactly once when the user picks a file (single) or
  /// completes a drop (one or more URLs). The pane defers the call
  /// until the entire batch is processed so review v3 F21's first-
  /// success-dismisses bug is impossible by construction.
  let onBatch: (_ successes: [URL], _ failures: [AddModelSheet.BatchFailure]) -> Void

  @State private var isTargeted: Bool = false

  var body: some View {
    VStack(spacing: 12) {
      Spacer()
      Image(systemName: "tray.and.arrow.down")
        .font(.system(size: 40))
        .foregroundStyle(.tertiary)
      Text("Drop a .gguf file here")
        .font(.headline)
      Text("Or click *Choose File…* to import from disk. The file is copied into your Rational models directory; the original is left untouched.")
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 40)
        .fixedSize(horizontal: false, vertical: true)

      Button("Choose File…") { openPanel() }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("LocalImportChooseFile")

      if let error {
        Text(error)
          .foregroundStyle(.red)
          .padding(.horizontal, 20)
          .multilineTextAlignment(.center)
      }
      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(
      RoundedRectangle(cornerRadius: 12)
        .strokeBorder(isTargeted ? Color.accentColor : Color.secondary.opacity(0.25),
                      style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: isTargeted ? [8] : [6]))
        .padding(12)
    )
    .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
      DroppedURLs.resolve(providers) { res in
        // Multi-drop policy: import every dropped `.gguf`. The full
        // batch is processed BEFORE we hand control back to the
        // sheet's `onBatch` callback, which is what actually triggers
        // `dismiss()` (review v3 F21). Failures from `loadObject`
        // become BatchFailure rows with an opaque filename.
        if res.urls.isEmpty && res.errors.isEmpty {
          error = "drop yielded no file URLs"
          return
        }
        var successes: [URL] = []
        var failures: [AddModelSheet.BatchFailure] = []
        for providerErr in res.errors {
          failures.append(AddModelSheet.BatchFailure(
            filename: "<unknown>",
            reason: "drop provider error: \(providerErr)"))
        }
        for url in res.urls {
          switch attemptImport(url) {
          case .success(let dest):
            successes.append(dest)
          case .failure(let reason):
            failures.append(AddModelSheet.BatchFailure(
              filename: url.lastPathComponent,
              reason: reason))
          }
        }
        // Surface any failures inside the pane so a user who DOES
        // notice them before dismissal sees the same string. The
        // sheet handler also surfaces them via `actionError` on the
        // Models tab — that is the canonical post-dismiss display.
        error = failures.isEmpty
          ? nil
          : "Imported \(successes.count) of \(successes.count + failures.count). Failed: " +
            failures.map { "\($0.filename) (\($0.reason))" }.joined(separator: "; ")
        // Emit when ANY URL was processed — success OR failure
        // (review v4 F30). The prior gate `!successes.isEmpty`
        // silently dropped all-failure drops: the parent never saw
        // the failures because the user would dismiss via Done and
        // `.cancelled` early-returns in `handleSheetOutcome`. The
        // gate logic lives in `AddModelSheet.shouldEmitBatch` so
        // the contract is pinnable in a unit test (review v5 F38).
        if AddModelSheet.shouldEmitBatch(successes: successes,
                                          failures: failures) {
          onBatch(successes, failures)
        }
      }
      return true
    }
  }

  private func openPanel() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = ggufTypes
    if panel.runModal() == .OK, let url = panel.url {
      // Single-pick batch is a one-element list — same `onBatch`
      // shape the drop loop uses (review v3 F21). The `.failure`
      // branch deliberately does NOT emit (review v5 F36): a
      // Choose File… failure stays in the pane with the inline
      // caption so the user can immediately retry without being
      // booted to the parent Models tab. v4 F30 over-reached when
      // it mirrored the multi-drop emit policy here; the F30 brief
      // targeted the drop loop's all-failure path only.
      switch attemptImport(url) {
      case .success(let dest):
        error = nil
        onBatch([dest], [])
      case .failure(let reason):
        error = reason
        // No onBatch — stay in pane. The Done button still emits
        // `.cancelled`, which is the right shape: the user did not
        // import anything.
      }
    }
  }

  private var ggufTypes: [UTType] {
    if let t = UTType(filenameExtension: "gguf") {
      return [t, .data]
    }
    return [.data]
  }

  enum ImportAttempt {
    case success(URL)
    case failure(reason: String)
  }

  /// Pure attempt: returns `.success(dest)` or `.failure(reason)`
  /// without touching any view state. Callers decide how to surface
  /// the outcome — `openPanel()` wraps a single-shot batch,
  /// `onDrop` aggregates many of these before calling `onBatch`
  /// exactly once (review v3 F21). Not modelled as `Result<URL,
  /// String>` because `String` is not `Error`-conforming.
  private func attemptImport(_ source: URL) -> ImportAttempt {
    guard let dir = modelsDirectory else {
      return .failure(reason: "models directory is not available")
    }
    do {
      let dest = try ModelImporter.importFile(at: source, into: dir)
      return .success(dest)
    } catch {
      return .failure(reason: String(describing: error))
    }
  }
}
