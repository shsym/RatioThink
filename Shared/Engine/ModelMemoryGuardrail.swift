import Foundation

/// Guardrail for obviously unsafe model loads.
///
/// The guardrail compares the *resolved artifact size* against a
/// ceiling. The ceiling is now derived from the host's physical RAM
/// rather than a fixed tripwire, so a roomy machine can run the
/// 8B-30B models the old hardcoded 8 GiB limit wrongly blocked. Tests
/// inject a fixed `Policy` to stay deterministic — the production
/// default reads RAM, but no test is allowed to depend on the real
/// host's memory. Unknown *model*-size cases still fail closed because
/// launching an unmeasurable artifact is no safer than an oversized
/// one; unknown *host RAM* falls back to the old fixed ceiling so the
/// app stays usable rather than blocking every load.
public enum ModelMemoryGuardrail {
  public struct Policy: Equatable, Sendable {
    /// Ceiling for a resolved model artifact. Production derives this
    /// from physical RAM via `recommended(physicalMemoryBytes:)`;
    /// tests inject a fixed value so a deterministic sparse-file
    /// fixture above it is rejected before `pie serve` is spawned.
    public var maxResolvedModelBytes: Int64

    /// Physical RAM the ceiling was derived from, or `nil` when a
    /// fixed ceiling was injected directly / RAM was unreadable.
    /// Carried only so the rejection message can show the
    /// "(N% of <RAM> RAM)" context an operator needs to understand
    /// why a model the machine *almost* fits was blocked.
    public var physicalMemoryBytes: Int64?

    /// Fraction of *usable* RAM the ceiling represents, or `nil` when
    /// a fixed ceiling was injected directly. Message context only.
    public var ramFraction: Double?

    /// Fixed OS/app headroom subtracted from physical RAM *before* the
    /// fraction is applied. Carried so the rejection
    /// message + picker badge can show the full derivation; `nil` for
    /// an injected fixed ceiling.
    public var reserveBytes: Int64?

    public init(maxResolvedModelBytes: Int64 = Policy.unknownRAMFallbackBytes,
                physicalMemoryBytes: Int64? = nil,
                ramFraction: Double? = nil,
                reserveBytes: Int64? = nil) {
      self.maxResolvedModelBytes = maxResolvedModelBytes
      self.physicalMemoryBytes = physicalMemoryBytes
      self.ramFraction = ramFraction
      self.reserveBytes = reserveBytes
    }

    /// Default fraction of *usable* RAM (physical − reserve) a resolved
    /// model may occupy. 0.65 lets a 64 GB host run the 8B-30B
    /// models the old fixed 8 GiB tripwire wrongly blocked, after the
    /// reserve carves out OS/app headroom.
    public static let defaultRAMFraction: Double = 0.65

    /// Fixed OS/app headroom reserved before the fraction is applied
    ///. Without it a flat `fraction × physical` allows,
    /// on an 8 GB Mac, 0.65 × 8 = 5.2 GiB — enough to greenlight a
    /// ~4.7 GiB model with zero headroom. Subtracting 6 GiB first makes
    /// that host's ceiling (8−6) × 0.65 = 1.3 GiB, correctly blocking
    /// it. Not user-exposed in v1 (only `fraction` is on the dial).
    public static let defaultReserveBytes: Int64 = 6 * 1024 * 1024 * 1024

    /// Conservative ceiling when physical RAM is unreadable: the
    /// pre- fixed tripwire. Falling back here (instead of failing
    /// closed on every load) keeps small models usable on a host whose
    /// RAM we somehow cannot read.
    public static let unknownRAMFallbackBytes: Int64 = 8 * 1024 * 1024 * 1024

