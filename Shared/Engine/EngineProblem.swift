import Foundation

/// The single normalized channel from a raw engine fault to what the user
/// sees: a high-level problem (short `title` + action-oriented `message`)
/// plus the one `recovery` action a surface should offer (#477).
///
/// Every user-facing surface (status banners, the engine pip, the send
/// gate, chat failure bubbles, the Local API card) derives its copy from
/// this type instead of forwarding the wire/launcher text, so the
/// raw-error → user-problem → next-action mapping lives in exactly one
/// place.
///
/// The raw diagnostic (stderr tail, wire `code`/`message`, `NSError`
/// dump) is preserved in `technicalDetail` — it is NEVER primary UI copy.
/// It belongs in logs (`Log.engine`, `DiagnosticLog`) or an explicit
/// technical-detail disclosure. The sources already log it before the
/// status reaches the app, so dropping it from primary copy loses no
/// diagnosability.
public struct EngineProblem: Equatable, Sendable {
  /// The one next action a surface should offer for this problem.
  /// Surfaces map these to their own affordances (banner button, prompt
  /// CTA, Model-menu hint) — the taxonomy decides WHICH action, never how
  /// it is rendered.
  public enum Recovery: Equatable, Sendable {
    /// Nothing the user can usefully do from here (e.g. a refused kill).
    case none
    /// Re-send the chat turn — the request failed, the engine is fine.
    case retrySend
    /// Transient: the engine is coming back; wait a moment and retry.
    case retryShortly
    /// Restart (or resume) the engine.
    case restartEngine
    /// Pick, download, or fix a model in Settings → Models.
    case chooseModel
    /// Restart the background helper.
    case restartHelper
  }

  public let title: String
  public let message: String
  public let recovery: Recovery
  /// Raw diagnostic text, when the source carried any. Logs / explicit
  /// technical-detail surfaces only — never primary copy.
  public let technicalDetail: String?

  public init(title: String, message: String, recovery: Recovery,
              technicalDetail: String? = nil) {
    self.title = title
    self.message = message
    self.recovery = recovery
    self.technicalDetail = technicalDetail
  }
}

// MARK: - Status axis (EngineStatus.failed)

public extension EngineProblem {
  /// Map an `EngineStatus.failed(code, message)` to user copy.
  ///
  /// The `message` on the status wire is a DIAGNOSTIC by construction —
  /// launcher errors embed stderr tails, `LaunchSpecResolver` emits
  /// path-by-path resolution traces, the guardrail emits sizing prose —
  /// so it is never used as primary copy: the curated copy comes from the
  /// `code`, and the raw message is kept only as `technicalDetail`.
  init(statusCode code: EngineErrorCode, rawMessage: String) {
    let detail = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    let technicalDetail = detail.isEmpty ? nil : detail
    switch code {
    case .modelMissing:
      self.init(
        title: "Model not installed",
        message: "The selected model isn’t downloaded. Download it in Settings → Models, or pick another model.",
        recovery: .chooseModel, technicalDetail: technicalDetail)
    case .memoryRisk:
      self.init(
        title: "Model too large",
        message: "This model exceeds this Mac’s safe memory limit. Pick a smaller model.",
        recovery: .chooseModel, technicalDetail: technicalDetail)
    case .profileMissing:
      self.init(
        title: "Profile configuration problem",
        message: "The active profile is missing or broken. Check Settings → Models.",
        recovery: .chooseModel, technicalDetail: technicalDetail)
    case .engineGone:
      self.init(
        title: "Engine stopped unexpectedly",
        message: "The engine process exited. Restart the engine to continue.",
        recovery: .restartEngine, technicalDetail: technicalDetail)
    case .killRejected:
      self.init(
        title: "Engine couldn’t be stopped",
        message: "The engine process refused to stop. Quit and reopen the app if this persists.",
        recovery: .none, technicalDetail: technicalDetail)
    case .degraded:
      self.init(
        title: "Engine helper problem",
        message: "The background helper hit a problem and needs to be restarted.",
        recovery: .restartHelper, technicalDetail: technicalDetail)
    case .handshakeTimeout:
      self.init(
        title: "The engine couldn’t start",
        message: "The engine didn’t respond while starting. Try restarting it.",
        recovery: .restartEngine, technicalDetail: technicalDetail)
    case .portUnavailable:
      self.init(
        title: "The engine couldn’t start",
        message: "The engine’s local port is already in use. Quit other copies of the app, then restart the engine.",
        recovery: .restartEngine, technicalDetail: technicalDetail)
    case .spawnFailed:
      self.init(
        title: "The engine couldn’t start",
        message: "The engine failed to start. Try restarting it.",
        recovery: .restartEngine, technicalDetail: technicalDetail)
    case .wireContractViolation:
      // An app–helper plumbing bug (type-skewed XPC reply), not an engine
      // failure — restarting the engine cannot fix it.
      self.init(
        title: "App–helper communication problem",
        message: "The app and its background helper are out of sync. Quit and reopen the app; if it keeps happening, report a bug.",
        recovery: .none, technicalDetail: technicalDetail)
    default:
      // The code discriminator moves to technicalDetail — enum case names
      // are never user copy.
      self.init(
        title: "Engine failed",
        message: "The engine hit an unexpected error. Try restarting it.",
        recovery: .restartEngine,
        technicalDetail: detail.isEmpty ? code.rawValue : "[\(code.rawValue)] \(detail)")
    }
  }
}

