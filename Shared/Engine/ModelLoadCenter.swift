import Foundation
import Combine
import os

/// App-wide source of truth for the in-flight model load. The window
/// toolbar's `ModelLoadIndicator` (Phase 3.5) and the profile-swap
/// popover (Phase 3.6) read state from one instance so a load kicked
/// off by either entry point lights up the same indicator.
///
/// Decoupled from `EngineClient` — callers hand in a stream factory so
/// the center can be unit-tested without bringing up an engine, and so
/// the same observable can drive loads triggered by `loadModel` *or* by
/// a `chatCompletion` meta-frame prefix (Phase 6).
@MainActor
public final class ModelLoadCenter: ObservableObject {
  public enum State: Equatable, Sendable {
    case idle
    /// Engine reported a `.loading` frame. `totalBytes == 0` is the
    /// indeterminate fallback — the indicator renders a spinning arc
    /// instead of a determinate fill. `etaSeconds == nil` until the
    /// engine has a transfer-rate sample (matches `LoadEvent` semantics).
    case loading(modelID: String, loadedBytes: UInt64, totalBytes: UInt64, etaSeconds: Double?)
    case ready(modelID: String)
    case cancelled(modelID: String)
    case failed(modelID: String, message: String)
    /// Engine has not yet reported `.running` over XPC — the request
    /// short-circuited inside `HTTPEngineClient.baseURLProvider` with
    /// `HTTPEngineError.engineNotReady`. Distinct from `.failed` so
    /// the toolbar surfaces an "Engine starting…" placeholder (yellow
    /// ring + idle copy) rather than a generic red failure banner.
    /// : callers should retry the load once
    /// `EngineStatusStore.status` flips to `.running`.
    case engineNotReady(modelID: String, detail: String)
  }

  @Published public private(set) var state: State

  /// The last *verified* `.ready` model. Verified-only contract per
  /// review v2 F2: updates ONLY on terminal `.ready`, stays through
  /// transient `.cancelled` / `.failed` of subsequent loads. Most
  /// engines do not evict the prior resident until the new load
  /// succeeds, so the conservative reading is "still resident."
  @Published public private(set) var residentModelID: String?

  // MARK: - epoch counters
  //
  // Two-counter model (review v3 F1). Each load() captures both at
  // start; every terminal-dispatch site checks both:
  //
  //   - `eventEpoch` is bumped by BOTH cancel() and load(). The
  //     for-await body drops events whose captured epoch no longer
  //     matches — this catches buffered `.ready` frames that arrived
  //     before the user clicked Cancel (the F1-v1 race) AND events
  //     from superseded loads. Post-loop, an `eventEpoch` mismatch
  //     plus `loadEpoch` match signals "cancel ran, no new load" —
  //     the cue to flip state to `.cancelled`.
  //
  //   - `loadEpoch` is bumped ONLY by load(). A mismatch here means
  //     a NEW load has started; the old task's terminal must drop
  //     unconditionally, otherwise it would clobber the new load's
  //     state (the ABA-on-modelID case in review v3 F1).
  //
  // Single-counter generation cannot disambiguate these two cases:
  // a generation gap of 1 could be "cancel only" or "start of a new
  // load." Splitting the counters makes the distinction explicit.

  private var eventEpoch: UInt64 = 0
  private var loadEpoch: UInt64 = 0

  /// The most recent `(modelID, streamFactory)` handed to `load()`,
  /// retained so `retryLast()` can re-run it (#396 recovery action).
  /// Cleared by `markUnloaded()` — an explicit Unload is the user
  /// saying "stop", so a later Retry must not resurrect that model.
  /// `.failed` is only ever produced by `load()`'s error path (the chat
  /// pipeline uses `applyChatMetaEvent`, which carries only
  /// `.loading`/`.ready`), so this is a complete retry target for every
  /// failure the popover can surface.
  private var lastLoad: (modelID: String, factory: @Sendable () -> AsyncThrowingStream<LoadEvent, Error>)?

  /// Per-load latch tripped at most once by `progress` to keep the
  /// upstream-protocol-bug warning out of the per-frame logging
  /// budget (review v1 F14). Reset on every `load()` entry.
  private var loggedOverflowFor: UInt64?