    /// RAM-aware ceiling: `max(0, physicalMemoryBytes − reserveBytes) ×
    /// fraction`, rounded. The reserve is subtracted first so a small
    /// host keeps real OS/app headroom (a 4 GB host yields a 0 ceiling
    /// → blocks every model, which is correct). Falls back to
    /// `unknownRAMFallbackBytes` when RAM is unknown or non-positive.
    /// The returned policy carries RAM + fraction + reserve so callers
    /// (the rejection message, the picker's over-limit badge) can show
    /// the same comparison the guardrail enforced.
    public static func recommended(physicalMemoryBytes: Int64?,
                                   fraction: Double = defaultRAMFraction,
                                   reserveBytes: Int64 = defaultReserveBytes) -> Policy {
      guard let physical = physicalMemoryBytes, physical > 0 else {
        // Genuine failure, not the unset state: host RAM was unreadable (or
        // non-positive), so the RAM-aware ceiling can't be derived and we fall
        // back to the fixed legacy ceiling. Leave a breadcrumb — silently
        // enforcing a stale 8 GiB cap on an unknown host is the kind of mute
        // degradation an operator can't otherwise diagnose (#333).
        Log.store.warning("guardrail: physical RAM unknown (reported \(physicalMemoryBytes ?? -1, privacy: .public)); using fixed \(unknownRAMFallbackBytes, privacy: .public)-byte fallback ceiling")
        return Policy(maxResolvedModelBytes: unknownRAMFallbackBytes)
      }
      let usable = max(0, physical - reserveBytes)
      let ceiling = Int64((Double(usable) * fraction).rounded())
      return Policy(maxResolvedModelBytes: ceiling,
                    physicalMemoryBytes: physical,
                    ramFraction: fraction,
                    reserveBytes: reserveBytes)
    }

    /// Human summary of how the ceiling was derived, e.g.
    /// `"0.65 × (64.0 GB RAM − 6.0 GB reserve)"`. `nil` when this policy
    /// was injected with a fixed ceiling (no RAM context) so the
    /// message + picker simply omit the formula.
    public var derivationSummary: String? {
      guard let physical = physicalMemoryBytes,
            let fraction = ramFraction,
            let reserve = reserveBytes else { return nil }
      return String(format: "%.2f", fraction)
        + " × (\(InstalledModels.formattedSize(physical)) RAM"
        + " − \(InstalledModels.formattedSize(reserve)) reserve)"
    }
  }

  /// Production default — RAM-aware. Resolved once from the host's
  /// physical memory. Tests that exercise the size limit inject a fixed
  /// `Policy` instead of reading this (see `LaunchSpecResolver`'s
  /// `memoryPolicy` seam) so their fixtures never depend on real RAM.
  public static let defaultPolicy = Policy.recommended(
    physicalMemoryBytes: SystemMemory.physicalBytes())

  /// Production policy honoring the operator's *Settings → Models* dial
  /// fraction (persisted as `guardrail.json`). Reads the fraction FRESH
  /// each call — unlike `defaultPolicy` (a `static let` pinned to the 0.65
  /// default) — so a dial change applies with no restart. This is the
  /// single derivation the Helper's launch-time guard and the
  /// ProfileEditor picker badge both call, so the displayed "exceeds …"
  /// ceiling and the enforced gate can never disagree (#334).
  ///
  /// An absent `guardrail.json` (or unavailable support root) is the
  /// legitimate unset state → default fraction, no signal. A
  /// present-but-unreadable/corrupt file must not brick either surface, so
  /// it also falls back to the default — but logs the lost operator ceiling
  /// rather than reverting silently (the operator-visible signal lives in
  /// the Settings dial, which reads `loadFraction` directly). `root` and
  /// `physicalMemoryBytes` are injectable so tests pin a fixed RAM +
  /// fraction instead of depending on the host.
  public static func livePolicy(
    root: URL? = try? PieDirs.applicationSupport(),
    physicalMemoryBytes: Int64? = SystemMemory.physicalBytes()
  ) -> Policy {
    if root == nil {
      // Genuine failure, not the unset state: the support root itself couldn't
      // be resolved (the default arg's `try?` swallowed the throw), so we can't
      // even look for the operator's persisted fraction and fall back to the
      // default at this authoritative load-time gate. Distinct from a resolved
      // root with no `guardrail.json` (the legitimate unset case, which stays
      // silent). Breadcrumb so the lost dial isn't a mute degradation (#333).
      Log.store.warning("guardrail: application-support root unavailable; using default fraction \(GuardrailSettings.defaultFraction, privacy: .public) (operator dial not read)")
    }
    let fraction: Double
    do {
      fraction = try root.map { try GuardrailSettings.loadFraction(root: $0) }
        ?? GuardrailSettings.defaultFraction
    } catch {
      Log.store.error("guardrail.json present but unreadable/corrupt; using default fraction \(GuardrailSettings.defaultFraction, privacy: .public): \(String(describing: error), privacy: .public)")
      fraction = GuardrailSettings.defaultFraction
    }
    return Policy.recommended(physicalMemoryBytes: physicalMemoryBytes, fraction: fraction)
  }