// MARK: - Request axis (chat send / stream failures)

public extension EngineProblem {
  /// Map a thrown send/stream error to user copy. Covers
  /// `HTTPEngineError` (envelope, FaultClass, lifecycle), `ToTStreamError`,
  /// transport errors, and an honest generic fallback. `requestedModelID`
  /// names the model in the `model_not_found` copy when known.
  init(requestError error: Error, requestedModelID: String? = nil) {
    if let engineError = error as? HTTPEngineError {
      self.init(httpEngineError: engineError, requestedModelID: requestedModelID)
      return
    }
    if let totError = error as? ToTStreamError {
      switch totError {
      case let .stream(code, message) where code == "model_not_found":
        // Parity with the HTTP path's `isModelNotFound` routing — a ToT
        // terminal frame rejecting the model is the same user problem.
        // Bracket convention keeps the wire code in the diagnostic
        // (`ToTStreamError.errorDescription` drops it when a message is
        // present).
        self.init(modelNotFound: requestedModelID,
                  technicalDetail: Self.totStreamDetail(code: code, message: message))
      case let .stream(code, message):
        self.init(
          title: "Engine couldn’t answer",
          message: "The engine couldn’t answer this message. Try sending it again.",
          recovery: .retrySend,
          technicalDetail: Self.totStreamDetail(code: code, message: message))
      case .malformedFrame:
        self.init(
          title: "Engine couldn’t answer",
          message: "The engine sent an unreadable response. Try sending again.",
          recovery: .retrySend,
          technicalDetail: totError.errorDescription)
      }
      return
    }
    if error is URLError {
      self.init(
        title: "Can’t reach the engine",
        message: "Couldn’t connect to the engine. Make sure it’s running, then try again.",
        recovery: .restartEngine,
        technicalDetail: PersistenceStatus.formatError(error))
      return
    }
    self.init(
      title: "Couldn’t send",
      message: "Something went wrong while sending this message. Try again.",
      recovery: .retrySend,
      technicalDetail: PersistenceStatus.formatError(error))
  }

  /// `[code] message` diagnostic for a ToT terminal `error` frame — the
  /// same bracket convention the status-axis default arm uses, so the
  /// wire code always survives in the log.
  private static func totStreamDetail(code: String, message: String) -> String {
    message.isEmpty ? "[\(code)]" : "[\(code)] \(message)"
  }

  /// One model-not-found mapping shared by the HTTP envelope/meta-frame
  /// path and the ToT terminal-frame path — names the model when known.
  private init(modelNotFound requestedModelID: String?, technicalDetail: String?) {
    let leaf = requestedModelID.flatMap {
      $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? nil : ModelDisplayName.leaf($0)
    }
    let message = leaf.map {
      "Model \($0) isn’t installed — download it in Settings → Models, or pick another model."
    } ?? "The selected model isn’t installed — download it in Settings → Models, or pick another model."
    self.init(title: "Model not installed", message: message,
              recovery: .chooseModel, technicalDetail: technicalDetail)
  }

  private init(httpEngineError error: HTTPEngineError, requestedModelID: String?) {
    // The raw diagnostic for every HTTP-boundary case is the error's own
    // description — the string the pre-#477 surfaces used as primary copy.
    let detail = error.description

    if error.isModelNotFound {
      self.init(modelNotFound: requestedModelID, technicalDetail: detail)
      return
    }

    if let fault = error.faultClass {
      switch fault {
      case .inFlightCrash:
        self.init(
          title: "Engine restarted",
          message: "The engine restarted while answering. Try again in a moment.",
          recovery: .retryShortly, technicalDetail: detail)
      case .hostSetup:
        self.init(
          title: "Engine couldn’t answer",
          message: "The engine couldn’t run this request. Restart the engine and try again.",
          recovery: .restartEngine, technicalDetail: detail)
      case .guestFault:
        self.init(
          title: "Engine couldn’t answer",
          message: "The engine failed while answering. Try sending again.",
          recovery: .retrySend, technicalDetail: detail)
      }
      return
    }

    switch error {
    case .engineGone:
      self.init(
        title: "Engine stopped unexpectedly",
        message: "The engine stopped while answering. Restart the engine and try again.",
        recovery: .restartEngine, technicalDetail: detail)
    case .engineNotReady:
      self.init(
        title: "Engine still starting",
        message: "The engine isn’t ready yet. Wait a moment and try again.",
        recovery: .retryShortly, technicalDetail: detail)
    case .api, .stream, .http, .nonHTTPResponse:
      self.init(
        title: "Engine couldn’t answer",
        message: "The engine couldn’t answer this message. Try sending it again.",
        recovery: .retrySend, technicalDetail: detail)
    }
  }
}