  private var task: Task<Void, Never>?
  private static let log = Logger(subsystem: "com.ratiothink.app", category: "model-load")

  public init(initialResident: String? = nil) {
    self.residentModelID = initialResident
    self.state = initialResident.map(State.ready) ?? .idle
  }

  /// Indicator visibility predicate. The window toolbar widget binds
  /// `.opacity(center.isLoading ? 1 : 0)` rather than removing the
  /// view from the hierarchy, so the toolbar layout doesn't reflow
  /// each time a load starts/ends.
  public var isLoading: Bool {
    if case .loading = state { return true }
    return false
  }

  /// Determinate fill in `0...1`, or `nil` for indeterminate. View
  /// reads this once per `state` change and decides between
  /// `Circle().trim(from:0,to:p)` and a spinning short arc.
  ///
  /// `loaded > total` is a protocol bug — log once per load (F14) and
  /// fall through to the indeterminate path so the UI does not pin at
  /// 100 % while the engine is misreporting.
  public var progress: Double? {
    guard case let .loading(_, loaded, total, _) = state, total > 0 else { return nil }
    if loaded > total {
      if loggedOverflowFor != loadEpoch {
        loggedOverflowFor = loadEpoch
        Self.log.error("model load progress overflow: loaded=\(loaded) > total=\(total) (loadEpoch=\(self.loadEpoch, privacy: .public)) — falling through to indeterminate")
      }
      return nil
    }
    return Double(loaded) / Double(total)
  }

  /// Begin a load. Cancels any in-flight load first — only one model
  /// can be resident at a time. Synchronously bumps both epoch
  /// counters; the consuming task captures both at start.
  public func load(
    modelID: String,
    streamFactory: @escaping @Sendable () -> AsyncThrowingStream<LoadEvent, Error>
  ) {
    cancel()
    lastLoad = (modelID, streamFactory)
    loadEpoch &+= 1
    eventEpoch &+= 1
    let myLoadEpoch = loadEpoch
    let myEventEpoch = eventEpoch
    loggedOverflowFor = nil
    state = .loading(modelID: modelID, loadedBytes: 0, totalBytes: 0, etaSeconds: nil)
    Self.log.info("model load begin id=\(modelID, privacy: .public) loadEpoch=\(myLoadEpoch, privacy: .public)")
    let stream = streamFactory()
    // Iteration runs detached on the default executor; state
    // mutations hop back via `MainActor.run`. Review v1 F2 suggested
    // collapsing this onto `Task { @MainActor in }` — empirically
    // that variant starves the for-await pump on this Swift 5.10
    // toolchain. The two-counter gates below are the correctness
    // mechanism; loop placement is just a workaround.
    task = Task.detached { [weak self] in
      do {
        for try await event in stream {
          await MainActor.run {
            guard let self else { return }
            // Drop buffered events from cancelled OR superseded
            // loads, and from a load whose final state has already
            // been committed (e.g. cancel() flipped to .cancelled
            // synchronously, or apply(.ready) ran on a prior frame).
            // eventEpoch catches cancel/supersede; the loading-state
            // precondition catches "already terminal."
            guard self.eventEpoch == myEventEpoch,
                  self.isLoadingOwnedBy(modelID: modelID) else { return }
            self.apply(event: event, modelID: modelID)
          }
        }
        await MainActor.run {
          guard let self else { return }
          self.dispatchPostLoopTerminal(
            modelID: modelID,
            myLoadEpoch: myLoadEpoch,
            myEventEpoch: myEventEpoch
          )
        }
      } catch is CancellationError {
        await MainActor.run {
          guard let self else { return }
          self.dispatchCancellationTerminal(
            modelID: modelID,
            myLoadEpoch: myLoadEpoch
          )
        }
      } catch let HTTPEngineError.engineNotReady(detail) {
        // : `HTTPEngineClient.baseURLProvider` rejected the
        // load because `EngineStatusStore.status != .running`. Surface
        // this as a distinct terminal state so the toolbar shows
        // "Engine starting…" rather than a red "Load failed" ring.
        await MainActor.run {
          guard let self else { return }
          self.dispatchEngineNotReadyTerminal(
            modelID: modelID,
            detail: detail,
            myLoadEpoch: myLoadEpoch
          )
        }
      } catch {
        let message = "\(error)"
        await MainActor.run {
          guard let self else { return }
          self.dispatchFailureTerminal(
            modelID: modelID,
            message: message,
            myLoadEpoch: myLoadEpoch
          )
        }
      }
    }
  }

