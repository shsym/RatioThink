import Foundation
import Combine
import os

/// App-wide source of truth for the engine's RESIDENT model — the single
/// model the engine serves (v1 pie binds it at `pie serve` boot).
///
/// #469: the former in-flight model-LOAD half (progress / Cancel / Retry,
/// driven by the now-removed `/v1/models/load` endpoint) is gone. Changing the
/// served model is an engine LIFECYCLE event (start / restart), surfaced by
/// `EngineStatusStore` / `EngineIndicatorState` ("Engine starting…" → running),
/// not a load with its own progress UI. What remains here is purely the
/// residency mirror: which model is currently served (and the engine's
/// effective per-request `max_tokens` ceiling for it, #474), reconciled from
/// `GET /v1/models` and invalidated when the engine leaves `.running`. The
/// chat send gate and the toolbar model menu read `residentModelID`; the
/// profile-swap "pick == resident" no-op short-circuit depends on it.
@MainActor
public final class ModelLoadCenter: ObservableObject {
  /// The model the engine currently serves, or `nil` when nothing is resident
  /// (engine stopped, or running but serving no model). Updated by the
  /// reconcile from `GET /v1/models`, by a chat `model_ready` meta-frame, and
  /// cleared on the leave-`.running` edge.
  @Published public private(set) var residentModelID: String?

  /// The launched engine's effective per-request `max_tokens` ceiling for
  /// the resident model (#474), learned from `GET /v1/models`
  /// (`ModelInfo.maxOutputTokens`). `nil` = unknown (pre-#474 engine, no
  /// model, or never reconciled) → the send path does not clamp. Updated
  /// on every successful reconcile, even when `residentModelID` is
  /// unchanged: a memory-guardrail change or model reload can re-launch
  /// the engine with a different ceiling under the same model id. Cleared
  /// wherever residency clears so a stale ceiling never outlives its engine.
  @Published public private(set) var residentMaxOutputTokens: Int?

  private static let log = Logger(subsystem: "com.ratiothink.app", category: "model-load")

  public init(initialResident: String? = nil) {
    self.residentModelID = initialResident
  }

  /// Reflect a model the engine already serves. The engine binds its model at
  /// `pie serve` boot, so after any start/restart (launch prompt, explicit
  /// Restart, Local API, post-download start, crash auto-relaunch) the App
  /// learns the resident id from `GET /v1/models` (the only id the engine's
  /// chat endpoint accepts) and records it here so the composer's send gate
  /// unblocks. No-op when already recorded.
  public func reconcileEngineResident(_ id: String) {
    guard residentModelID != id else { return }
    residentModelID = id
    Self.log.info("engine-resident reconcile: residentModelID=\(id, privacy: .public)")
  }

  /// Record the launched engine's effective `max_tokens` ceiling reported by
  /// `GET /v1/models` (#474). Set unconditionally on every successful
  /// reconcile — unlike `reconcileEngineResident`, this does NOT short-circuit
  /// on an unchanged model id, because a guardrail change or reload can hand
  /// the same model a different ceiling. (#469: there is no in-flight load to
  /// race anymore, so the former `!isLoading` guard is gone.)
  public func setResidentMaxOutputTokens(_ ceiling: Int?) {
    guard residentMaxOutputTokens != ceiling else { return }
    residentMaxOutputTokens = ceiling
    Self.log.info("engine-resident ceiling: maxOutputTokens=\(ceiling ?? -1, privacy: .public)")
  }

  /// The engine left `.running` (stopped, failed, or stopping). Its resident
  /// model's RAM is freed by the stop, so app-side residency must not outlive
  /// it: clear `residentModelID` and the resident ceiling. Idempotent (a no-op
  /// once cleared), so it is safe to call on every leave-`.running` edge.
  /// Invoked by `EngineLifecycle` on the `EngineStatus` transition out of
  /// `.running`.
  public func engineLeftRunning() {
    guard residentModelID != nil || residentMaxOutputTokens != nil else { return }
    residentModelID = nil
    residentMaxOutputTokens = nil
    Self.log.info("engine left running — resident cleared")
  }

  /// The engine is `.running` but `GET /v1/models` returned no model — a live
  /// engine serving nothing. Clear any stale residency (and ceiling) so the
  /// chat gate does not pass a send to a model the engine no longer has.
  /// Sibling to `engineLeftRunning()` for the engine-running-but-empty case
  /// (`reconcileEngineResidentModel`'s `.empty` branch).
  public func engineServesNoModel() {
    if residentModelID != nil { residentModelID = nil }
    if residentMaxOutputTokens != nil { residentMaxOutputTokens = nil }
  }

  /// Explicit Unload. Clears the resident model (and ceiling). Paired by the
  /// caller with an engine `stopEngine` so the model's RAM is actually freed;
  /// this only resets the app-side source of truth. The next send re-enters
  /// the no-model confirm gate.
  public func markUnloaded() {
    guard residentModelID != nil || residentMaxOutputTokens != nil else {
      Self.log.info("model unloaded — already idle")
      return
    }
    residentModelID = nil
    residentMaxOutputTokens = nil
    Self.log.info("model unloaded — resident cleared")
  }
}
