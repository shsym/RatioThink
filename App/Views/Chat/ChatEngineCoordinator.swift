import Foundation

/// #616: the app's engine-orchestration coordinator, extracted out of
/// `ChatScaffoldView` (a god-view that owned engine start/stop/unload, the
/// `/v1/models` residency reconcile, and a process-global once-per-launch
/// start-prompt latch as an `@MainActor static var` on the render path).
///
/// App-scoped (one instance, built in `RatioThinkApp`'s composition root and
/// injected as an `@EnvironmentObject`) so the latch is a normal instance bool
/// surviving the per-chat `.id(id)` remount, and so the chat scaffold and the
/// Local API view drive ONE engine through the same methods instead of each
/// open-coding the start/stop sequence.
///
/// What lives here is engine orchestration: the start/stop/unload/refresh
/// calls and their sequencing (stop→`markUnloaded`), the `/v1/models`
/// residency reconcile (fetch → fold the toolbar served-model list → set
/// `ModelLoadCenter` residency + the engine token ceiling), and the launch
/// latch. What stays in the views is the per-surface presentation and the
/// view-state consequences of a reconcile (a chat seeding its own
/// `Chat.modelID` selection, settling its `PendingSendState`): the coordinator
/// returns the reconcile result and the view applies its own state. Thrown
/// engine errors propagate so each view keeps its own fault-presentation state
/// (`engineActionError` / `helperBlock`) and `HelperUnavailable`-vs-engine-fault
/// routing.
///
/// Holds strong references to the app-lifetime singletons it drives; none
/// reference it back, so there is no retain cycle.
@MainActor
final class ChatEngineCoordinator: ObservableObject {
  private let engineStatus: EngineStatusStore
  private let modelLoad: ModelLoadCenter
  private let engineClient: any EngineClient

  /// What the chat toolbar model menu should offer, folded from the latest
  /// `/v1/models` reconcile. `.unknown` (→ the caller's injected fallback)
  /// only until the first reconcile; afterwards the engine's real served list
  /// (`.known`, possibly empty), so a verified empty/not-running/unreachable
  /// engine never re-surfaces placeholder models the engine would reject (F2).
  /// An engine fact, so it is owned here rather than per-chat-view `@State`.
  @Published var engineModels: ToolbarModelList = .unknown

  /// #4: closes after the engine status FIRST settles this launch, so the
  /// launch prompt is evaluated exactly once and a later mid-session stop
  /// never re-pops it. Instance-scoped on the app-lifetime coordinator
  /// (replaces the old `View`-struct `static`), so the app still asks exactly
  /// once per launch but the latch no longer lives on the render path.
  private var didEvaluateLaunchStartPrompt = false

  init(engineStatus: EngineStatusStore,
       modelLoad: ModelLoadCenter,
       engineClient: any EngineClient) {
    self.engineStatus = engineStatus
    self.modelLoad = modelLoad
    self.engineClient = engineClient
  }

  // MARK: - start / stop / unload

  /// Unload: stop the engine (frees the resident model's RAM) and, only on
  /// success, clear the app-side resident state. If the stop is rejected the
  /// resident model stays put so the indicator does not lie about freed
  /// memory. Re-throws so the caller routes a `HelperUnavailable` to its
  /// helper-framed notice and any other fault to the engine-failure banner.
  func unload() async throws {
    try await engineStatus.stopEngine()
    modelLoad.markUnloaded()
  }

  /// Stop the engine WITHOUT clearing app-side residency — the Local API
  /// toggle's off path. (`EngineLifecycle` invalidates residency on the
  /// leave-`.running` edge; the chat Unload additionally marks the model
  /// unloaded eagerly via `unload()`.) Re-throws for the caller to route.
  func stopEngine() async throws {
    try await engineStatus.stopEngine()
  }

  /// Kick the helper to (re)start the engine on `profileID`. The chat scaffold
  /// passes a `modelOverride` (an explicit per-chat model pick as the boot
  /// model, #459/#460); the Local API view passes a `daemonBindHost` (its
  /// external-access bind mode). Both default to the store's own resolution.
  /// Re-throws for the caller to route.
  func startEngine(profileID: String,
                   modelOverride: String? = nil,
                   daemonBindHost: EngineHTTPBindMode? = nil) async throws {
    try await engineStatus.startEngine(profileID: profileID,
                                       modelOverride: modelOverride,
                                       daemonBindHost: daemonBindHost)
  }

