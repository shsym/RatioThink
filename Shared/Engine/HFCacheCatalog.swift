import Foundation
import os

/// Read-only enumerator of the shared Hugging Face cache
/// (`<HF_HOME>/hub/models--*`). Lists every repo whose `refs/main`
/// snapshot is complete enough to launch — config + tokenizer + a
/// resolved weight present — so the profile model picker and the
/// *Settings → Models* tab can surface safetensors / GGUF models the
/// user already pulled with `huggingface-cli`, `pie model download`, or
/// another HF client. It never downloads and never writes.
///
/// Completeness is delegated to `HFCacheResolver`, which is
/// presence-only by design (it proves a resolved weight *exists*, not
/// that it is byte-complete). A partial/aborted pull leaves the hub dir
/// without a resolvable weight and is correctly skipped — it is not yet
/// a selectable model.
public enum HFCacheCatalog {
  /// Diagnostic breadcrumbs so a user who staged a model but doesn't see
  /// it can tell discovery *ran* and *why* a repo was skipped, rather
  /// than assuming it silently failed. Visible in Console.app /
  /// `log show` under this subsystem+category.
  private static let log = Logger(subsystem: "com.ratiothink.app", category: "models")

  /// Scan `hfHome/hub` and return one `InstalledModel` per complete
  /// cached repo, identified by its resolvable `<org>/<name>` slug.
  ///
  /// A missing or unreadable cache root yields an empty list rather
  /// than an error: unlike the app models directory, the HF cache is
  /// optional and its absence is normal (but it is logged so a user who
  /// *expected* cached models can see discovery ran). `sizeBytes` is the
  /// best-effort total of the snapshot's resolved files (matching what
  /// the memory guardrail sums at load time for the common, clean case);
  /// rows are sorted newest-first by snapshot mtime.
  public static func scan(hfHome: URL,
                          fileManager: FileManager = .default) -> [InstalledModel] {
    let hub = hfHome.appendingPathComponent("hub", isDirectory: true)
    guard let entries = try? fileManager.contentsOfDirectory(
      at: hub,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    ) else {
      log.info("HF cache hub absent or unreadable at \(hub.path, privacy: .public); no cached models discovered")
      return []
    }

    let resolver = HFCacheResolver(hfHome: hfHome, fileManager: fileManager)
    var rows: [InstalledModel] = []
    for entry in entries {
      guard let repo = repoID(fromCacheDirName: entry.lastPathComponent) else { continue }
      switch resolver.resolve(repo: repo) {
      case .hit(let snapshot):
        rows.append(contentsOf: models(repo: repo, snapshot: snapshot, fileManager: fileManager))
      case .invalid(let problem):
        // A repo with a `refs/main` snapshot present but missing a
        // required artifact (config / tokenizer / weight) or a dangling
        // symlink. Surface it so an incomplete pull is diagnosable, not
        // silently absent from the picker.
        log.notice("HF cache: skipping incomplete/invalid snapshot for \(repo, privacy: .public): \(problem.reason, privacy: .public)")
      case .miss:
        // Normal: a hub dir without a resolvable `refs/main` snapshot
        // (e.g. an aborted pull or a non-model cache). Debug-only — not
        // actionable.
        log.debug("HF cache: no complete snapshot for \(repo, privacy: .public); skipping")
      }
    }
    rows.sort { $0.modifiedAt > $1.modifiedAt }
    return rows
  }

  /// Expand one cached repo into its selectable rows.
  ///
  /// GGUF is the special case: pie loads a *single .gguf file*, not a
  /// directory, and a repo can hold several quants. So each distinct
  /// quant becomes its own option with the 3-segment
  /// `<org>/<name>/<file>.gguf` slug the resolver expects (it forwards
  /// `file` to `HFCacheResolver`, which returns that file as `hf_repo`)
  /// and sized to that file alone — never the sum of all quants. A quant
  /// split across `…-NNNNN-of-MMMMM.gguf` shards collapses to one option
  /// at the first shard, sized to the shard sum — see `ggufRows`.
  ///
  /// Safetensors / `.bin` / sharded repos are directory-loaded, so they
  /// stay a single 2-segment `<org>/<name>` row pointing at the
  /// snapshot dir, sized to the whole snapshot (matching what the
  /// memory guardrail sums for a directory).
  ///
  /// The two coexist: a repo shipping BOTH formats emits the per-file
  /// GGUF rows *and* the 2-segment directory row, so the safetensors
  /// variant is never silently dropped. pie's portable driver loads a
  /// snapshot *directory* via the HF-safetensors path and never consults
  /// stray `.gguf` siblings (`driver/portable/src/model.cpp`), so the
  /// directory slug is a valid, distinct choice. Only a *pure*-GGUF repo
  /// (no non-GGUF weight) omits the directory row, since loading its
  /// snapshot dir as safetensors would find no weights.
  private static func models(repo: String,
                             snapshot: URL,
                             fileManager: FileManager) -> [InstalledModel] {
    let weights = weightArtifacts(in: snapshot, fileManager: fileManager)
    let ggufs = weights.filter(\.isGGUF)
    // Collapse split-shard GGUF sets to one (unlaunchable) row; distinct
    // quants each stay their own launchable row. Empty input → [].
    var rows = ggufs.isEmpty ? [] : ggufRows(repo: repo, ggufs: ggufs)

    // Emit the directory-loaded (safetensors/.bin) row unless this is a
    // pure-GGUF repo. The `ggufs.isEmpty` arm also preserves the original
    // fallback for a snapshot the resolver hit but whose weight type we
    // don't enumerate as GGUF.
    let hasNonGGUFWeight = weights.contains { !$0.isGGUF }
    if hasNonGGUFWeight || ggufs.isEmpty {
      let metrics = snapshotMetrics(snapshot, fileManager: fileManager)
      rows.append(InstalledModel(
        filename: repo,
        url: snapshot,
        sizeBytes: metrics.size,
        modifiedAt: metrics.modified,
        isPartial: false,
        isUnverified: false,
        metadataUnreadable: false,
        source: .huggingFaceCache
      ))
    }
    return rows
  }

