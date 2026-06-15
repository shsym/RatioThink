import Foundation

/// Where the OpenAI-compatible daemon should bind its HTTP listener.
///
/// Important distinction: pie's `[server] host` config controls the
/// control-plane websocket. The user-facing Local API is the long-lived
/// inferlet daemon launched over that control plane, so this value is
/// threaded through `launch_daemon` instead of changing the control server.
public enum EngineHTTPBindMode: String, Codable, Equatable, Sendable {
  public static let localAPIExternalAccessEnabledPreferenceKey = "localAPIExternalAccessEnabled"

  /// Only processes on this Mac can connect.
  case loopback
  /// Bind all IPv4 interfaces so other reachable devices can connect.
  case external

  public var daemonHost: String {
    switch self {
    case .loopback: return "127.0.0.1"
    case .external: return "0.0.0.0"
    }
  }

  /// Host rendered in examples that describe the bind target. In-app HTTP
  /// clients still talk to `127.0.0.1`; this is for the Local API explorer.
  public var baseURLHost: String { daemonHost }

  /// Read the persisted Local API exposure preference without requiring an
  /// `AppPreferences` instance. The helper owns menu-bar Resume and
  /// auto-relaunch outside the SwiftUI app process, so its launch resolver
  /// needs the same on-disk preference at the spec boundary.
  public static func persistedLocalAPIBindMode(
    root: URL? = try? PieDirs.applicationSupport()
  ) -> EngineHTTPBindMode {
    guard let root else { return .loopback }
    return LocalAPIExposurePreference.loadBindMode(root: root)
  }
}

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

  /// Whether the security exposure toggle is actionable. Disabled during
  /// `.starting`/`.stopping` because the daemon may already be committed to a
  /// previously requested bind host and a preference-only write would under-
  /// report the listener that is about to appear or is still shutting down.
  public let externalAccessToggleEnabled: Bool

  /// Whether profile tabs are actionable. Disabled mid-transition so a
  /// profile selection cannot be accepted while an already-captured restart
  /// is moving through `.stopping`/`.starting`.
  public let profileSelectionEnabled: Bool

  /// One-word status for the header ("Running", "Starting…", …).
  public let statusLabel: String

  /// Optional sub-line: failure cause or guidance when not serving.
  public let detail: String?

  /// The authoritative served-model id from the running
  /// `EngineSessionSnapshot`, else `nil`. The Local API surface labels this
  /// as the EXACT id requests must use, so it is never approximated: no
  /// `/v1/models` re-fetch, no `activeProfile.model` fallback. A legacy
  /// snapshot with an empty `servedModelID` maps to `nil` (fail closed —
  /// the exact-id row and curl example are hidden rather than guessed).
  public let servedModelID: String?

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
    case .running(let snapshot):
      return LocalAPIState(
        phase: .serving(port: snapshot.port),
        toggleOn: true,
        toggleEnabled: true,
        externalAccessToggleEnabled: true,
        profileSelectionEnabled: true,
        statusLabel: "Running",
        detail: nil,
        servedModelID: snapshot.servedModelID.isEmpty ? nil : snapshot.servedModelID
      )
    case .starting:
      return LocalAPIState(
        phase: .starting,
        toggleOn: true,
        toggleEnabled: false,
        externalAccessToggleEnabled: false,
        profileSelectionEnabled: false,
        statusLabel: "Starting…",
        detail: "Available once the model finishes loading.",
        servedModelID: nil
      )
    case .stopping:
      return LocalAPIState(
        phase: .stopping,
        toggleOn: false,
        toggleEnabled: false,
        externalAccessToggleEnabled: false,
        profileSelectionEnabled: false,
        statusLabel: "Stopping…",
        detail: nil,
        servedModelID: nil
      )
    case .stopped:
      return LocalAPIState(
        phase: .off,
        toggleOn: false,
        toggleEnabled: hasActiveProfile,
        externalAccessToggleEnabled: true,
        profileSelectionEnabled: true,
        statusLabel: "Off",
        detail: hasActiveProfile
          ? "Turn on to start the engine and serve requests on 127.0.0.1."
          : "Choose a profile in the chat toolbar to enable the local API.",
        servedModelID: nil
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
        externalAccessToggleEnabled: true,
        profileSelectionEnabled: true,
        statusLabel: "Engine failed",
        detail: failureReason(code: code, message: message),
        servedModelID: nil
      )
    }
  }

  /// One-line human cause for a `.failed` engine status, from the shared
  /// `EngineProblem` taxonomy (#477) — the status `message` is a raw
  /// diagnostic and never primary copy.
  static func failureReason(code: EngineErrorCode, message: String) -> String {
    EngineProblem(statusCode: code, rawMessage: message).message
  }
}