  /// #397 F1: re-poll the helper after an unreachable-transport failure. The
  /// 1 Hz loop would catch up anyway; this makes Retry immediate.
  func refreshStatus() async {
    _ = try? await engineStatus.refresh()
  }

  // MARK: - residency reconcile

  /// When the engine is running, sync `ModelLoadCenter` residency to the id
  /// the engine actually serves (`GET /v1/models`) — the only id its chat
  /// endpoint accepts — and capture the engine's effective `max_tokens`
  /// ceiling (#474) from the same response. Folds the served list into
  /// `engineModels`. Returns the raw reconcile result so the caller can apply
  /// its OWN view-state consequences (a chat seeding `Chat.modelID`, settling
  /// a pending send) — those touch per-chat SwiftData/`@State` and are not
  /// engine orchestration.
  ///
  /// No-op effects when the engine isn't running or a load is in flight (the
  /// `ModelLoadCenter` setters are internally guarded).
  @discardableResult
  func reconcileResidentModel() async -> EngineModelReconciler.Result {
    // Bounded retry while the engine stays running — a single transient
    // /v1/models failure must not strand residency unset until a status flip
    // that may never come on equal .running polls (F2).
    var fetchedCeiling: Int?
    let result = await EngineModelReconciler.reconcile(
      isRunning: {
        if case .running = self.engineStatus.status { return true }
        return false
      },
      fetchModelIDs: {
        let infos = try await self.engineClient.models()
        // #474: the engine's effective max_tokens ceiling is engine-global, so
        // the first entry's value is authoritative; it rides the same fetch.
        fetchedCeiling = infos.first?.maxOutputTokens
        return infos.map(\.id)
      }
    )
    // Fold into the toolbar state. `.empty`/`.notRunning` become `.known([])`
    // (no placeholders for a verified empty/dead engine); `.failedAfterRetries`
    // keeps any prior known list. Placeholders show only before the first
    // fetch (F2).
    engineModels = ToolbarModelList.from(result, previous: engineModels)
    switch result {
    case .models(let ids):
      // reconcileEngineResident is internally guarded against clobbering an
      // in-flight load.
      modelLoad.reconcileEngineResident(ids[0])
      // #474: apply the launched ceiling unconditionally (a guardrail change
      // or reload can hand the same model a different ceiling). The setter
      // no-ops on an unchanged value and while a load is in flight.
      modelLoad.setResidentMaxOutputTokens(fetchedCeiling)
    case .empty:
      // Engine running but serving NO model — clear any stale residency so the
      // send gate doesn't pass a model the engine no longer has. No-op while a
      // load is in flight.
      modelLoad.engineServesNoModel()
    case .failedAfterRetries(let attempts):
      // Don't silently drop: engine running but unreachable for models. The
      // caller decides whether to retry / settle a pending send.
      NSLog("ChatEngineCoordinator: /v1/models reconcile failed after \(attempts) attempts while engine .running")
    case .notRunning:
      // Engine isn't running — `EngineLifecycle` already invalidated residency
      // on the leave-`.running` edge; nothing to do here.
      break
    }
    return result
  }

  // MARK: - launch latch

  /// #4: the engine no longer auto-starts on boot. Once the status settles, if
  /// the engine is idle with a default model (and Local API auto-start is
  /// off), the caller proactively raises the no-model prompt — whose Load
  /// action starts the engine — so the user explicitly confirms the start.
  ///
  /// Returns `true` exactly once per launch, when the prompt should be raised.
  /// The initial `.starting` placeholder is skipped so the real post-launch
  /// state is evaluated, not the "reachability unknown" default.
  func shouldPromptEngineStartOnLaunch(autoStartEnabled: Bool, target: ModelTarget?) -> Bool {
    guard !didEvaluateLaunchStartPrompt else { return false }
    if case .starting = engineStatus.status { return false }
    didEvaluateLaunchStartPrompt = true
    if autoStartEnabled { return false }
    return LaunchEngineStartPrompt.shouldAsk(status: engineStatus.status, target: target)
  }
}
