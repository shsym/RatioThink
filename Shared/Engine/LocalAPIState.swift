import Foundation

/// Pure view-state for the "Local API" surface (#422).
///
/// The app exposes exactly ONE OpenAI-compatible HTTP endpoint: the pie
/// engine's own loopback server (`http://127.0.0.1:<port>`), the same one
/// in-app chat talks to. There is no independent "API server" to toggle —
/// the engine's HTTP listener *is* the API. So this reducer projects the
/// live `EngineStatus` into the fields the view renders, and the on/off
/// control binds to engine start/stop (see `LocalAPIView`).
///
/// Kept pure (no SwiftUI, no I/O) so the state machine is unit-tested in
/// `RatioThinkCoreTests`, mirroring `EngineIndicatorState` / `ChatStartGate`.
public struct LocalAPIState: Equatable {
  /// Coarse serving phase derived from `EngineStatus`.
  public enum Phase: Equatable {
    /// Engine running — the API is live on this loopback port.
    case serving(port: EnginePort)
    /// Engine coming up; the API will be live once the load handshake lands.
    case starting
    /// Engine shutting down.
    case stopping
    /// Engine off — the API is not served.
    case off
    /// Engine failed; `reason` is a one-line human cause.
    case failed(reason: String)
  }

  public let phase: Phase

  /// Whether the on/off control should render as "on". On while serving or
  /// starting so the control reflects the user's intent without flicker;
  /// real state catches up on the next status poll.
  public let toggleOn: Bool

  /// Whether the on/off control is actionable. Disabled mid-transition
  /// (`starting`/`stopping`) and when off with no model to start.
  public let toggleEnabled: Bool

  /// One-word status for the header ("Running", "Starting…", …).
  public let statusLabel: String

  /// Optional sub-line: failure cause or guidance when not serving.
  public let detail: String?

  /// True only while the engine is running — gates the live-stat rows
  /// (base URL, model, memory, routes, curl).
  public var isServing: Bool {
    if case .serving = phase { return true }
    return false
  }

  /// The live loopback port while serving, else `nil`.
  public var port: EnginePort? {
    if case .serving(let p) = phase { return p }
    return nil
  }

  /// Project the live engine status into Local-API view state.
  ///
  /// - Parameters:
  ///   - status: the engine lifecycle state from `EngineStatusStore`.
  ///   - hasActiveProfile: whether a profile/model is selected to start on.
  ///     When false the API can't be turned on (nothing to serve), so the
  ///     control is disabled with guidance rather than offering a start that
  ///     would immediately fail `profileMissing`.
  public static func make(status: EngineStatus, hasActiveProfile: Bool) -> LocalAPIState {
    switch status {
    case .running(let port, _):
      return LocalAPIState(
        phase: .serving(port: port),
        toggleOn: true,
        toggleEnabled: true,
        statusLabel: "Running",
        detail: nil
      )
    case .starting:
      return LocalAPIState(
        phase: .starting,
        toggleOn: true,
        toggleEnabled: false,
        statusLabel: "Starting…",
        detail: "The local API becomes available once the engine finishes loading the model."
      )
    case .stopping:
      return LocalAPIState(
        phase: .stopping,
        toggleOn: false,
        toggleEnabled: false,
        statusLabel: "Stopping…",
        detail: nil
      )
    case .stopped:
      return LocalAPIState(
        phase: .off,
        toggleOn: false,
        toggleEnabled: hasActiveProfile,
        statusLabel: "Off",
        detail: hasActiveProfile
          ? "Turn on to serve OpenAI-compatible requests on 127.0.0.1."
          : "Select a model in Settings → Models to enable the local API."
      )
    case .failed(let code, let message):
      // A retry (start) only makes sense for a recoverable failure that has
      // a model to start on. `memoryRisk`/`killRejected` aren't retryable by
      // a plain start (see `EngineErrorCode.invitesResumeRetry`).
      let canRetry = hasActiveProfile && code.invitesResumeRetry
      return LocalAPIState(
        phase: .failed(reason: failureReason(code: code, message: message)),
        toggleOn: false,
        toggleEnabled: canRetry,
        statusLabel: "Engine failed",
        detail: failureReason(code: code, message: message)
      )
    }
  }