  /// Build the GGUF rows for a repo, collapsing split shard sets.
  ///
  /// pie's portable GGUF driver loads a SINGLE .gguf file
  /// (`Vendor/pie/driver/portable/src/gguf_archive.cpp` →
  /// `gguf_init_from_file` on one `mmap`'d file; no `-NNNNN-of-MMMMM`
  /// sibling discovery, no `split.count` metadata), so a model split
  /// across `…-NNNNN-of-MMMMM.gguf` shards has no monolithic file to
  /// point at. Emitting one row per shard makes each shard look like a
  /// whole model while `hf_repo` resolves to a single partial file.
  /// Instead we surface the set as ONE option at the FIRST shard — the
  /// llama.cpp split entry-point convention — sized to the sum of the
  /// set, and mark it UNLAUNCHABLE (`unsupportedReason`): the picker
  /// shows it (the user sees the cached model) but disables selecting it,
  /// since pie cannot assemble a split model. Unsharded `.gguf` files and
  /// distinct quants each stay their own launchable row.
  static let shardedUnsupportedReason =
    "Split GGUF (…-NNNNN-of-MMMMM): the engine loads a single .gguf file; choose a single-file quant"

  private static func ggufRows(repo: String, ggufs: [WeightArtifact]) -> [InstalledModel] {
    // Group shards together; keep first-seen group order so output is
    // deterministic (scan() re-sorts by mtime afterward). NUL-joined key
    // can't collide with real path/name bytes.
    var order: [String] = []
    var groups: [String: [WeightArtifact]] = [:]
    for gguf in ggufs {
      let key: String
      if let shard = shardComponents(ofRelativePath: gguf.relativePath) {
        key = "\(shard.directory)\u{0}\(shard.base)\u{0}\(shard.total)"
      } else {
        // Unsharded file: a unique key so it is never merged.
        key = "\u{1}\(gguf.relativePath)"
      }
      if groups[key] == nil { order.append(key) }
      groups[key, default: []].append(gguf)
    }
    return order.map { key in
      let members = groups[key]!
      // Representative = lowest shard. Indices are zero-padded, so the
      // lexicographic min of relativePath is `-00001-of-…`; for an
      // unsharded singleton it is the file itself.
      let representative = members.min { $0.relativePath < $1.relativePath } ?? members[0]
      let totalSize = members.reduce(Int64(0)) { $0 + $1.sizeBytes }
      let newest = members.map(\.modifiedAt).max() ?? representative.modifiedAt
      // A group built from the shard branch (representative leaf matches
      // the split pattern) is unlaunchable; an unsharded singleton is not.
      let unsupported = shardComponents(ofRelativePath: representative.relativePath) != nil
      return InstalledModel(
        filename: "\(repo)/\(representative.relativePath)",
        url: representative.url,
        sizeBytes: totalSize,
        modifiedAt: newest,
        isPartial: false,
        isUnverified: false,
        metadataUnreadable: false,
        source: .huggingFaceCache,
        unsupportedReason: unsupported ? Self.shardedUnsupportedReason : nil
      )
    }
  }

  /// Whether a model filename (a leaf or a `<repo>/<file>` slug) is a
  /// llama.cpp / HF split shard (`…-NNNNN-of-MMMMM.gguf`). The launch
  /// path uses this to refuse a split shard up front, so a stale or
  /// hand-authored profile pointing at one fails fast with a clear
  /// reason instead of being handed to an engine that cannot load it.
  static func isSplitShardFilename(_ filename: String) -> Bool {
    shardComponents(ofRelativePath: filename) != nil
  }

  private struct ShardComponents {
    /// Snapshot-relative directory of the shard ("" for a top-level
    /// file). Part of the group key so identically-named shards in
    /// different subdirs never merge.
    let directory: String
    /// File name before the `-NNNNN-of-MMMMM.gguf` suffix — the quant.
    let base: String
    /// `MMMMM`, the total shard count; pins the key to one split set.
    let total: String
  }

