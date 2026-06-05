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
    /// `true` for the profile's current model (checkmarked).
    public let isCurrent: Bool

    public var id: String { slug }

    public init(slug: String,
                displayName: String,
                sizeBytes: Int64?,
                source: CachedModelSource?,
                isOverLimit: Bool,
                isCurrent: Bool,
                unsupportedReason: String? = nil) {
      self.slug = slug
      self.displayName = displayName
      self.sizeBytes = sizeBytes
      self.source = source
      self.isOverLimit = isOverLimit
      self.isCurrent = isCurrent
      self.unsupportedReason = unsupportedReason
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
    var bySlug: [String: InstalledModel] = [:]
    var order: [String] = []
    for model in models where bySlug[model.filename] == nil {
      bySlug[model.filename] = model
      order.append(model.filename)
    }
    if !current.isEmpty, bySlug[current] == nil {
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
          isCurrent: slug == current,
          unsupportedReason: reason
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
