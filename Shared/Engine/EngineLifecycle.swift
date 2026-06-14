import Foundation
import Combine

/// The single reconciled, reactively-published engine-lifecycle state. Folds
/// the two independent sources of truth — `EngineStatus` (engine lifecycle,
/// from `EngineStatusStore`) and `ModelLoadCenter` (model load + residency) —
/// into ONE `EngineIndicatorState` via the existing pure
/// `EngineIndicatorState.make` reducer (reused verbatim — no new reducer), so
/// every surface (toolbar dot, status popover, chat send gate) derives from
/// one value and cannot drift. In particular the popover can no longer claim a
/// `Loaded — resident` model while the engine is stopped.
///
/// It also closes the dropped stop edge: `ModelLoadCenter` has no engine
/// observer of its own, so when the engine leaves `.running` this coordinator
/// invalidates app-side residency (`ModelLoadCenter.engineLeftRunning()`) —
/// the engine freed the model's RAM, so the resident state must not outlive
/// it. That source invalidation is the real fix; deriving every surface from
/// `indicator` is the belt-and-suspenders that also covers the brief edge
/// before the invalidation lands.
@MainActor
public final class EngineLifecycle: ObservableObject {
  /// The single semantic engine/model state, refolded on any input change.
  @Published public private(set) var indicator: EngineIndicatorState

  private let engineStatus: EngineStatusStore
  private let modelLoad: ModelLoadCenter
  private var cancellables: Set<AnyCancellable> = []

  /// Whether the last observed `EngineStatus` was `.running`, so a transition
  /// OUT of `.running` is detected as an EDGE (fired once) rather than on
  /// every poll or every load-state change.
  private var wasRunning: Bool

  public init(engineStatus: EngineStatusStore, modelLoad: ModelLoadCenter) {
    self.engineStatus = engineStatus
    self.modelLoad = modelLoad
    self.wasRunning = Self.isRunning(engineStatus.status)
    self.indicator = EngineIndicatorState.make(
      engine: engineStatus.status,
      engineDetail: engineStatus.statusDetail,
      residentModelID: modelLoad.residentModelID
    )
    wire()
  }

  private func wire() {
    // Refold the single semantic state whenever any input changes.
    // `$status`/`$lastError` feed the engine axis (+ the `.starting` detail);
    // `$residentModelID` feeds the resident-model display (#469: the separate
    // load axis is gone). `@Published` emits the current value on
    // subscription, so `indicator` is correct immediately and stays
    // change-guarded (`Equatable`) against churn.
    Publishers.CombineLatest3(
      engineStatus.$status,
      engineStatus.$lastError,
      modelLoad.$residentModelID
    )
    .sink { [weak self] status, _, resident in
      guard let self else { return }
      let next = EngineIndicatorState.make(
        engine: status,
        engineDetail: self.engineStatus.statusDetail,
        residentModelID: resident
      )
      if next != self.indicator { self.indicator = next }
    }
    .store(in: &cancellables)

    // The session edges, keyed off `status` ALONE so they fire once per
    // transition — not on load churn. `$status` is `@Published` + `Equatable`
    // (the snapshot is the whole `.running` payload), so it re-emits only when
    // the snapshot actually changes.
    engineStatus.$status
      .sink { [weak self] status in
        guard let self else { return }
        let nowRunning = Self.isRunning(status)
        // Enter `.running` (or a snapshot change while running — a model-switch
        // restart): feed the authoritative `EngineSessionSnapshot` (#476) into
        // `ModelLoadCenter` the instant it lands, so the served model + effective
        // `max_tokens` ceiling are available to the send path BEFORE the first
        // send — no `/v1/models` round-trip race. The `/v1/models` reconcile in
        // `ChatScaffoldView` remains the engine-authoritative cross-check.
        // Setters are change-guarded. A legacy/pin snapshot carries an empty
        // `servedModelID` (no model resolution happened on that path) — skip it
        // so it never clobbers real residency.
        if case .running(let snapshot) = status, !snapshot.servedModelID.isEmpty {
          self.modelLoad.reconcileEngineResident(snapshot.servedModelID)
          self.modelLoad.setResidentMaxOutputTokens(snapshot.maxOutputTokens)
        }
        // The dropped stop edge: on any transition OUT of `.running`, invalidate
        // app-side residency so no surface outlives the freed model's RAM.
        // `engineLeftRunning()` is idempotent, so a redundant call is safe.
        if self.wasRunning, !nowRunning {
          self.modelLoad.engineLeftRunning()
        }
        self.wasRunning = nowRunning
      }
      .store(in: &cancellables)
  }

  private static func isRunning(_ status: EngineStatus) -> Bool {
    if case .running = status { return true }
    return false
  }
}
