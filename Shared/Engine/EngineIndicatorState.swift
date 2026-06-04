import Foundation

/// The single semantic state the toolbar engine-status pip renders,
/// folding the two independent sources of truth — `EngineStatus`
/// (engine lifecycle) and `ModelLoadCenter.State` (model load) — into
/// one value. Pure and `Equatable` so the whole state→meaning mapping is
/// unit-tested without SwiftUI, mirroring `HelperStatusItemModel.make`.
///
/// The view owns *presentation* (pip text with the model leaf + percent,
/// SF Symbols, popover rows); this enum owns *meaning* (which state, what
/// dot color, whether it banners).
public enum EngineIndicatorState: Equatable, Sendable {
  /// Engine stopped. Grey dot, no pip text — a calm idle affordance.
  case offline
  /// Engine starting / stopping, a deferred load, or helper briefly
  /// unreachable. Amber dot. `detail` carries the store's status detail
  /// (e.g. "Engine starting…" or "Helper unreachable: …").
  case starting(detail: String)
  /// A model load is in flight (foreground — outranks a running engine).
  /// `fraction` is nil for an indeterminate load.
  case loading(modelID: String, fraction: Double?)
  /// Engine running, no active/failed load. Green dot, quiet. `modelID`
  /// is the resident model when known (popover shows it + memory).
  case running(modelID: String?)
  /// A failure that must be loud: red dot + an in-window banner.
  case error(EngineIndicatorError)

  /// Colour intent for the pip dot. The view maps these to concrete
  /// `Color`s (grey / amber / neutral adaptive ink / red) — kept abstract
  /// here so the reducer stays free of SwiftUI.
  public enum Dot: Equatable, Sendable {
    case offline   // grey (secondary)
    case busy      // amber — starting or loading
    case running   // neutral adaptive label ink — quiet when healthy
    case error     // red
  }

  public var dot: Dot {
    switch self {
    case .offline:            return .offline
    case .starting, .loading: return .busy
    case .running:            return .running
    case .error:              return .error
    }
  }

  /// The error to surface in the in-window banner, or nil when nothing
  /// should banner. Only `.error` banners — loading and steady states
  /// never do (errors are the one noisy path).
  public var bannerError: EngineIndicatorError? {
    if case let .error(error) = self { return error }
    return nil
  }

  /// Build the semantic state from both sources. Pure.
  ///
  /// Precedence:
  ///  1. An active model load is foreground (`.loading` outranks a
  ///     running engine; a load `.failed` outranks everything).
  ///  2. A deferred load (`.engineNotReady`) reads as "starting".
  ///  3. Otherwise reflect the engine lifecycle.
  ///
  /// Anti-flap: a transient poll failure never reaches here as a
  /// failure — `EngineStatusStore` keeps `.starting` (and folds the
  /// reason into `engineDetail`), so helper-unreachable shows amber
  /// "starting", never a red error banner.
  public static func make(
    engine: EngineStatus,
    engineDetail: String,
    load: ModelLoadCenter.State,
    residentModelID: String?
  ) -> EngineIndicatorState {
    switch load {
    case let .loading(modelID, loaded, total, _):
      let fraction = (total > 0 && loaded <= total) ? Double(loaded) / Double(total) : nil
      return .loading(modelID: modelID, fraction: fraction)
    case let .failed(modelID, message):
      let text = message.isEmpty ? "Couldn’t load \(modelID)." : message
      return .error(EngineIndicatorError(
        kind: .loadFailed, title: "Load failed", message: text, invitesModelChoice: false
      ))
    case let .engineNotReady(_, detail):
      return .starting(detail: detail)
    case .idle, .ready, .cancelled:
      break  // fall through to the engine lifecycle
    }

    switch engine {
    case .stopped:
      return .offline
    case .starting, .stopping:
      return .starting(detail: engineDetail)
    case .running:
      return .running(modelID: residentModelID)
    case let .failed(code, message):
      return .error(EngineIndicatorError.make(code: code, message: message))
    }
  }
}

/// A failure surfaced by the engine-status pip + banner. Carries a
/// discriminated `kind` (routed from `EngineErrorCode` where available),
/// a short `title`, an actionable `message`, and whether the recovery is
/// "pick a smaller / different model" (`invitesModelChoice`) — the
/// banner appends a Model-menu hint in that case.
public struct EngineIndicatorError: Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    case engineFailed   // generic engine failure (spawn, handshake, …)
    case engineGone     // engine died after a good launch
    case loadFailed     // HTTP /v1/models/load failure
    case memoryRisk     // model too large for this Mac's safe limit
    case modelMissing   // engine has no such model
  }

  public let kind: Kind
  public let title: String
  public let message: String
  public let invitesModelChoice: Bool

  public init(kind: Kind, title: String, message: String, invitesModelChoice: Bool) {
    self.kind = kind
    self.title = title
    self.message = message
    self.invitesModelChoice = invitesModelChoice
  }

  /// Route an `EngineStatus.failed` code to a banner-ready error. The
  /// codes the GUI can act on (`memoryRisk`, `modelMissing`) invite a
  /// model choice; everything else is a plain failure.
  static func make(code: EngineErrorCode, message: String) -> EngineIndicatorError {
    switch code {
    case .memoryRisk:
      return EngineIndicatorError(
        kind: .memoryRisk, title: "Model too large",
        message: message.isEmpty ? "The model exceeds this Mac’s safe memory limit." : message,
        invitesModelChoice: true
      )
    case .engineGone:
      return EngineIndicatorError(
        kind: .engineGone, title: "Engine stopped unexpectedly",
        message: message.isEmpty ? "The engine process exited." : message,
        invitesModelChoice: false
      )
    case .modelMissing:
      return EngineIndicatorError(
        kind: .modelMissing, title: "Model not found",
        message: message.isEmpty ? "The selected model isn’t available." : message,
        invitesModelChoice: true
      )
    default:
      return EngineIndicatorError(
        kind: .engineFailed, title: "Engine failed",
        message: message.isEmpty ? "Engine error (\(code.rawValue))." : message,
        invitesModelChoice: false
      )
    }
  }
}