  /// Re-run the most recent load (#396 recovery action). Drives the
  /// popover's "Retry" button on a `.failed` / `.engineNotReady`
  /// terminal: re-invokes the stored stream factory through the normal
  /// `load()` path (which cancels any in-flight load and resets the
  /// epoch counters), so a retry is indistinguishable from the user
  /// re-triggering the same load. No-op when nothing has been loaded
  /// yet or after an explicit Unload cleared the target.
  public func retryLast() {
    guard let lastLoad else {
      Self.log.info("retryLast: no prior load to retry — ignored")
      return
    }
    Self.log.info("retryLast: re-running load id=\(lastLoad.modelID, privacy: .public)")
    load(modelID: lastLoad.modelID, streamFactory: lastLoad.factory)
  }

  /// Cancel the current load. No-op when idle.
  ///
  /// Synchronously transitions `.loading(id)` → `.cancelled(id)`
  /// (review v3 F3) so the popover's F7 `.onChange(of: showPopover)`
  /// cleanup observes the terminal state immediately after the
  /// Cancel button fires `isPresented = false`. Before this fix the
  /// transition happened asynchronously from the consuming task's
  /// catch site — the popover dismissed first, the onChange ran
  /// against `.loading`, and the terminal-ack never fired.
  ///
  /// Bumps `eventEpoch` (so any buffered events from this load are
  /// dropped by the for-await body) without touching `loadEpoch`
  /// (so the post-loop branch can still recognize "cancel happened
  /// to me, no new load" for the F1-v1 race where the synchronous
  /// transition below was a no-op because state was not `.loading`).
  public func cancel() {
    let inflightModelID: String?
    if case let .loading(id, _, _, _) = state {
      inflightModelID = id
    } else {
      inflightModelID = nil
    }
    task?.cancel()
    task = nil
    eventEpoch &+= 1
    if let id = inflightModelID {
      state = .cancelled(modelID: id)
      Self.log.info("model load cancelled (synchronous) id=\(id, privacy: .public)")
    }
  }

  /// Applies model-loading meta frames that arrive as part of a chat
  /// completion stream. Unlike `load(modelID:streamFactory:)`, the
  /// producer is owned by the chat send pipeline, so this method only
  /// mirrors the observed state into the shared indicator and cancels
  /// any standalone load task that would otherwise race to publish an
  /// older terminal state.
  public func applyChatMetaEvent(_ event: LoadEvent, modelID: String) {
    task?.cancel()
    task = nil
    loadEpoch &+= 1
    eventEpoch &+= 1
    loggedOverflowFor = nil
    apply(event: event, modelID: modelID)
  }

  // MARK: - terminal dispatchers

  /// Common precondition for every terminal dispatcher (review v4
  /// F1+F2): state MUST be `.loading(modelID)`. Once state is
  /// terminal (`.ready` / `.cancelled` / `.failed`), no further
  /// write is appropriate — the prior writer (cancel(), apply(.ready),
  /// or another dispatcher) has already committed the final outcome.
  /// Without this guard, two failure modes appeared:
  ///   - F1: cancel() flips state to `.cancelled(A)`. A producer
  ///     stream that doesn't honor `Task.isCancelled` later finishes
  ///     with a non-cancel error. Catch arm passed the previous
  ///     ownership-only gate (state.id == modelID still holds) and
  ///     overwrote `.cancelled` with `.failed` — Cancel turned into
  ///     a red failure ring.
  ///   - F2: stream emits `.ready` → finishReady sets `.ready(A)`.
  ///     User clicks Cancel before the post-loop hop runs. Post-loop
  ///     passed ownership-only gate against `.ready(A)`, saw the
  ///     bumped eventEpoch, and demoted `.ready` to `.cancelled` —
  ///     a verified load reported as cancelled.
  /// Returning `false` here means: somebody else owns the final
  /// outcome; do nothing.
  private func isLoadingOwnedBy(modelID: String) -> Bool {
    if case let .loading(id, _, _, _) = state, id == modelID {
      return true
    }
    return false
  }

