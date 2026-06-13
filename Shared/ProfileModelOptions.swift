import Foundation

/// Pure option-list builder for the *Settings → Profiles* model picker.
/// The picker offers discovered models (app-managed + Hugging Face
/// cache) and must always include the profile's current model so the
/// displayed value is never silently dropped when that model isn't
/// installed (yet / anymore). Each option carries its resolved size and
/// whether that size exceeds the model-size guardrail ceiling, so the
/// picker can disable an unloadable choice with a reason instead of
/// letting the user pick a default that can never launch on this machine.
public enum ProfileModelOptions {
  public struct Option: Equatable, Sendable, Identifiable {
    /// Resolvable slug persisted to the profile (`<org>/<name>`,
    /// `<repo>/<file>`, or a bare GGUF filename).
    public let slug: String
    /// Friendly leaf shown in the menu.
    public let displayName: String
    /// Resolved size, or `nil` when unknown (e.g. the synthesized
    /// current-model entry that isn't among the discovered set).
    public let sizeBytes: Int64?
    /// Origin, or `nil` for the synthesized current-model entry.
    public let source: CachedModelSource?
    /// `true` when `sizeBytes` exceeds the guardrail ceiling — the
    /// picker renders these disabled with a "too large" reason.
    public let isOverLimit: Bool
    /// Non-nil when the discovered model is NOT launchable (a split
    /// GGUF). The picker shows the option but disables selecting it and
    /// surfaces this reason — like `isOverLimit`, but the engine can
    /// never load it regardless of host RAM.
    public let unsupportedReason: String?
    /// Advisory-only cache support warning. Unlike `unsupportedReason`,
    /// this does not make the option unloadable; it tells the user this
    /// HF-cache discovery is outside RatioThink's curated support list.
    public let supportWarning: String?
    /// True when the slug is in RatioThink's curated, engine-validated
    /// catalog.
    public let isCuratedEngineSupported: Bool
    /// `true` for the profile's current model (checkmarked).
    public let isCurrent: Bool
    /// `true` when the discovered model was installed without a verified
    /// sha256 (#580 #5 — surfaced as a shield in the picker, mirroring the
    /// Settings table). The synthesized current entry (not discovered) is
    /// never unverified.
    public let isUnverified: Bool
    /// Structured identity parsed from `slug` (#580) — the picker renders
    /// `parts.base` prominent + `parts.quant` as a tag, and groups rows by
    /// `parts.groupKey`. Derived from the slug so it always agrees with it.
    public let parts: ModelNameParts

    public var id: String { slug }

    public init(slug: String,
                displayName: String,
                sizeBytes: Int64?,
                source: CachedModelSource?,
                isOverLimit: Bool,
                isCurrent: Bool,
                unsupportedReason: String? = nil,
                isUnverified: Bool = false,
                supportWarning: String? = nil,
                isCuratedEngineSupported: Bool = false) {
      self.slug = slug
      self.displayName = displayName
      self.sizeBytes = sizeBytes
      self.source = source
      self.isOverLimit = isOverLimit
      self.isCurrent = isCurrent
      self.unsupportedReason = unsupportedReason
      self.isUnverified = isUnverified
      self.supportWarning = supportWarning
      self.isCuratedEngineSupported = isCuratedEngineSupported
      self.parts = ModelNameParts.parse(slug)
    }
  }

  /// Build the picker's option list. `models` is the discovered set
  /// (app-managed first, then HF cache); duplicate slugs keep the first
  /// (app-managed) entry, matching the resolver's app-staged-first
  /// precedence. `current` (when non-empty) is always present, even if
  /// not discovered. `limitBytes` is the model-size guardrail ceiling
  /// (`nil` disables over-limit flagging). Sorted by slug for stable,
  /// locale-free ordering.
  public static func build(models: [InstalledModel],
                           current: String,
                           limitBytes: Int64?) -> [Option] {
    // Dedup by IDENTITY = the full resolvable slug (review v2 F2): an
    // app-managed download and an HF-cache copy of the SAME `<repo>/<file>`
    // slug collapse to one row (app-managed first wins, the resolver's
    // app-staged-first precedence); distinct files that merely share a leaf
    // stay apart. Quant distinctness (Q4 vs Q8) falls out for free.
    let currentIdentity = current.isEmpty ? nil : ModelNameParts.parse(current).identity
    var bySlug: [String: InstalledModel] = [:]
    var seenIdentity = Set<String>()
    var order: [String] = []
    for model in models {
      let identity = ModelNameParts.parse(model.filename).identity
      guard seenIdentity.insert(identity).inserted else { continue }
      bySlug[model.filename] = model
      order.append(model.filename)
    }
    // The profile's current model must always be visible + checkmarked, even
    // when not installed. Presence-check by IDENTITY (review v2 F3): only
    // synthesize a "Not downloaded" current row when NO discovered row shares
    // its identity. When one does, that surviving row is marked current below
    // (isCurrent is identity-based) — no duplicate, no false "Not downloaded".
    if let currentIdentity, !seenIdentity.contains(currentIdentity) {
      order.append(current)
    }

    return order
      .map { slug -> Option in
        let model = bySlug[slug]
        // #3: a slug that is NOT among the discovered set is the
        // synthesized current-model entry for a default that isn't
        // installed on this Mac. Mark it "Not downloaded" so the picker
        // shows WHY it can't run (and a non-current one is disabled),
        // instead of offering a clean-looking choice that resolves to the
        // engine's noisy `model_not_found` at load time (#2). A discovered
        // model keeps its own reason (e.g. a split GGUF).
        let reason = model?.unsupportedReason ?? (model == nil ? "Not downloaded" : nil)
        return Option(
          slug: slug,
          displayName: ModelDisplayName.leaf(slug),
          sizeBytes: model?.sizeBytes,
          source: model?.source,
          isOverLimit: isOverLimit(sizeBytes: model?.sizeBytes, limitBytes: limitBytes),
          // Identity-based (review v2 F3): a discovered row whose identity
          // matches the current model is marked current even when the profile
          // persisted a different-but-equivalent slug, so the checkmark never
          // splits onto a synthesized duplicate.
          isCurrent: ModelNameParts.parse(slug).identity == currentIdentity,
          unsupportedReason: reason,
          isUnverified: model?.isUnverified ?? false,
          supportWarning: model?.supportWarning,
          isCuratedEngineSupported: model?.isCuratedEngineSupported ?? CuratedModelCatalog.isCuratedModelSlug(slug)
        )
      }
      .sorted { $0.slug < $1.slug }
  }

  /// A model is over the limit only when both its size and the ceiling
  /// are known. Unknown size (synthesized current entry, unreadable
  /// metadata) is never flagged — the load-time guardrail stays the
  /// authoritative gate.
  static func isOverLimit(sizeBytes: Int64?, limitBytes: Int64?) -> Bool {
    guard let sizeBytes, let limitBytes else { return false }
    return sizeBytes > limitBytes
  }
}