  /// Parse the llama.cpp / HF split suffix `…-NNNNN-of-MMMMM.gguf`
  /// (zero-padded 5-digit indices — the `gguf-split` and
  /// safetensors-index convention). Returns nil for an unsharded
  /// `.gguf`, so non-split files fall through as their own rows.
  private static func shardComponents(ofRelativePath relativePath: String) -> ShardComponents? {
    let segments = relativePath
      .split(separator: "/", omittingEmptySubsequences: false)
      .map(String.init)
    guard let leaf = segments.last, leaf.lowercased().hasSuffix(".gguf") else { return nil }
    let stem = Array(leaf.dropLast(".gguf".count))
    // Trailing shape "-NNNNN-of-MMMMM" is exactly 15 chars; the base
    // must be non-empty, so the stem has to be strictly longer.
    let suffixLength = 15
    guard stem.count > suffixLength else { return nil }
    let s = Array(stem.suffix(suffixLength))
    func isDigit(_ c: Character) -> Bool { c.isASCII && c.isNumber }
    guard s[0] == "-",
          s[1...5].allSatisfy(isDigit),
          s[6] == "-", s[7] == "o", s[8] == "f", s[9] == "-",
          s[10...14].allSatisfy(isDigit) else { return nil }
    let directory = segments.dropLast().joined(separator: "/")
    return ShardComponents(directory: directory,
                           base: String(stem.dropLast(suffixLength)),
                           total: String(s[10...14]))
  }

  private struct WeightArtifact {
    /// Path of the weight relative to the snapshot ("/"-joined) — the
    /// slug tail appended to `<org>/<name>`.
    let relativePath: String
    /// Snapshot-side URL (the symlink HF places in `snapshots/<rev>/`);
    /// reveal + the resolver both resolve it to the `blobs/` target.
    let url: URL
    let isGGUF: Bool
    let sizeBytes: Int64
    let modifiedAt: Date
  }

  /// Resolved weight files (`.safetensors` / `.gguf` / `.bin`) in the
  /// snapshot, sized through their symlink targets. Dangling/unreadable
  /// entries are skipped (the resolver already proved a weight exists).
  private static func weightArtifacts(in snapshot: URL,
                                      fileManager: FileManager) -> [WeightArtifact] {
    guard let enumerator = fileManager.enumerator(
      at: snapshot,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: []
    ) else {
      return []
    }
    var out: [WeightArtifact] = []
    for case let url as URL in enumerator {
      let lower = url.lastPathComponent.lowercased()
      let isGGUF = lower.hasSuffix(".gguf")
      guard isGGUF || lower.hasSuffix(".safetensors") || lower.hasSuffix(".bin") else { continue }
      let resolved = url.resolvingSymlinksInPath()
      guard let values = try? resolved.resourceValues(
        forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]),
        values.isDirectory != true else { continue }
      out.append(WeightArtifact(
        relativePath: InstalledModels.relativePath(of: url, under: snapshot),
        url: url,
        isGGUF: isGGUF,
        sizeBytes: Int64(values.fileSize ?? 0),
        modifiedAt: values.contentModificationDate ?? Date(timeIntervalSince1970: 0)
      ))
    }
    return out
  }

  /// `models--Qwen--Qwen3-0.6B` → `Qwen/Qwen3-0.6B`. Returns `nil` for
  /// non-model caches (`datasets--*`, `.locks`, stray files) and any
  /// name that does not decode to a 2-segment `<org>/<name>` repo id —
  /// the same shape `HFCacheResolver.resolve(repo:)` accepts, so a
  /// listed slug always round-trips back through the resolver.
  static func repoID(fromCacheDirName name: String) -> String? {
    let prefix = "models--"
    guard name.hasPrefix(prefix) else { return nil }
    let body = String(name.dropFirst(prefix.count))
    let segments = body.components(separatedBy: "--")
    guard segments.count == 2, segments.allSatisfy({ !$0.isEmpty }) else { return nil }
    return segments.joined(separator: "/")
  }

  private struct SnapshotMetrics {
    var size: Int64
    var modified: Date
  }

  /// Best-effort total resolved size + newest mtime of a snapshot dir.
  /// Symlinks (HF links weights into `blobs/`) are resolved before
  /// sizing; unreadable / dangling entries are skipped — the resolver
  /// already proved a weight is present, and the strict size check
  /// runs again at load time in `ModelMemoryGuardrail`.
  private static func snapshotMetrics(_ snapshot: URL,
                                      fileManager: FileManager) -> SnapshotMetrics {
    var total: Int64 = 0
    var latest = Date(timeIntervalSince1970: 0)
    guard let enumerator = fileManager.enumerator(
      at: snapshot,
      includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
      options: []
    ) else {
      return SnapshotMetrics(size: 0, modified: latest)
    }
    for case let url as URL in enumerator {
      let resolved = url.resolvingSymlinksInPath()
      guard let values = try? resolved.resourceValues(
        forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]),
        values.isDirectory != true else { continue }
      total += Int64(values.fileSize ?? 0)
      if let modified = values.contentModificationDate, modified > latest {
        latest = modified
      }
    }
    return SnapshotMetrics(size: total, modified: latest)
  }
}
