import Foundation

/// THE launch/load-target derivation (#497): which model a blocked-send
/// surface should name and a Load tap should boot — the chat's pinned
/// selection (`Chat.modelID`) when present, else the active profile's
/// default. Mirrors the boot path's precedence
/// (`startEngineForSelectedProfile` boots `chats.first?.modelID`, falling
/// back to the profile default), so the prompt's chip, download CTA, Load
/// action, missing-model banner, and launch ask all name the model the tap
/// will actually boot.
///
/// `source` travels with the id so copy stays honest: a user-pinned
/// selection is never described as "this profile's default model". Carrying
/// the pair (rather than a bare slug, the pre-#497 `gateModelID`) makes
/// that misdescription unrepresentable — a surface either has the target
/// with its provenance or has nothing.
public struct ModelTarget: Equatable, Sendable {
  public enum Source: Equatable, Sendable {
    /// The user pinned this model for the chat (`Chat.modelID`).
    case selected
    /// Falls back to the active profile's stored default model.
    case profileDefault
  }

  public let modelID: String
  public let source: Source

  public init(modelID: String, source: Source) {
    self.modelID = modelID
    self.source = source
  }

  /// Selection intent beats the profile default; blank/whitespace ids
  /// count as absent (same trim the pre-#497 `gateModelID` applied).
  /// Nil means there is genuinely nothing to load (`noDefault`).
  public static func resolve(selectedModelID: String?,
                             profileDefault: String?) -> ModelTarget? {
    if let pick = selectedModelID,
       !pick.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return ModelTarget(modelID: pick, source: .selected)
    }
    if let d = profileDefault,
       !d.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return ModelTarget(modelID: d, source: .profileDefault)
    }
    return nil
  }
}

/// Helper-observed engine state that matters before constructing a request.
///
/// The app's `ModelTarget` is user intent; this value is what the helper /
/// running engine can actually serve. Keeping them separate makes the
/// send-time preflight explicit: request construction may use engine-bound
/// constraints such as the `max_tokens` ceiling only when they came from the
/// same resident model the app intends to target.
public struct EngineResidentState: Equatable, Sendable {
  public let modelID: String?
  public let maxOutputTokensCeiling: Int?

  public init(modelID: String?, maxOutputTokensCeiling: Int? = nil) {
    self.modelID = modelID
    self.maxOutputTokensCeiling = maxOutputTokensCeiling
  }
}

/// Desired-vs-resident request preflight contract.
///
/// `resolvedModelID` is non-nil only when the app's single target derivation
/// (`ModelTarget.resolve`) matches the helper-observed resident model. Any
/// mismatch means the caller must synchronize the engine first rather than
/// sending a request that the engine will reject with `model_not_found`.
public struct EngineRequestSync: Equatable, Sendable {
  public let target: ModelTarget?
  public let resident: EngineResidentState

  public init(target: ModelTarget?, resident: EngineResidentState) {
    self.target = target
    self.resident = resident
  }

  public var resolvedModelID: String? {
    guard let target,
          let residentModelID = resident.modelID,
          target.modelID == residentModelID else {
      return nil
    }
    return target.modelID
  }

  public var maxOutputTokensCeiling: Int? {
    resolvedModelID == nil ? nil : resident.maxOutputTokensCeiling
  }
}
