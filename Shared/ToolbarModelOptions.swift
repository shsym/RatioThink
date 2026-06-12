import Foundation

/// Pure option-list builder for the chat toolbar's model menu.
///
/// The toolbar is a selection surface, not merely an engine-introspection
/// surface: it must offer every model the user can reasonably choose
/// (app-managed files, Hugging Face cache rows, the currently served engine
/// id, and the active profile default), while keeping the selected/resident
/// identity visible as the concrete model leaf rather than a generic
/// "Default" sentinel.
public enum ToolbarModelOptions {
  public struct Option: Equatable, Sendable, Identifiable {
    public let slug: String
    public let displayName: String
    public let source: CachedModelSource?
    public let isCurrent: Bool
    public let isProfileDefault: Bool
    /// Non-nil when the row is visible for context but must not be sent
    /// through the normal model-load path (partial download, split GGUF, etc.).
    public let unavailableReason: String?

    public var id: String { slug }
    public var isSelectable: Bool { unavailableReason == nil }

    public init(slug: String,
                displayName: String,
                source: CachedModelSource?,
                isCurrent: Bool,
                isProfileDefault: Bool,
                unavailableReason: String? = nil) {
      self.slug = slug
      self.displayName = displayName
      self.source = source
      self.isCurrent = isCurrent
      self.isProfileDefault = isProfileDefault
      self.unavailableReason = unavailableReason
    }
  }

  public enum SelectionAction: Equatable, Sendable {
    /// Row is visible but cannot be selected as a load target.
    case unavailable(reason: String)
    /// Request the normal coordinator path for `modelID`. `overrideAfterConfirmation`
    /// is the concrete slug to write to the chat after confirmation. Selecting
    /// any concrete row is an explicit model pick, even when that row is also
    /// the current profile default.
    case requestModel(modelID: String, overrideAfterConfirmation: String?)
  }

  public struct CurrentSummary: Equatable, Sendable {
    public let slug: String
    public let displayName: String
    /// Secondary status, e.g. "Profile default". The display name remains
    /// the concrete model leaf so collapsed controls never say only Default.
    public let annotation: String?

    public init(slug: String, displayName: String, annotation: String?) {
      self.slug = slug
      self.displayName = displayName
      self.annotation = annotation
    }
  }

  /// Three-tier `override → resident → default` precedence, NOT the
  /// pin-over-default pair (`ModelTarget.resolve`). The middle RESIDENT tier
  /// — the model the engine is actually serving — has no analogue in
  /// `ModelTarget` (which models pick → default → nil) and is what keeps the
  /// collapsed toolbar honest about what is loaded right now. Folding this
  /// into `resolve` would drop the resident tier and change what the toolbar
  /// shows, so it is intentionally a separate derivation. Only the
  /// profile-default tail carries the "Profile default" annotation.
  public static func currentSummary(modelOverride: String?,
                                    residentModelID: String?,
                                    profileDefaultModelID: String?) -> CurrentSummary? {
    if let slug = normalized(modelOverride) {
      return CurrentSummary(slug: slug,
                            displayName: ModelDisplayName.leaf(slug),
                            annotation: nil)
    }
    if let slug = normalized(residentModelID) {
      return CurrentSummary(slug: slug,
                            displayName: ModelDisplayName.leaf(slug),
                            annotation: nil)
    }
    if let slug = normalized(profileDefaultModelID) {
      return CurrentSummary(slug: slug,
                            displayName: ModelDisplayName.leaf(slug),
                            annotation: "Profile default")
    }
    return nil
  }

  public static func selectionAction(for option: Option,
                                     residentModelID: String?) -> SelectionAction {
    if let reason = option.unavailableReason {
      return .unavailable(reason: reason)
    }
    return .requestModel(
      modelID: option.slug,
      overrideAfterConfirmation: option.slug)
  }

  public static func build(discoveredModels: [InstalledModel],
                           servedModelIDs: [String],
                           profileDefaultModelID: String?,
                           modelOverride: String?,
                           residentModelID: String?) -> [Option] {
    let currentSlug = currentSummary(modelOverride: modelOverride,
                                     residentModelID: residentModelID,
                                     profileDefaultModelID: profileDefaultModelID)?.slug
    let profileDefault = normalized(profileDefaultModelID)

    var bySlug: [String: InstalledModel?] = [:]
    func add(_ slug: String?, model: InstalledModel? = nil) {
      guard let slug = normalized(slug), bySlug[slug] == nil else { return }
      bySlug[slug] = model
    }

    for model in discoveredModels {
      add(model.filename, model: model)
    }
    for id in servedModelIDs { add(id) }
    add(profileDefault)
    add(modelOverride)
    add(residentModelID)

    return bySlug.keys.sorted().map { slug in
      let model = bySlug[slug] ?? nil
      return Option(slug: slug,
                    displayName: ModelDisplayName.leaf(slug),
                    source: model?.source,
                    isCurrent: slug == currentSlug,
                    isProfileDefault: slug == profileDefault,
                    unavailableReason: unavailableReason(for: model))
    }
  }

  private static func unavailableReason(for model: InstalledModel?) -> String? {
    guard let model else { return nil }
    if model.isPartial { return "Download in progress" }
    return model.unsupportedReason
  }

  private static func normalized(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }
}
