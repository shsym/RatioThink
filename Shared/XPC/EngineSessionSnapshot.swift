import Foundation

/// The one authoritative description of the engine session the Helper
/// launched — the standardized App↔Helper contract for an active engine
/// (#476). Produced Helper-side from the actual `PieControlLauncher.LaunchSpec`
/// at the moment `PieEngineHost` reaches `.running`, and carried on BOTH the
/// 1 Hz `engineStatus` poll (via `EngineStatus.running`) and the
/// `startEngine`/`restartEngine` success reply. One snapshot, two transports —
/// so the App gates sends / restarts / model UI off this value instead of
/// reconciling served-model and request limits through parallel transient
/// guesses (`/v1/models`, profile TOML, view state) that can drift.
///
/// Why these fields and not more: the ticket sketches a maximal wishlist
/// (modelRef / resolution source / timeout policy / raw default_token_limit).
/// Those are deliberately omitted — `modelRef` is a local filesystem path that
/// can leak `$HOME`, and none of the rest has an App consumer today. Add a
/// field when a real reader lands; an empty field is a wire-surface liability.
public struct EngineSessionSnapshot: Codable, Equatable, Sendable {
  /// Monotonic per-launch generation id (the host's `launchID`). Increments on
  /// every (re)start, so the App can detect that a send / restart it composed
  /// against an earlier session is now stale (the engine relaunched under it).
  public let generation: UInt64

  /// Loopback TCP port the engine's HTTP surface listens on. Same value the
  /// removed `EngineStatus.running(port:)` carried; `EnginePort` (UInt16)
  /// forbids out-of-range ports at the type level and the decoder rejects 0.
  public let port: EnginePort

  /// Active profile id the engine was started for. Drives the menu-bar
  /// "running — <profile>" copy and the profile-swap no-op short-circuit.
  public let profileID: String

  /// The model id the engine actually serves — identical to the `/v1/models`
  /// id and to the chat-completion `model` field the App must send. The
  /// resolved boot model (`explicitModel ?? profile.model`), so a no-default
  /// profile started by an explicit pick reports the pick, not "".
  public let servedModelID: String

  /// The effective per-request `max_tokens` ceiling the engine enforces for
  /// this session — what `GET /v1/models` reports as `max_output_tokens`.
  /// Derived from the LaunchSpec via `KVCacheBudget.effectiveOutputCeiling`
  /// (`min(default_token_limit ?? kvCap, kvCap)`), so the App can clamp the
  /// send-path `max_tokens` down to it the instant `.running` is observed —
  /// before the first send, with no `/v1/models` round-trip race.
  public let maxOutputTokens: Int

  /// Effective Local API daemon bind mode for this session — `loopback`
  /// (`127.0.0.1`) or `external` (`0.0.0.0`). A `nil` means the field was
  /// absent from an older helper payload, NOT confirmed loopback: the App's
  /// exposure-warning path fails safe (over-reports external) on an
  /// unconfirmed bind so it never claims loopback-only safety it can't prove.
  public let daemonBindHost: EngineHTTPBindMode?

  public init(generation: UInt64,
              port: EnginePort,
              profileID: String,
              servedModelID: String,
              maxOutputTokens: Int,
              daemonBindHost: EngineHTTPBindMode? = nil) {
    self.generation = generation
    self.port = port
    self.profileID = profileID
    self.servedModelID = servedModelID
    self.maxOutputTokens = maxOutputTokens
    self.daemonBindHost = daemonBindHost
  }

  /// Minimal-snapshot convenience for the few non-production construction
  /// sites that only know `(port, profileID)`: the legacy `PieSupervisor`
  /// projection (test-bundle-only) and the App's `PIE_TEST_ENGINE_BASE_URL`
  /// pin / inline test stub. Fills `generation = 0`, `servedModelID = ""`
  /// (no real model resolution happened on these paths), and the engine
  /// default pool ceiling. Production builds the full snapshot from the
  /// LaunchSpec in `PieEngineHost`.
  public init(port: EnginePort,
              profileID: String,
              generation: UInt64 = 0,
              servedModelID: String = "",
              maxOutputTokens: Int = KVCacheBudget.defaultPoolCapacityTokens,
              daemonBindHost: EngineHTTPBindMode? = nil) {
    self.init(generation: generation,
              port: port,
              profileID: profileID,
              servedModelID: servedModelID,
              maxOutputTokens: maxOutputTokens,
              daemonBindHost: daemonBindHost)
  }

  /// Whether `self` and `other` describe the SAME engine incarnation — same
  /// monotonic launch `generation`. A send or restart the App composed while
  /// one snapshot was live is stale once the engine relaunches under a new
  /// generation (crash auto-relaunch, profile switch, model switch): capture
  /// the generation at compose time, compare against the live snapshot, and a
  /// mismatch means "the engine moved under you." The session id the ticket
  /// calls for — port alone is insufficient (a relaunch can reuse a port).
  public func isSameSession(as other: EngineSessionSnapshot) -> Bool {
    generation == other.generation
  }
}
