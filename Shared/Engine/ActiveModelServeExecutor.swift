import Foundation
import Combine
import os

/// The status-aware executor a model PICK routes through (#469), plus the
/// deferred-pick queue (#488).
///
/// v1 pie binds the served model at `pie serve` boot, so changing the served
/// model is an engine LIFECYCLE event — start a stopped engine bound to the
/// pick, rebuild a running one onto a different pick, or no-op when it is
/// already resident — NOT a `/v1/models/load` (the endpoint is gone). The
/// routing decision is `ActiveModelLaunchPolicy.decide`; this class executes
/// it against the live `EngineStatusStore` / `ModelLoadCenter`.
///
/// #488: `decide` returns `.deferBusy` while the engine is mid-transition
/// (`.starting` / `.stopping`) — correct, the in-flight launch owns the
/// engine — but the pick must not silently die there. The executor QUEUES it
/// (`deferredPick`, coalesced to the latest pick) and re-serves it when the
/// engine next reaches a settled state (`.running` / `.stopped` / `.failed`).
/// The re-serve re-runs the policy against the settled state, so it converges
/// honestly: a settle already serving the pick drops it (`alreadyResident`),
/// a terminal failure drops it (`blockedTerminal` — the failure banner owns
/// the reason), a settle on a different model restarts onto the pick, a
/// stopped settle starts bound to it, and an engine that went busy again
/// simply re-queues.
///
/// A deferred re-serve has no awaiting caller (the `startLoad` Task that
/// carried the original pick returned when the pick was queued), so its
/// failure is reported through `onDeferredServeFailure` — production wires it
/// to `ProfileSwapCoordinator.reportServeFailure` so the toolbar copy is
/// identical to a direct pick's failure.
@MainActor
public final class ActiveModelServeExecutor: ObservableObject {
  /// A coalesced pick waiting for the engine to settle. Latest wins: a
  /// fresh `serve` (queued or executed) supersedes whatever was queued.
  public struct Pick: Equatable {
    public let modelID: String
    public let profileID: String

    public init(modelID: String, profileID: String) {
      self.modelID = modelID
      self.profileID = profileID
    }
  }

  /// The pick queued behind a transitional engine, or `nil`. `@Published`
  /// so a surface can render "applies when the engine settles" if it wants
  /// to; the queue/apply behavior does not depend on anyone observing it.
  @Published public private(set) var deferredPick: Pick?

  /// Failure sink for a deferred re-serve (which has no awaiting caller to
  /// throw to). Wired by `RatioThinkApp` to
  /// `ProfileSwapCoordinator.reportServeFailure`; default no-op keeps unit
  /// construction trivial.
  public var onDeferredServeFailure: (_ modelID: String, _ error: Error) -> Void = { _, _ in }

  private let engineStatus: EngineStatusStore
  private let modelLoad: ModelLoadCenter
  private var cancellable: AnyCancellable?
  private static let log = Logger(subsystem: "com.ratiothink.app", category: "model-serve")

  public init(engineStatus: EngineStatusStore, modelLoad: ModelLoadCenter) {
    self.engineStatus = engineStatus
    self.modelLoad = modelLoad
    // Re-serve the queued pick when the engine settles. `$status` is
    // change-guarded at the store (`setStatusAndTrackStarting`), so this
    // fires per transition, not per poll; the initial-value emission on
    // subscription is harmless (the queue is empty at init).
    cancellable = engineStatus.$status
      .sink { [weak self] status in
        guard let self else { return }
        guard Self.isSettled(status), let pick = self.deferredPick else { return }
        self.deferredPick = nil
        Self.log.info("engine settled — serving deferred pick model=\(pick.modelID, privacy: .public) profile=\(pick.profileID, privacy: .public)")
        Task { @MainActor in
          do {
            try await self.serve(modelID: pick.modelID, profileID: pick.profileID)
          } catch {
            Self.log.error("deferred serve failed model=\(pick.modelID, privacy: .public) profile=\(pick.profileID, privacy: .public): \(String(describing: error), privacy: .public)")
            self.onDeferredServeFailure(pick.modelID, error)
          }
        }
      }
  }

  /// Make the engine serve `modelID` on `profileID` — the `serveModel`
  /// executor `ProfileSwapCoordinator` routes every confirmed/direct pick
  /// through. Throws the start/restart failure to the caller (which surfaces
  /// it via `serveModelError`); a pick against a transitional engine is
  /// queued, not dropped (#488).
  public func serve(modelID: String, profileID: String) async throws {
    // The newest pick is the user's intent — it supersedes any queued one,
    // whether this serve executes or re-queues (coalesce-to-latest).
    deferredPick = nil
    switch ActiveModelLaunchPolicy.decide(
      modelID: modelID,
      status: engineStatus.status,
      residentModelID: modelLoad.residentModelID
    ) {
    case .startEngine(let model):
      try await engineStatus.startEngine(profileID: profileID, modelOverride: model)
    case .restartEngine(let model):
      try await engineStatus.restartEngine(profileID: profileID, modelOverride: model)
    case .alreadyResident, .blockedTerminal:
      // Already serving the pick, or a terminal failure the banner owns —
      // no (re)launch. The indicator/banner already reflect the live state.
      break
    case .deferBusy:
      // Mid-transition — queue the pick; the status subscription re-serves
      // it on the next settled state.
      Self.log.info("engine busy — deferring pick model=\(modelID, privacy: .public) profile=\(profileID, privacy: .public)")
      deferredPick = Pick(modelID: modelID, profileID: profileID)
    }
  }

  /// A settled engine state a deferred pick can act on. Transitional states
  /// keep the queue parked.
  private static func isSettled(_ status: EngineStatus) -> Bool {
    switch status {
    case .running, .stopped, .failed:
      return true
    case .starting, .stopping:
      return false
    }
  }
}