  /// Post-loop dispatch — stream finished cleanly (iterator returned
  /// nil without throwing). Requires state == `.loading(modelID)`;
  /// see `isLoadingOwnedBy` for rationale.
  ///
  ///   - loadEpoch mismatch → a new load started → drop silently.
  ///   - state no longer `.loading(modelID)` → terminal already
  ///     committed (e.g. cancel() flipped to `.cancelled`) → drop.
  ///   - eventEpoch match → normal terminal: mark ready.
  ///   - eventEpoch mismatch → cancel() ran for this load with no
  ///     new load behind it → mark cancelled.
  ///
  /// Review v5 F1: split log severity. A `loadEpoch` mismatch is a
  /// real stale-race drop (`.notice`); an "already-terminal" drop
  /// is the in-band happy path (apply(.ready) wrote `.ready(A)` in
  /// the same for-await iteration) and must NOT log at `.notice` —
  /// it would fire on every successful load and read like a race.
  private func dispatchPostLoopTerminal(
    modelID: String,
    myLoadEpoch: UInt64,
    myEventEpoch: UInt64
  ) {
    guard loadEpoch == myLoadEpoch else {
      Self.log.notice("dropping stale post-loop terminal (new load took over) id=\(modelID, privacy: .public) loadEpoch=\(myLoadEpoch, privacy: .public) current-loadEpoch=\(self.loadEpoch, privacy: .public)")
      return
    }
    guard isLoadingOwnedBy(modelID: modelID) else {
      // Terminal already committed in-band (apply(.ready) →
      // finishReady ran inside the for-await body, or cancel()
      // synchronously flipped to .cancelled). Expected on every
      // happy-path load — debug only.
      Self.log.debug("post-loop fallthrough; terminal already committed id=\(modelID, privacy: .public) state=\(String(describing: self.state), privacy: .public)")
      return
    }
    if eventEpoch == myEventEpoch {
      finishReady(modelID: modelID)
    } else {
      markCancelled(modelID: modelID)
    }
  }

  /// `CancellationError` propagation — stream threw on cancellation
  /// (or the consuming task was cancelled). Same precondition as
  /// post-loop. Common case: cancel() has already synchronously
  /// flipped state to `.cancelled(modelID)`, so the guard drops and
  /// this dispatcher becomes a no-op — that's the F3 idempotency
  /// guarantee.
  ///
  /// Review v5 F2: split log severity. Same split as post-loop —
  /// the idempotent-drop path (cancel() already flipped state) is
  /// `.debug`; only a loadEpoch mismatch logs at `.notice`.
  private func dispatchCancellationTerminal(
    modelID: String,
    myLoadEpoch: UInt64
  ) {
    guard loadEpoch == myLoadEpoch else {
      Self.log.notice("dropping stale cancel (new load took over) id=\(modelID, privacy: .public) loadEpoch=\(myLoadEpoch, privacy: .public) current-loadEpoch=\(self.loadEpoch, privacy: .public)")
      return
    }
    guard isLoadingOwnedBy(modelID: modelID) else {
      Self.log.debug("cancellation already committed in-band; idempotent drop id=\(modelID, privacy: .public) state=\(String(describing: self.state), privacy: .public)")
      return
    }
    markCancelled(modelID: modelID)
  }

  /// Producer-side failure — stream finished with a non-cancel error.
  /// Same precondition as post-loop. Critically: a late failure from
  /// a producer that doesn't honor `Task.isCancelled`, arriving after
  /// the user clicked Cancel, must NOT rewrite `.cancelled` to
  /// `.failed` (review v4 F1).
  ///
  /// Review v5 F2: split log severity. The `error=` field is only
  /// attached when the failure is actually surfaced as the terminal
  /// (stale-load path). On the idempotent-drop path the user-facing
  /// terminal is already `.cancelled` and the producer error is no
  /// longer the story — log at `.debug` without the error= field so
  /// triage doesn't mistake it for a real failure.
  /// Engine-not-ready dispatch — `HTTPEngineClient.baseURLProvider`
  /// short-circuited the request with `HTTPEngineError.engineNotReady`.
  /// Same epoch + ownership preconditions as the other terminal
  /// dispatchers: a stale "engine not ready" must not overwrite a
  /// newer load that succeeded, and the dispatch is a no-op if the
  /// terminal was already committed in-band.
  ///
  /// Routed to its own state case (`.engineNotReady`) so the toolbar
  /// renders a yellow "Engine starting…" placeholder rather than the
  /// red "Load failed" ring `.failed` triggers.
  private func dispatchEngineNotReadyTerminal(
    modelID: String,
    detail: String,
    myLoadEpoch: UInt64
  ) {
    guard loadEpoch == myLoadEpoch else {
      Self.log.notice("dropping stale engineNotReady (new load took over) id=\(modelID, privacy: .public) loadEpoch=\(myLoadEpoch, privacy: .public) current-loadEpoch=\(self.loadEpoch, privacy: .public)")
      return
    }
    guard isLoadingOwnedBy(modelID: modelID) else {
      Self.log.debug("engineNotReady dropped; terminal already committed in-band id=\(modelID, privacy: .public) state=\(String(describing: self.state), privacy: .public) detail=\(detail, privacy: .public)")
      return
    }
    markEngineNotReady(modelID: modelID, detail: detail)
  }

