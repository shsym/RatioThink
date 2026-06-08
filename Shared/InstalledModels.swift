import Foundation

/// Where a discovered model lives, which decides what the app may do
/// with it.
public enum CachedModelSource: String, Equatable, Sendable {
  /// Staged in Rational's app-managed models directory
  /// (`PieDirs.models()`) — imported or downloaded through the app, and
  /// deletable from it.
  case appManaged
  /// Discovered in the shared Hugging Face cache (`HF_HOME/hub`). The
  /// app does not own that directory, so these rows are read-only:
  /// reveal in Finder, never delete.
  case huggingFaceCache
}

/// One row in *Settings → Models → Installed library*. Built by
/// scanning `PieDirs.models()` for `*.gguf` files plus their `*.gguf.partial`
/// siblings (active downloads). Pure value type — no observation,
/// no FS-watcher. The Settings view re-scans on appear and after a
/// successful Add Model flow; the cost of a directory scan dominates
/// over any in-memory cache here, so the rebuild-on-event approach
/// keeps the data path trivial.
public struct InstalledModel: Equatable, Identifiable, Sendable {
  /// Stable identity. `filename` is the path RELATIVE to the models
  /// root ( review v2 F1) — a bare leaf for a top-level file, or
  /// the `<repo>/<file>` slug for a curated download nested under
  /// `<modelsRoot>/<repo>/`. This slug is exactly what the resolver
  /// joins onto the models root and what a profile stores as `model`,
  /// so the installed-list identity and engine refs agree. UI shows
  /// `displayName` (the leaf), never this raw slug.
  public var id: String { filename }

  public let filename: String

  /// Friendly leaf name for UI (last path component of `filename`).
  public var displayName: String { ModelDisplayName.leaf(filename) }

  public let url: URL
  public let sizeBytes: Int64
  public let modifiedAt: Date
  /// `true` when a `<filename>.partial` (or `<filename>.gguf.partial`)
  /// sibling is present — the file is from an interrupted download
  /// and should be flagged as "not yet downloaded" rather than ready
  /// to load.
  public let isPartial: Bool
  /// `true` when a `<filename>.unverified` sidecar is present — the
  /// download completed but its sha256 was NOT verified against HF's
  /// `X-Linked-Etag` (e.g. a resumed download that skipped the resolve
  /// 302).  F10: this makes the unverified marker DURABLE — a user
  /// who wasn't watching the live download row still sees it after a
  /// rescan/restart, instead of the file looking identical to a
  /// verified one. Written/cleared at placement by
  /// `ModelDownloader.completeDownload`.
  public let isUnverified: Bool
  /// `true` when `URLResourceValues` for the file could not be read
  /// (perms, dangling symlink, FS quirk). The UI must distinguish
  /// this from "0 bytes / 1970" — otherwise a user mis-diagnoses a
  /// permission glitch as a corrupt file and deletes it (review v2
  /// F4). `sizeBytes` / `modifiedAt` are still emitted with zero/
  /// epoch defaults so the row is renderable, but UI code is
  /// expected to suppress the size + date columns on `true`.
  public let metadataUnreadable: Bool

  /// Origin of the row. `.appManaged` for files under the app models
  /// directory (the only rows `InstalledModels.scan` produces);
  /// `.huggingFaceCache` for repos surfaced by `HFCacheCatalog`. The UI
  /// keys read-only behavior off this.
  public let source: CachedModelSource

  /// Non-nil when the row is discovered-but-NOT-LAUNCHABLE: a
  /// human-readable reason the engine cannot load this model as-is, so
  /// the UI surfaces it (the user can see the cached model) but disables
  /// selecting it as a launch target. A split GGUF
  /// (`…-NNNNN-of-MMMMM.gguf`) collapses to one row carrying this reason,
  /// because pie's portable driver loads a single `.gguf` file and has no
  /// split-file support. `nil` = launchable.
  public let unsupportedReason: String?

  public init(filename: String,
              url: URL,
              sizeBytes: Int64,
              modifiedAt: Date,
              isPartial: Bool,
              isUnverified: Bool = false,
              metadataUnreadable: Bool = false,
              source: CachedModelSource = .appManaged,
              unsupportedReason: String? = nil) {
    self.filename = filename
    self.url = url
    self.sizeBytes = sizeBytes
    self.modifiedAt = modifiedAt
    self.isPartial = isPartial
    self.isUnverified = isUnverified
    self.metadataUnreadable = metadataUnreadable
    self.source = source
    self.unsupportedReason = unsupportedReason
  }
}