  private struct SizeSummary {
    var totalBytes: Int64
    var largestPath: String
    var largestBytes: Int64
  }

  /// Validate a local file or resolved HF snapshot directory before it
  /// reaches `PieControlLauncher.LaunchSpec`. On failure, returns an
  /// actionable `EngineError(.memoryRisk, ...)` that can be surfaced
  /// directly by XPC/status UI layers.
  public static func validate(
    resolvedModelURL: URL,
    modelID: String,
    policy: Policy = defaultPolicy,
    fileManager: FileManager = .default
  ) -> Result<Void, EngineError> {
    let summary: SizeSummary
    do {
      summary = try summarize(resolvedModelURL: resolvedModelURL,
                              fileManager: fileManager)
    } catch {
      return .failure(memoryRiskError(
        modelID: modelID,
        path: resolvedModelURL.path,
        detail: "cannot determine model size safely (\(error.localizedDescription))"
      ))
    }

    guard summary.totalBytes <= policy.maxResolvedModelBytes else {
      let detail: String
      if policy.maxResolvedModelBytes == 0,
         let physical = policy.physicalMemoryBytes,
         let reserve = policy.reserveBytes {
        // 0-ceiling: physical RAM ≤ reserve, so no model fits. Render it
        // as a too-small-host condition, NOT "model exceeds limit 0 B"
        // (which reads like a corrupt model) —  review F4.
        // Unreachable on supported Apple Silicon (8 GiB floor →
        // (8−6)×0.65 = 1.3 GiB), rendered correctly regardless.
        detail = "this Mac's memory \(InstalledModels.formattedSize(physical)) is below the minimum"
          + " to run any model after reserving \(InstalledModels.formattedSize(reserve)) for the system"
      } else {
        var over = "resolved size \(InstalledModels.formattedSize(summary.totalBytes))"
          + " exceeds limit \(InstalledModels.formattedSize(policy.maxResolvedModelBytes))"
        if let derivation = policy.derivationSummary {
          over += " (\(derivation))"
        }
        over += "; largest artifact \(summary.largestPath) is \(InstalledModels.formattedSize(summary.largestBytes))"
        detail = over
      }
      return .failure(memoryRiskError(
        modelID: modelID,
        path: resolvedModelURL.path,
        detail: detail
      ))
    }
    return .success(())
  }

  /// Total resolved artifact size in bytes (the weight footprint), or
  /// `nil` if it can't be measured. Reuses the same traversal as
  /// `validate`; used by `KVCacheBudget` to size the KV token ceiling.
  public static func resolvedBytes(resolvedModelURL: URL,
                                   fileManager: FileManager = .default) -> Int64? {
    (try? summarize(resolvedModelURL: resolvedModelURL, fileManager: fileManager))?.totalBytes
  }

  private static func summarize(resolvedModelURL: URL,
                                fileManager: FileManager) throws -> SizeSummary {
    var isDir: ObjCBool = false
    guard fileManager.fileExists(atPath: resolvedModelURL.path, isDirectory: &isDir) else {
      throw NSError(
        domain: "ModelMemoryGuardrail",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "resolved model path does not exist"]
      )
    }