  private func dispatchFailureTerminal(
    modelID: String,
    message: String,
    myLoadEpoch: UInt64
  ) {
    guard loadEpoch == myLoadEpoch else {
      Self.log.notice("dropping stale failure (new load took over) id=\(modelID, privacy: .public) loadEpoch=\(myLoadEpoch, privacy: .public) current-loadEpoch=\(self.loadEpoch, privacy: .public) error=\(message, privacy: .public)")
      return
    }
    guard isLoadingOwnedBy(modelID: modelID) else {
      // Review v6 F1: keep `error=` in the debug interpolation. The
      // commit narrative ("error is no longer the story") only
      // applies to the sync-cancel-then-late-failure path; two
      // other paths reach here too — (b) for-await committed
      // .ready in-band then the stream throws a non-cancel error
      // before the iterator returns nil, and (c) user dismissed
      // a terminal via dismissTerminalState() then the producer
      // crashes. Both are real "post-success producer crash"
      // diagnostics; dropping the message renders them
      // unrecoverable even with debug logging enabled.
      Self.log.debug("failure dropped; terminal already committed in-band id=\(modelID, privacy: .public) state=\(String(describing: self.state), privacy: .public) error=\(message, privacy: .public)")
      return
    }
    markFailed(modelID: modelID, message: message)
  }

  // MARK: - state mutation primitives

  private func apply(event: LoadEvent, modelID: String) {
    switch event {
    case let .loading(loaded, total, eta):
      state = .loading(modelID: modelID, loadedBytes: loaded, totalBytes: total, etaSeconds: eta)
    case .ready:
      finishReady(modelID: modelID)
    }
  }

  private func finishReady(modelID: String) {
    residentModelID = modelID
    state = .ready(modelID: modelID)
    task = nil
    Self.log.info("model load ready id=\(modelID, privacy: .public)")
  }

  private func markCancelled(modelID: String) {
    state = .cancelled(modelID: modelID)
    task = nil
    Self.log.info("model load cancelled id=\(modelID, privacy: .public)")
  }

  private func markFailed(modelID: String, message: String) {
    state = .failed(modelID: modelID, message: message)
    task = nil
    Self.log.error("model load failed id=\(modelID, privacy: .public) error=\(message, privacy: .public)")
  }

  private func markEngineNotReady(modelID: String, detail: String) {
    state = .engineNotReady(modelID: modelID, detail: detail)
    task = nil
    Self.log.info("model load deferred — engine not ready id=\(modelID, privacy: .public) detail=\(detail, privacy: .public)")
  }

  // MARK: - user-facing terminal acknowledgement

  /// Explicit Unload. Abandons any in-flight load, clears the
  /// resident model, and returns to `.idle`. Paired by the caller with
  /// an engine `stopEngine` so the model's RAM is actually freed; this
  /// only resets the app-side source of truth. The next send re-enters
  /// the no-model confirm gate.
  public func markUnloaded() {
    cancel()
    lastLoad = nil
    residentModelID = nil
    state = .idle
    Self.log.info("model unloaded — resident cleared, state idle")
  }

