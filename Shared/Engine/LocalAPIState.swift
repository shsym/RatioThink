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

/// Synchronous decision for runtime profile switches from the Local API
/// surface. It exists so the view can resolve a selection immediately, before
/// SwiftUI observes `.stopping`/`.starting` from the poll channel.
///
/// #654: a profile switch only needs an engine RELAUNCH when it changes the
/// SERVED MODEL. v1 pie binds just the model at `pie serve` boot
/// (`LaunchSpecResolver.LaunchSpec` carries the model, not sampling /
/// speculation / constraint / tree-of-thought — those are per-request fields in
/// the `/v1/chat/completions` body). So switching to a DIFFERENT profile that
/// serves the SAME model is a marker-only change: the engine stays up and the
/// new profile's parameters apply per request. Only a model change is a
/// lifecycle event. The pre-#654 gate relaunched on any profile-id change,
/// which is the observed "switching profiles restarts the engine" defect.
public enum LocalAPIProfileSwitchGate {
  /// What the view should do for a requested selection.
  public enum Outcome: Equatable {
    /// Not actionable right now (empty id, selection disabled, or a restart is
    /// already in flight) — ignore the selection.
    case reject
    /// Accept the selection and persist the active-profile marker, but take NO
    /// engine action: either nothing is running, the running profile was
    /// re-selected, or the new profile serves the model already loaded.
    case selectOnly
    /// Accept the selection AND relaunch the engine bound to the new model.
    case restart
  }

  /// Decide the outcome of selecting `selectedProfileID`.
  ///
  /// - Parameters:
  ///   - selectedModelID: the model the newly selected profile serves.
  ///   - runtimeProfileID: the profile the running engine booted with (`nil`
  ///     when not running).
  ///   - runtimeModelID: the model the running engine actually serves
  ///     (`EngineSessionSnapshot.servedModelID`); compared against
  ///     `selectedModelID` to detect a same-model switch.
  ///   - restartInFlight: flipped to `true` only when the outcome is `.restart`,
  ///     so the view can synchronously reject a second switch before the async
  ///     stop/start cycle is observable on the poll channel.
  public static func decide(
    selectedProfileID: String,
    selectedModelID: String?,
    runtimeProfileID: String?,
    runtimeModelID: String?,
    state: LocalAPIState,
    restartInFlight: inout Bool
  ) -> Outcome {
    guard !selectedProfileID.isEmpty else { return .reject }
    guard state.profileSelectionEnabled, !restartInFlight else { return .reject }
    // Not running, or re-selecting the running profile: marker-only, no engine
    // action.
    guard let runtimeProfileID, runtimeProfileID != selectedProfileID else {
      return .selectOnly
    }
    // Running a DIFFERENT profile that serves the SAME model: the engine binds
    // only the model at boot, so there is nothing to relaunch — the new
    // profile's params apply per request.
    if let selectedModelID, let runtimeModelID, selectedModelID == runtimeModelID {
      return .selectOnly
    }
    restartInFlight = true
    return .restart
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
  ///
  /// #654: the chat-completions summary reflects the panel's streaming toggle —
  /// `chat-apc` serves BOTH `stream: true` (SSE) and `stream: false` (single
  /// JSON body), branching on the request's `stream` field
  /// (`handle_streaming` / `handle_non_streaming`).
  public static func clientFacing(streaming: Bool = true) -> [LocalAPIRoute] {
    [
      LocalAPIRoute(method: "POST", path: "/v1/chat/completions",
                    summary: chatCompletionsSummary(streaming: streaming)),
      LocalAPIRoute(method: "GET", path: "/v1/models", summary: "List served models"),
      LocalAPIRoute(method: "GET", path: "/healthz", summary: "Health check"),
    ]
  }

  /// Human summary for the chat-completions route, reflecting the streaming
  /// choice the user toggled in the panel.
  public static func chatCompletionsSummary(streaming: Bool) -> String {
    streaming ? "Chat completions (SSE streaming)" : "Chat completions (single JSON response)"
  }
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
/// for 0.1.5 (no per-endpoint configuration). If the launch contract gains
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

  /// Whether selecting this profile means the engine is serving it live right
  /// now — the basis of the "Running" badge.
  ///
  /// #663: this is model-aware, not profile-id-aware. The pre-#663 rule was a
  /// strict `profile.id == runtimeProfileID` (the profile the engine BOOTED
  /// with). But #654 made a same-model profile switch a marker-only change
  /// (`LocalAPIProfileSwitchGate.decide` → `.selectOnly`): the engine stays up
  /// bound to the same model and the new profile's params apply per request
  /// (insight:513). Under the old rule the badge vanished after such a switch
  /// even though the engine was serving the selected profile's model live. So
  /// a profile is "served live" when it booted the engine OR when it serves
  /// the model the running engine actually serves. The boot-id arm keeps the
  /// badge for a legacy snapshot whose `servedModelID` is empty (`nil` here).
  public let isServedLive: Bool

  public static func make(entries: [ProfileLoadResult],
                          runtimeProfileID: String?,
                          runtimeServedModelID: String? = nil) -> [LocalAPIProfileOption] {
    entries.compactMap { entry -> LocalAPIProfileOption? in
      // A profile with no default model (#459) can't serve the Local API, so
      // it has no endpoint to explore — skip it rather than list an empty row.
      guard entry.error == nil, let profile = entry.profile,
            let model = profile.model, !model.isEmpty else { return nil }
      let bootedThisProfile = profile.id == runtimeProfileID
      let servesRunningModel =
        (runtimeServedModelID.map { !$0.isEmpty && $0 == model }) ?? false
      return LocalAPIProfileOption(
        id: profile.id,
        title: profile.name,
        modelID: model,
        modelDisplayName: ModelDisplayName.leaf(model),
        isServedLive: bootedThisProfile || servesRunningModel
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
  public static func chatCompletions(baseURL: String, model: String, streaming: Bool = true) -> String {
    """
    curl \(baseURL)/v1/chat/completions \\
      -H 'Content-Type: application/json' \\
      -d '{
        "model": "\(model)",
        "messages": [{"role": "user", "content": "Hello"}],
        "stream": \(streaming)
      }'
    """
  }
}