public enum InstalledModelsError: Error, CustomStringConvertible, Equatable {
  case directoryUnreadable(path: String, underlying: String)
  /// A nested directory could not be read during the recursive walk
  /// ( review v3 F1). Surfaced instead of silently skipping, so a
  /// model staged under an unreadable `<repo>/` does not masquerade as
  /// "no models installed".
  case traversalFailed(path: String, underlying: String)

  public var description: String {
    switch self {
    case let .directoryUnreadable(path, underlying):
      return "InstalledModels: could not read models dir at \(path): \(underlying)"
    case let .traversalFailed(path, underlying):
      return "InstalledModels: could not traverse \(path): \(underlying)"
    }
  }
}

public enum InstalledModels {
  /// `*.gguf` extension match — case-insensitive because macOS HFS+
  /// preserves case but compares case-insensitive by default and the
  /// user could drag-drop a `MODEL.GGUF`.
  public static let modelExtension = "gguf"
  public static let partialSuffix = ".partial"
  /// Sidecar marking a placed-but-unverified GGUF ( F10). Presence
  /// next to `<file>` means the download finished with verification
  /// `.notAdvertised` (sha256 not checked). Written/cleared by
  /// `ModelDownloader.completeDownload` at placement.
  public static let unverifiedSuffix = ".unverified"

  /// Scan a directory and return the installed-models view. Sorted
  /// by descending `modifiedAt` so the most-recently added file is on
  /// top — matches what the user expects after dropping a new GGUF.
  ///
  /// Throws on directory-level failures: the models root being missing
  /// /unreadable (`.directoryUnreadable`) or a nested dir failing during
  /// the recursive walk (`.traversalFailed`, review v3 F1) — an
  /// unreadable dir must not masquerade as "no models installed". A
  /// per-file `resourceValues` failure for one row degrades that row to
  /// 0 bytes / epoch zero rather than aborting, so a single weird
  /// sidecar never empties the table.
  public static func scan(_ directory: URL,
                          fileManager: FileManager = .default) throws -> [InstalledModel] {
    let root = directory.standardizedFileURL
    // Detect directory-level failure (missing / perms) up front so the
    // throw contract is preserved; the recursive enumerator below does
    // not surface those cleanly.
    do {
      _ = try fileManager.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
      )
    } catch {
      throw InstalledModelsError.directoryUnreadable(
        path: directory.path,
        underlying: String(describing: error)
      )
    }