  /// Reflect a model the ENGINE already has resident that this center
  /// did not load itself ( follow-up). The engine can come up with a
  /// model already loaded after an explicit start path (launch prompt/user
  /// confirmation, Restart, Local API, post-download startEngine) or after
  /// crash auto-relaunch, in which case nothing went through `startLoad`, so
  /// `residentModelID` would stay nil and the chat composer would block
  /// every send behind the no-model prompt despite a ready engine. The
  /// caller passes the id from `GET /v1/models` (the only id the engine's
  /// chat endpoint accepts). No-op while a load is in flight so this
  /// never clobbers an explicit user load.
  public func reconcileEngineResident(_ id: String) {
    guard !isLoading else { return }
    guard residentModelID != id else { return }
    residentModelID = id
    if case .engineNotReady = state { state = .idle }
    Self.log.info("engine-resident reconcile: residentModelID=\(id, privacy: .public)")
  }

  /// The engine left `.running` (stopped, failed, or stopping). Its resident
  /// model's RAM is freed by the stop, so app-side residency must not outlive
  /// it: clear `residentModelID`, demote a settled `.ready` to `.idle`, and
  /// abandon any in-flight `.loading` (it is streaming against a gone engine
  /// and would otherwise leave a stale progress bar). An explicit `.failed` /
  /// `.cancelled` terminal is left intact as history — it no longer counts as
  /// residency because `residentModelID` is now nil. Idempotent (a no-op once
  /// cleared), so it is safe to call on every leave-`.running` edge. Invoked
  /// by `EngineLifecycle` on the `EngineStatus` transition out of `.running`.
  public func engineLeftRunning() {
    if residentModelID != nil { residentModelID = nil }
    switch state {
    case .ready:
      state = .idle
    case .loading:
      // Abandon the in-flight load pump (it will throw on the dead engine);
      // bump eventEpoch so any buffered frame is dropped by the for-await
      // body, and settle to `.idle` rather than a user-facing
      // `.cancelled`/`.failed` — the engine went away, the user did not
      // cancel and the load did not fail on its own merits.
      task?.cancel()
      task = nil
      eventEpoch &+= 1
      state = .idle
    case .idle, .cancelled, .failed, .engineNotReady:
      break  // terminals stay as history; resident already cleared above
    }
    Self.log.info("engine left running — resident cleared, load state settled")
  }

  /// The engine is `.running` but `GET /v1/models` returned no model — a live
  /// engine serving nothing. Clear any stale residency so the chat gate does
  /// not pass a send to a model the engine no longer has. No-op while a load
  /// is in flight (must not clobber a legitimate `.loading`). Sibling to
  /// `engineLeftRunning()` for the engine-running-but-empty case
  /// (`reconcileEngineResidentModel`'s `.empty` branch).
  public func engineServesNoModel() {
    guard !isLoading else { return }
    if residentModelID != nil { residentModelID = nil }
    if case .ready = state { state = .idle }
  }

  /// User-facing clear for terminal `.failed` / `.cancelled` /
  /// `.ready` states (review v2 F3, F7, v3 F3). The popover's
  /// Dismiss button calls this; click-outside dismissal of the
  /// popover routes through here too via the indicator's
  /// `.onChange(of: showPopover)` cleanup.
  ///
  /// Does NOT touch the epoch counters (unlike `cancel()`), so a
  /// dismiss that races a new load cannot kill the new load's task.
  public func dismissTerminalState() {
    switch state {
    case .failed, .cancelled, .ready, .engineNotReady:
      state = .idle
    case .idle, .loading:
      Self.log.error("dismissTerminalState called from non-terminal state \(String(describing: self.state), privacy: .public) — ignored")
    }
  }

  /// Test seam used by the snapshot suite to render the indicator in
  /// each terminal/intermediate state without spinning up a stream.
  /// `internal` (not `public`) per review v2 F3 so production code
  /// cannot reach for it; the test target imports `@testable RatioThink` to
  /// see it.
  internal func _testOverrideState(_ newState: State) {
    cancel()
    state = newState
    if case let .ready(modelID) = newState {
      residentModelID = modelID
    }
  }

  // MARK: - convenience predicates

  /// True iff the most recent terminal is `.engineNotReady`. SwiftUI
  /// views read this to branch on the "Engine starting…" placeholder
  /// without unpacking the State enum each time.
  public var isEngineNotReady: Bool {
    if case .engineNotReady = state { return true }
    return false
  }
}
