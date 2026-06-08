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
/// residency mirror: which model is currently served, reconciled from
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

  /// The engine left `.running` (stopped, failed, or stopping). Its resident
  /// model's RAM is freed by the stop, so app-side residency must not outlive
  /// it: clear `residentModelID`. Idempotent (a no-op once cleared), so it is
  /// safe to call on every leave-`.running` edge. Invoked by `EngineLifecycle`
  /// on the `EngineStatus` transition out of `.running`.
  public func engineLeftRunning() {
    guard residentModelID != nil else { return }
    residentModelID = nil
    Self.log.info("engine left running — resident cleared")
  }

  /// The engine is `.running` but `GET /v1/models` returned no model — a live
  /// engine serving nothing. Clear any stale residency so the chat gate does
  /// not pass a send to a model the engine no longer has. Sibling to
  /// `engineLeftRunning()` for the engine-running-but-empty case
  /// (`reconcileEngineResidentModel`'s `.empty` branch).
  public func engineServesNoModel() {
    guard residentModelID != nil else { return }
    residentModelID = nil
  }

  /// Explicit Unload. Clears the resident model. Paired by the caller with an
  /// engine `stopEngine` so the model's RAM is actually freed; this only
  /// resets the app-side source of truth. The next send re-enters the no-model
  /// confirm gate.
  public func markUnloaded() {
    guard residentModelID != nil else {
      Self.log.info("model unloaded — already idle")
      return
    }
    residentModelID = nil
    Self.log.info("model unloaded — resident cleared")
  }
}