  /// One-line human cause for a `.failed` engine status. Mirrors the
  /// honest, code-aware framing used by `EngineStatusStore.statusDetail`
  /// without dragging the store into the pure reducer.
  static func failureReason(code: EngineErrorCode, message: String) -> String {
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    switch code {
    case .memoryRisk:
      return trimmed.isEmpty ? "Model too large for available memory." : trimmed
    case .engineGone:
      return trimmed.isEmpty ? "The engine stopped unexpectedly." : trimmed
    default:
      return trimmed.isEmpty ? "Engine failed (\(code.rawValue))." : "\(trimmed) (\(code.rawValue))"
    }
  }
}

/// One OpenAI-compatible route the engine actually serves. The set is
/// static-true: `chat-apc` always registers these (see its `lib.rs` route
/// table). We surface them so a user can see what the local endpoint
/// accepts without guessing.
public struct LocalAPIRoute: Equatable, Identifiable {
  public let method: String
  public let path: String
  public let summary: String
  public var id: String { "\(method) \(path)" }

  public init(method: String, path: String, summary: String) {
    self.method = method
    self.path = path
    self.summary = summary
  }

  /// The routes `chat-apc` serves that are useful to an OpenAI-compatible
  /// client. `/v1/inferlet` (raw dispatch) is intentionally omitted — it
  /// isn't part of the standard client surface a user would call. (#469:
  /// there is no `/v1/models/load` — the served model is fixed at engine boot
  /// and read from `GET /v1/models`.)
  public static let clientFacing: [LocalAPIRoute] = [
    LocalAPIRoute(method: "POST", path: "/v1/chat/completions", summary: "Chat completions (SSE streaming)"),
    LocalAPIRoute(method: "GET", path: "/v1/models", summary: "List served models"),
    LocalAPIRoute(method: "GET", path: "/healthz", summary: "Health check"),
  ]
}

/// Read-only security posture of the engine's HTTP server. Each fact is
/// sourced from how the app actually launches the engine, NOT invented:
///  · `loopbackOnly` / `authenticated` ← `PieControlLauncher.renderConfigBody`
///    preamble (`[server] host = "127.0.0.1"`, `[auth] enabled = false`),
///    applied to every config variant. Pinned by `LocalAPIStateTests`.
///  · `sendsCORSHeaders` ← the `chat-apc` inferlet emits no CORS headers
///    (its `lib.rs`/`control` handlers set none), so browser cross-origin
///    requests are blocked by the browser.
///
/// These are constants because they are fixed by the app's launch contract
/// for 0.1.2 (no per-endpoint configuration). If the launch contract gains
/// a knob, this type becomes a computed projection of it.
public enum EngineHTTPPosture {
  public static let loopbackOnly = true
  public static let authenticated = false
  public static let sendsCORSHeaders = false

  public static let networkSummary =
    "Loopback only (127.0.0.1). Not reachable from other devices."
  public static let authSummary =
    "None. Any process on this Mac can call it. Treat it as local-only."
  public static let corsSummary =
    "No CORS headers are sent, so browser cross-origin requests are blocked. Use curl, an SDK, or a server-side client."
}

/// Pure builders for the copyable snippets the view shows. Kept here so the
/// exact wire shape (served model id, no auth header) is unit-tested.
public enum LocalAPICurl {
  /// `curl` example for the chat-completions route. `baseURL` is the engine
  /// root (`http://127.0.0.1:<port>`); `model` is the served model id from
  /// `/v1/models` (which the request `model` field MUST equal — `chat-apc`
  /// rejects a mismatch with `model_not_found`). No `Authorization` header:
  /// the engine runs with `[auth] enabled = false`.
  public static func chatCompletions(baseURL: String, model: String) -> String {
    """
    curl \(baseURL)/v1/chat/completions \\
      -H 'Content-Type: application/json' \\
      -d '{
        "model": "\(model)",
        "messages": [{"role": "user", "content": "Hello"}],
        "stream": true
      }'
    """
  }
}