    //  review v2 F1: recurse so curated downloads nested at
    // `<modelsRoot>/<repo>/<file>` appear in the installed list. The
    // row's `filename` is the path RELATIVE to the models root (the
    // resolvable slug), so a nested download's identity matches what a
    // profile stores + the resolver joins.
    //
    // Review v3 F1: an `errorHandler` that aborts on an unreadable
    // nested dir (mirrors `ModelMemoryGuardrail`) so a model staged
    // under it surfaces an error rather than silently vanishing; a nil
    // enumerator throws rather than returning empty.
    var rows: [InstalledModel] = []
    var traversalError: Error?
    guard let enumerator = fileManager.enumerator(
      at: root,
      includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles],
      errorHandler: { url, error in
        traversalError = InstalledModelsError.traversalFailed(
          path: url.path, underlying: String(describing: error))
        return false  // abort the walk; surfaced below
      }
    ) else {
      throw InstalledModelsError.directoryUnreadable(
        path: directory.path,
        underlying: "enumerator(at:) returned nil")
    }
    while let url = enumerator.nextObject() as? URL {
      let name = url.lastPathComponent
      guard name.lowercased().hasSuffix(".\(modelExtension)") else { continue }
      let relativePath = Self.relativePath(of: url, under: root)
      // `<full path>.partial` sibling marks an interrupted download.
      let isPartial = fileManager.fileExists(atPath: url.path + partialSuffix)
      // `<full path>.unverified` sidecar marks a placed-but-unverified
      // download ( F10) — durable across rescan/restart.
      let isUnverified = fileManager.fileExists(atPath: url.path + unverifiedSuffix)
      let keys: Set<URLResourceKey> = [
        .isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
      ]
      do {
        var values = try url.resourceValues(forKeys: keys)
        // The enumerator yields the UNRESOLVED link node, and a direct
        // `resourceValues` read does NOT follow symlinks (verified: a
        // dangling `.gguf` link reports `isDirectory == false` and
        // `fileSize == <target-path length>`, not the model it points at).
        // So for a symlink, evaluate its TARGET via `fileExists`, which
        // DOES follow links ( v2):
        //   - unreachable target (dangling) → throw → `metadataUnreadable`
        //     row via the catch, not a phantom ~114 B clean row;
        //   - target is a directory → skip, same as a real dir;
        //   - target is a file → re-read the resolved target so the row
        //     carries the real size + mtime (not the link node's).
        // `resolvingSymlinksInPath()` walks the whole link chain.
        if values.isSymbolicLink == true {
          var targetIsDirectory: ObjCBool = false
          guard fileManager.fileExists(atPath: url.path, isDirectory: &targetIsDirectory) else {
            throw CocoaError(.fileReadNoSuchFile)  // dangling → catch flags it
          }
          if targetIsDirectory.boolValue { continue }
          values = try url.resolvingSymlinksInPath().resourceValues(forKeys: keys)
        }
        // Skip only a true directory named `X.gguf`; every non-directory
        // node — a regular file or a symlink to one — is kept. We test
        // `.isDirectoryKey`, not `.isRegularFileKey`: the latter is false
        // for an unresolved link node, so a symlinked model was silently
        // dropped before ( F1/F2). The read is a fail-loud `try`, so a
        // `resourceValues` throw falls into the catch below and emits a
        // `metadataUnreadable` row rather than a phantom clean one (
        // F1/F4) — matching scan()'s flag-don't-swallow stance and
        // `ModelMemoryGuardrail`'s skip-true-dirs guard (same logic AND
        // same fail-loud read).
        if values.isDirectory == true { continue }
        rows.append(InstalledModel(
          filename: relativePath,
          url: url,
          sizeBytes: Int64(values.fileSize ?? 0),
          modifiedAt: values.contentModificationDate ?? Date(timeIntervalSince1970: 0),
          isPartial: isPartial,
          isUnverified: isUnverified,
          metadataUnreadable: false))
      } catch {
        // Surface metadata-read failures as a flagged row rather than
        // collapsing to `0 B, 1970` (review v2 F4). The UI hides the
        // size + date columns when `metadataUnreadable == true`.
        rows.append(InstalledModel(
          filename: relativePath,
          url: url,
          sizeBytes: 0,
          modifiedAt: Date(timeIntervalSince1970: 0),
          isPartial: isPartial,
          isUnverified: isUnverified,
          metadataUnreadable: true))
      }
    }
    // Review v3 F1: an unreadable nested directory aborts the walk and
    // surfaces here rather than yielding a silently-partial list.
    if let traversalError {
      throw traversalError
    }
    // Unreadable rows have an epoch mtime — pin them to the bottom of
    // the descending-mtime sort regardless of their date stamp so they
    // don't masquerade as "old but valid". Sort stable: same-bucket
    // entries keep insertion order.
    rows.sort { lhs, rhs in
      if lhs.metadataUnreadable != rhs.metadataUnreadable {
        return !lhs.metadataUnreadable  // readable above unreadable
      }
      return lhs.modifiedAt > rhs.modifiedAt
    }
    return rows
  }

  /// Path of `url` relative to `root` ("/"-joined), e.g.
  /// `Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf` for a nested curated
  /// download or `model.gguf` for a top-level file. Falls back to the
  /// leaf when `url` is not under `root` (defensive — should not happen
  /// for enumerator output).
  static func relativePath(of url: URL, under root: URL) -> String {
    let rootComponents = root.standardizedFileURL.pathComponents
    let urlComponents = url.standardizedFileURL.pathComponents
    guard urlComponents.count > rootComponents.count,
          Array(urlComponents.prefix(rootComponents.count)) == rootComponents else {
      return url.lastPathComponent
    }
    return urlComponents.dropFirst(rootComponents.count).joined(separator: "/")
  }

  /// Human-friendly size string. We avoid `ByteCountFormatter` in
  /// RatioThinkCore tests would need to pin a locale; doing the math here
  /// keeps the formatter locale-stable and snapshot-deterministic.
  public static func formattedSize(_ bytes: Int64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    if bytes <= 0 { return "0 B" }
    var value = Double(bytes)
    var idx = 0
    while value >= 1024 && idx < units.count - 1 {
      value /= 1024
      idx += 1
    }
    if idx == 0 {
      return "\(Int(value)) \(units[idx])"
    }
    return String(format: "%.1f %@", value, units[idx])
  }
}