/// Transactional bind-mode preference application for Local API exposure.
///
/// The serving transaction is direction-aware:
/// - enabling must persist the helper-visible exposure preference before
///   starting `0.0.0.0`, so write failures cannot expose a listener while the
///   shared source of truth still says loopback;
/// - disabling must restart loopback before persisting `false`, so a failed
///   stop/restart cannot hide an already-exposed listener.
/// Off-engine changes are safe to persist immediately because no listener can
/// be under-reported.
public struct LocalAPIBindModeRollbackError: Error, LocalizedError {
  public let startError: Error
  public let rollbackError: Error

  public init(startError: Error, rollbackError: Error) {
    self.startError = startError
    self.rollbackError = rollbackError
  }

  public var errorDescription: String? {
    "External access did not start, and the external-access preference could not be restored. The helper-visible preference may still allow external binding on a later relaunch. Start error: \(startError). Rollback error: \(rollbackError)."
  }
}

public enum LocalAPIBindModeChange {
  public static func apply(
    enabled: Bool,
    phase: LocalAPIState.Phase,
    profileID: String?,
    setPreference: (Bool) throws -> Void,
    stopEngine: () async throws -> Void,
    startEngine: (EngineHTTPBindMode) async throws -> Void
  ) async throws {
    switch phase {
    case .starting, .stopping:
      return
    case .off, .failed:
      try setPreference(enabled)
      return
    case .serving:
      break
    }

    guard let profileID, !profileID.isEmpty else { return }
    try await stopEngine()
    if enabled {
      try setPreference(true)
      do {
        try await startEngine(.external)
      } catch {
        do {
          try setPreference(false)
        } catch let rollbackError {
          throw LocalAPIBindModeRollbackError(startError: error, rollbackError: rollbackError)
        }
        throw error
      }
    } else {
      try await startEngine(.loopback)
      try setPreference(false)
    }
  }
}

/// Synchronous guard for runtime profile switches from the Local API surface.
/// It exists so the view can reject a second selection immediately, before
/// SwiftUI observes `.stopping`/`.starting` from the poll channel.
public enum LocalAPIProfileSwitchGate {
  public static func acceptSelection(
    selectedProfileID: String,
    runtimeProfileID: String?,
    state: LocalAPIState,
    restartInFlight: inout Bool
  ) -> Bool {
    guard !selectedProfileID.isEmpty else { return false }
    guard state.profileSelectionEnabled, !restartInFlight else { return false }
    guard let runtimeProfileID, runtimeProfileID != selectedProfileID else {
      return true
    }
    restartInFlight = true
    return true
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
/// for 0.1.4 (no per-endpoint configuration). If the launch contract gains
/// a knob, this type becomes a computed projection of it.
public struct EngineHTTPPosture: Equatable {
  public let bindMode: EngineHTTPBindMode
  public let loopbackOnly: Bool
  public let authenticated: Bool
  public let sendsCORSHeaders: Bool
  public let networkSummary: String
  public let authSummary: String
  public let corsSummary: String
  public let warningTitle: String?
  public let warningDetail: String?

  public static func make(bindMode: EngineHTTPBindMode) -> EngineHTTPPosture {
    EngineHTTPPosture(
      bindMode: bindMode,
      loopbackOnly: bindMode == .loopback,
      authenticated: false,
      sendsCORSHeaders: false,
      networkSummary: networkSummary(bindMode: bindMode),
      authSummary: "None. Any process that can reach the listener can call it.",
      corsSummary: "No CORS headers are sent, so browser cross-origin requests are blocked. Use curl, an SDK, or a server-side client.",
      warningTitle: bindMode == .external ? "Network exposure risk" : nil,
      warningDetail: bindMode == .external
        ? "External access binds the unauthenticated local API to 0.0.0.0. Only enable it on trusted networks, and turn it off when you are done."
        : nil
    )
  }

  private static func networkSummary(bindMode: EngineHTTPBindMode) -> String {
    switch bindMode {
    case .loopback:
      return "Loopback only (127.0.0.1). Not reachable from other devices."
    case .external:
      return "External access enabled (0.0.0.0). Other devices on reachable networks can connect to this Mac’s local API port."
    }
  }
}

/// One selectable profile tab in the Local API explorer.
public struct LocalAPIProfileOption: Equatable, Identifiable {
  public let id: String
  public let title: String
  public let modelID: String
  public let modelDisplayName: String
  public let isRuntimeProfile: Bool

  public static func make(entries: [ProfileLoadResult],
                          runtimeProfileID: String?) -> [LocalAPIProfileOption] {
    entries.compactMap { entry -> LocalAPIProfileOption? in
      // A profile with no default model (#459) can't serve the Local API, so
      // it has no endpoint to explore — skip it rather than list an empty row.
      guard entry.error == nil, let profile = entry.profile,
            let model = profile.model, !model.isEmpty else { return nil }
      return LocalAPIProfileOption(
        id: profile.id,
        title: profile.name,
        modelID: model,
        modelDisplayName: ModelDisplayName.leaf(model),
        isRuntimeProfile: profile.id == runtimeProfileID
      )
    }
  }
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
