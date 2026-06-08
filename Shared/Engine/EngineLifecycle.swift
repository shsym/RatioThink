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

    // The dropped stop edge: on any transition OUT of `.running`, invalidate
    // app-side residency so no surface outlives the freed model's RAM. Keyed
    // off `status` ALONE so it fires once per edge — not on load churn, and
    // not re-firing while the engine stays stopped. `engineLeftRunning()` is
    // idempotent, so even a redundant call is safe.
    engineStatus.$status
      .sink { [weak self] status in
        guard let self else { return }
        let nowRunning = Self.isRunning(status)
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