    if isDir.boolValue {
      return try summarizeDirectory(resolvedModelURL, fileManager: fileManager)
    }

    let size = try regularFileSize(resolvedModelURL, fileManager: fileManager)
    return SizeSummary(totalBytes: size,
                       largestPath: resolvedModelURL.path,
                       largestBytes: size)
  }

  private static func summarizeDirectory(_ directory: URL,
                                         fileManager: FileManager) throws -> SizeSummary {
    var traversalError: Error?
    guard let enumerator = fileManager.enumerator(
      at: directory,
      includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey],
      options: [],
      errorHandler: { url, error in
        traversalError = NSError(
          domain: "ModelMemoryGuardrail",
          code: 8,
          userInfo: [NSLocalizedDescriptionKey: "\(url.path) cannot be inspected during traversal: \(error.localizedDescription)"]
        )
        return false
      }
    ) else {
      throw NSError(
        domain: "ModelMemoryGuardrail",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "cannot enumerate resolved model directory"]
      )
    }

    var total: Int64 = 0
    var largestPath = directory.path
    var largest: Int64 = 0
    var sawFile = false

    for case let url as URL in enumerator {
      let values = try url.resourceValues(forKeys: [.isDirectoryKey])
      if values.isDirectory == true { continue }
      let size = try regularFileSize(url, fileManager: fileManager)
      sawFile = true
      let (nextTotal, overflow) = total.addingReportingOverflow(size)
      guard !overflow else {
        throw NSError(
          domain: "ModelMemoryGuardrail",
          code: 6,
          userInfo: [NSLocalizedDescriptionKey: "resolved model directory size overflowed Int64"]
        )
      }
      total = nextTotal
      if size > largest {
        largest = size
        largestPath = url.path
      }
    }

    if let traversalError {
      throw traversalError
    }

    guard sawFile else {
      throw NSError(
        domain: "ModelMemoryGuardrail",
        code: 3,
        userInfo: [NSLocalizedDescriptionKey: "resolved model directory contains no files"]
      )
    }
    return SizeSummary(totalBytes: total, largestPath: largestPath, largestBytes: largest)
  }

  private static func regularFileSize(_ url: URL,
                                      fileManager: FileManager) throws -> Int64 {
    // HF snapshots commonly expose model artifacts as symlinks into
    // `blobs/`. Resolve before reading attributes so we count the blob
    // bytes, not the symlink's short path string.
    let resolved = url.resolvingSymlinksInPath()
    let attrs: [FileAttributeKey: Any]
    do {
      attrs = try fileManager.attributesOfItem(atPath: resolved.path)
    } catch {
      throw NSError(
        domain: "ModelMemoryGuardrail",
        code: 7,
        userInfo: [NSLocalizedDescriptionKey: "\(url.path) cannot be inspected: \(error.localizedDescription)"]
      )
    }
    if let type = attrs[.type] as? FileAttributeType,
       type != .typeRegular {
      throw NSError(
        domain: "ModelMemoryGuardrail",
        code: 4,
        userInfo: [NSLocalizedDescriptionKey: "\(resolved.path) is \(type.rawValue), expected a regular file"]
      )
    }
    guard let rawSize = attrs[.size] as? NSNumber else {
      throw NSError(
        domain: "ModelMemoryGuardrail",
        code: 5,
        userInfo: [NSLocalizedDescriptionKey: "\(resolved.path) size metadata is unavailable"]
      )
    }
    return rawSize.int64Value
  }

  private static func memoryRiskError(modelID: String,
                                      path: String,
                                      detail: String) -> EngineError {
    EngineError(
      code: .memoryRisk,
      message: "memory risk: choose a smaller model or remove this model and retry; model \(modelID.debugDescription) at \(path) was not launched; \(detail)."
    )
  }
}
