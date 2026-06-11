import Foundation
import Combine
import os

/// Decision unit for "user picked profile X (or model Y) — should we
/// just swap, or confirm first?" Decoupled from any specific toolbar
/// view so the same coordinator can drive future entry points
/// (sidebar quick-switcher, command palette).
///
/// Policy (#460 — every real model load is always confirmed; the old
/// per-model skip-set is gone):
///   1. New profile has no default model → swap silently, fire NO load,
///      and KEEP the chat's current concrete model by PINNING it as the
///      chat's selection (`commit(profile, fromModel)`). The new profile
///      has no default to follow, so an unpinned chat would otherwise lose
///      its concrete model (`modelID` nil + no profile default = nothing);
///      pinning `fromModel` makes the model the user was already using
///      survive the switch (acceptance #460-AC1). No popup — there is no
///      competing target model to confirm against.
///   1.5. The chat has NO current model at all (`fromModel == nil`:
///      engine stopped, nothing selected) → swap silently, fire NO load.
///      There is no model to REPLACE, so a swap-confirm "swap from — to X"
///      is meaningless. The model loads later through the normal start gate.
///   2. New profile's default == the chat's current model → swap silently.
///   3. Explicit-model mode (`preserveExplicitModelSelection == true`) and
///      the new profile's default differs → swap silently, pinning the current
///      concrete model and firing no load. This is the default product mode:
///      a user-picked model stays picked across profile changes.
///   4. Otherwise (compatibility/follow-default mode: new profile's default
///      differs from the current model)
///      → publish a `PendingSwap` so the toolbar can present
///      `ProfileSwapPopover`. The popover calls `confirm(token:setAsDefault:)`
///      (switch + pin the new model) or `cancel(token:)` (keep the current
///      model — acceptance #460-AC2).
///
/// Model overrides from the toolbar model menu go through
/// `requestModelOverride`, which uses the same model-identity policy but
/// also offers "Set as default for this profile" on confirm.
///
/// Single-source-of-truth invariant (#460): "the chat's current model" is
/// the per-chat selection authority (`Chat.modelID`, resolved through the
/// active profile's default when unpinned) — passed in by the caller as
/// `fromModel`. The coordinator no longer reads `ModelLoadCenter
/// .residentModelID` for the SELECTION decision: residency is the engine's
/// runtime fact, not the user's selection, and reading it as the selection
/// was one of the three unsynchronized stores #460 collapses. Keying on the
/// passed selection also makes the policy loading-aware — a model that is
/// still loading is already the chat's selection, so switching profiles
/// mid-load still prompts on a differing default. (`loadDirect` keeps its
/// `residentModelID` short-circuit: that is an engine-reload optimization,
/// not a selection read.)
///
/// Atomic in-flight state (review v2 F4): the three pieces of data
/// associated with a pending swap — toProfile/fromModel/toModel,
/// the commit closure, and the token used to disambiguate
/// confirm/dismiss races — live in a single private `PendingState`
/// struct so they cannot drift. Public callers see a derived
/// `PendingSwap` whose `id` IS the token; popover callbacks pass
/// that token back to `confirm(token:)` / `cancel(token:)` and
/// stale callbacks (from a re-entered swap or a post-confirm
/// dismissal) are token-mismatched and silently dropped.
@MainActor
public final class ProfileSwapCoordinator: ObservableObject {
  public struct PendingSwap: Equatable, Identifiable {
    public let id: UUID
    public let toProfileID: String
    public let fromModelID: String?
    public let toModelID: String
    /// : true when the confirm should offer "Set as default for
    /// this profile" — i.e. a runtime model override where the picked
    /// model differs from the profile's stored default. False for a
    /// plain profile swap (the model already IS the profile's default,
    /// so the checkbox would be a no-op).
    public let canSetAsDefault: Bool
    /// True when the popover should offer the third "Keep Current Model"
    /// outcome (#459): switch to the new profile but keep the
    /// already-resident model A loaded, with NO reload. Only the
    /// profile-swap path qualifies (`canSetAsDefault == false`) and only
    /// when a resident model A actually exists (`fromModelID != nil`).
    /// Meaningless for the toolbar model-override path, where the user
    /// explicitly picked a model to load.
    public let canKeepCurrentModel: Bool
  }

  /// Atomic record of an in-flight pending swap. Holds the user's
  /// commit closure alongside the rendered fields so they can never
  /// disagree on identity.
  private struct PendingState {
    let token: UUID
    let toProfileID: String
    let fromModelID: String?
    let toModelID: String
    /// Fully-bound effect run on confirm. A profile swap sets the chat's
    /// profile AND pins `toModelID` as its model; a model override sets the
    /// per-chat model. Storing a `() -> Bool` thunk (rather than a value +
    /// applier) lets the two shapes share the same pending machinery
    /// without the coordinator knowing which fields each writes. Returns
    /// `false` when the caller's durable write failed (review F2) so
    /// `confirm` skips `startLoad` — a failed commit must not load a model
    /// the chat did not actually adopt.
    let commit: () -> Bool
    /// #459 "Keep Current Model", ported onto #460's single authority: the
    /// third profile-swap outcome — switch to the new profile but KEEP the
    /// chat's CURRENT concrete model (`fromModelID`) as its selection, with
    /// NO reload. Built from the same `SwapCommit` by pinning `fromModel`
    /// instead of the new default, so it pins `Chat.modelID` (the authority)
    /// rather than the removed `viewModel.modelOverride`. Non-nil only on the
    /// profile-swap path with a current model; nil for the model-override
    /// path. Returns `false` if the durable write failed (review F2 — a
    /// failed pin leaves the profile unswitched).
    let keepCurrentCommit: (() -> Bool)?
    /// Profile id to persist `toModelID` onto when the user checks
    /// "Set as default". Nil disables the checkbox.
    let setAsDefaultProfileID: String?

    var publicView: PendingSwap {
      PendingSwap(
        id: token,
        toProfileID: toProfileID,
        fromModelID: fromModelID,
        toModelID: toModelID,
        canSetAsDefault: setAsDefaultProfileID != nil,
        // Keep-current is offered exactly when a keep-current action exists
        // (the profile-swap path with a current model to keep) — the single
        // source for the popover's third button.
        canKeepCurrentModel: keepCurrentCommit != nil
      )
    }
  }

  /// What a confirmed/silent swap should persist on the caller's side.
  /// `profileID` is always set; `pinModel` carries the model to pin — the
  /// new default on a confirm-and-switch, or the CURRENT model on the
  /// keep-current / no-default paths (#460-AC1). `nil` means "leave the
  /// chat's model untouched" — used by the same-model and no-current-model
  /// silent paths — distinct from clearing it. Returns
  /// `false` when persisting the pin failed (review F2): on a confirmed
  /// swap the caller must NOT switch the profile, and `confirm` skips the
  /// load. Silent paths ignore the result (they fire no load).
  public typealias SwapCommit = (_ profileID: String, _ pinModel: String?) -> Bool

  @Published public private(set) var pending: PendingSwap?
  private var pendingState: PendingState? {
    didSet { pending = pendingState?.publicView }
  }

  ///  review F2: non-nil when a confirmed "Set as default" write
  /// failed. `ContentToolbar` renders it (mirroring
  /// `ProfileEditor.modelWriteError`) so the swap-popover entry point to
  /// the persist is not silent — the model still loads, but the user is
  /// told the default was NOT saved. Cleared on the next successful (or
  /// skipped) confirm.
  @Published public private(set) var defaultModelWriteError: String?

  ///  review F2: non-nil when a confirmed model pick could not be routed
  /// through the engine (re)launch (#469): a thrown `startEngine` /
  /// `restartEngine` failure that the engine-status poll won't reflect on its
  /// own (a resolver reject — `modelMissing` / `profileMissing` — that the
  /// helper does not publish as `.failed`). `ContentToolbar` renders it next
  /// to `defaultModelWriteError` so a pick that silently failed to take is
  /// never invisible. Cleared at the start of the next serve.
  @Published public private(set) var serveModelError: String?

  private let center: ModelLoadCenter
  /// #469: status-aware executor that makes the engine actually SERVE a
  /// picked model — start it (stopped), restart it (running a different
  /// model), or no-op (already resident) per `ActiveModelLaunchPolicy`. v1
  /// pie binds the served model at boot, so a served-model change is an
  /// engine LIFECYCLE event (start/restart), not a `/v1/models/load` — which
  /// is why there is no longer a direct-load fallback. Required: production
  /// wires the real executor; tests/previews inject a no-op or spy.
  private let serveModel: @MainActor (_ modelID: String, _ profileID: String) async throws -> Void
  private let modelForProfile: (String) -> String?
  /// Persists a confirmed "Set as default" model onto a profile.
  /// Wired to `ProfileStore.setModel` in production; a no-op default
  /// keeps unit construction trivial. Throwing so `confirm` can surface
  /// the failure via `defaultModelWriteError` instead of swallowing it
  /// (review F2).
  private let setDefaultModel: (_ profileID: String, _ model: String) throws -> Void

  private static let log = Logger(subsystem: "com.ratiothink.app", category: "profile-swap")

  public init(
    center: ModelLoadCenter,
    modelForProfile: @escaping (String) -> String? = { _ in nil },
    setDefaultModel: @escaping (_ profileID: String, _ model: String) throws -> Void = { _, _ in },
    serveModel: @escaping @MainActor (_ modelID: String, _ profileID: String) async throws -> Void
  ) {
    self.center = center
    self.modelForProfile = modelForProfile
    self.setDefaultModel = setDefaultModel
    self.serveModel = serveModel
  }

  /// Production wiring. Derives `modelForProfile` from a live
  /// `ProfileStore` so a profile→model lookup is actually available —
  /// `RatioThinkApp` previously built the coordinator with the default
  /// `{ _ in nil }`, which made policy-1 ("unknown target model") fire
  /// for every swap and left the confirm popover dead in production.
  /// `profileStore` is held weakly; the app owns it for the process
  /// lifetime, and a nil read degrades to a silent swap rather than a
  /// crash.
  public convenience init(
    center: ModelLoadCenter,
    profileStore: ProfileStore,
    serveModel: @escaping @MainActor (_ modelID: String, _ profileID: String) async throws -> Void
  ) {
    self.init(
      center: center,
      modelForProfile: { [weak profileStore] in profileStore?.model(forProfileID: $0) },
      setDefaultModel: { [weak profileStore] profileID, model in
        // Propagate the throw so `confirm` surfaces it via
        // `defaultModelWriteError` (review F2) rather than logging only.
        try profileStore?.setModel(model, forProfileID: profileID)
      },
      // #469: the production status-aware engine (re)launch executor, built
      // by `RatioThinkApp` from the live `EngineStatusStore` + `ModelLoadCenter`.
      serveModel: serveModel
    )
  }

  /// Entry point from the profile menu. `commit` performs the persisted
  /// assignment the toolbar would have made directly — set the chat's
  /// profile and, on a confirm-and-switch, pin the new model (`{ profileID,
  /// pinModel in … }`, wired by `ChatScaffoldView`). Deferring through here
  /// lets the coordinator gate it behind the popover when needed.
  ///
  /// Re-entrancy (review v1 F3 + v3 F2): if a popover is already
  /// pending, the prior swap is dropped AND the new pending is
  /// published in a single `pendingState` assignment. The
  /// intermediate `pendingState = nil` of an earlier version let
  /// SwiftUI's popover-binding `get` momentarily read `pending == nil`
  /// between the two writes, which routed a stale `set(false)`
  /// dismissal through `dismissCurrentPending()` and unconditionally
  /// cleared the freshly-published swap — making rapid profile
  /// re-clicks silently swallow the second pick. Single assignment
  /// closes that window.
  ///
  /// Caller contract (review v3 F4): a re-entrant `requestSwap`
  /// silently discards the prior `commit` closure without invoking
  /// it. Callers MUST keep `commit` a pure persisted assignment (e.g.
  /// set `chat.profileID` / `chat.modelID`) with no side effects that
  /// need explicit teardown if the swap is abandoned.
  /// If a caller needs an abandonment signal, plumb it through
  /// their own state — the coordinator deliberately does not invoke
  /// abandoned commits because doing so would commit a swap the
  /// user never confirmed.
  /// `fromModel` is the chat's CURRENT model selection (`Chat.modelID`
  /// resolved through the active profile default — #460 single source of
  /// truth), NOT `center.residentModelID`. `commit` writes the result on
  /// the caller's side: it always sets the profile, and pins a model only
  /// on the confirm-and-switch path (`pinModel != nil`); a silent swap
  /// passes `pinModel == nil` so the chat's current model is PRESERVED.
  ///
  /// #459 "Keep Current Model" is the popover's third outcome — switch the
  /// profile but keep the current model loaded with NO reload. Under the
  /// single authority it needs no separate `setOverride`: the coordinator
  /// builds it from the same `commit`, pinning `fromModel` (the current
  /// model) instead of the new default, which writes `Chat.modelID`.
  /// `preserveExplicitModelSelection` is the non-popover version of the same
  /// keep-current outcome for default explicit-model mode: the caller already
  /// knows `fromModel` came from an explicit concrete row (`Chat.modelID`),
  /// so a profile change should keep that row rather than prompt for the
  /// destination default. Passing `false` preserves the compatibility/follow-
  /// default prompt path.
  public func requestSwap(
    toProfileID: String,
    fromModel: String?,
    preserveExplicitModelSelection: Bool = false,
    commit: @escaping SwapCommit
  ) {
    if let prior = pendingState {
      Self.log.notice("re-entrant requestSwap: discarding prior pending=\(prior.toProfileID, privacy: .public) for new=\(toProfileID, privacy: .public); prior commit is dropped without invocation (review v3 F4)")
    }
    // A fresh interaction begins — clear any stale set-as-default error
    // so it can't linger in the toolbar (review v2 F2).
    defaultModelWriteError = nil
    let toModelID = modelForProfile(toProfileID)

    guard let to = toModelID else {
      // Policy 1 (#460-AC1): the target profile has no default model — commit
      // the profile selection, fire NO load, and KEEP the chat's current
      // concrete model by PINNING it (`pinModel: fromModel`). The new profile
      // has no default to follow, so leaving an unpinned chat's `modelID` nil
      // would drop the model the user was using; pinning `fromModel` makes it
      // survive the switch. `fromModel == nil` (no current model) pins nothing
      // — there is nothing to keep. A later send with nothing resolvable routes
      // through the no-model confirm gate (ChatScaffoldView), never an implicit
      // load here.
      Self.log.debug("swap silent (no target default — pin current model) profile=\(toProfileID, privacy: .public) keep=\(fromModel ?? "—", privacy: .public)")
      pendingState = nil
      _ = commit(toProfileID, fromModel)  // pin current model; silent path fires no load
      return
    }
    guard let fromModel else {
      // Policy 1.5: the chat has NO current model (engine stopped / nothing
      // selected), so there is no model to REPLACE — a swap-confirm
      // ("swap from — to X") is meaningless. Commit the profile selection
      // silently and fire NO load; the model loads later through the normal
      // start gate, never an implicit load here. Nothing to pin/preserve.
      Self.log.debug("swap silent (no current model to replace) profile=\(toProfileID, privacy: .public) to=\(to, privacy: .public)")
      pendingState = nil
      _ = commit(toProfileID, nil)  // silent path fires no load — result irrelevant
      return
    }
    if to == fromModel {
      Self.log.debug("swap silent (same model) profile=\(toProfileID, privacy: .public) model=\(to, privacy: .public)")
      pendingState = nil
      _ = commit(toProfileID, nil)  // silent path fires no load — result irrelevant
      return
    }
    if preserveExplicitModelSelection {
      Self.log.debug("swap silent (explicit model selection preserved) profile=\(toProfileID, privacy: .public) keep=\(fromModel, privacy: .public)")
      pendingState = nil
      _ = commit(toProfileID, fromModel)  // pin current explicit model; silent path fires no load
      return
    }
    let token = UUID()
    Self.log.info("swap pending confirm token=\(token, privacy: .public) profile=\(toProfileID, privacy: .public) from=\(fromModel, privacy: .public) to=\(to, privacy: .public)")
    // Single assignment — review v3 F2. Replaces the prior pending
    // (if any) atomically; the bound popover binding never sees an
    // intermediate `pending == nil` view. A profile swap loads the
    // profile's stored default, so "Set as default" is not offered
    // (`setAsDefaultProfileID: nil`). On confirm the commit sets the
    // profile AND pins the new default as the chat's model.
    pendingState = PendingState(
      token: token,
      toProfileID: toProfileID,
      fromModelID: fromModel,
      toModelID: to,
      // Confirm = switch + pin the new profile's default.
      commit: { commit(toProfileID, to) },
      // #459 Keep Current = switch + pin the CURRENT model (`fromModel`,
      // non-nil here), no reload — pins `Chat.modelID`, not the deleted
      // `modelOverride`.
      keepCurrentCommit: { commit(toProfileID, fromModel) },
      setAsDefaultProfileID: nil
    )
  }

  /// Entry point from the toolbar model menu. The user picked a
  /// specific model that overrides the active profile's default for
  /// this chat. Same model-identity policy as `requestSwap`: picking
  /// the already-selected model is silent (set the pin, no load); with
  /// NO current model (`fromModel == nil`: engine stopped / unpinned) the
  /// pick is likewise silent with no load (policy 1.5 — nothing to
  /// replace, so a switch-model confirm would be meaningless; #486); any
  /// other model publishes a confirm that offers "Set as default for
  /// this profile" before loading.
  ///
  /// `fromModel` is the chat's CURRENT model selection (#460 single source
  /// of truth — `Chat.modelID` resolved through the profile default), NOT
  /// `center.residentModelID`. `commit` persists the per-chat model to the
  /// picked id (`{ id in chat.modelID = id }`, wired by `ChatScaffoldView`).
  public func requestModelOverride(
    modelID: String,
    activeProfileID: String,
    fromModel: String?,
    commit: @escaping (String) -> Bool
  ) {
    // Fresh interaction — clear any stale set-as-default error (review
    // v2 F2). Covers the already-selected early return below too.
    defaultModelWriteError = nil
    guard let fromModel else {
      // Policy 1.5 (parity with `requestSwap` — #486): the chat has NO
      // current model (engine stopped / unpinned), so there is nothing to
      // REPLACE and a switch-model confirm ("switch from — to X") would be
      // meaningless. Commit the override silently and fire NO load; the model
      // loads later through the normal start gate, never an implicit load
      // here. Without this branch the same-model check below (`modelID == nil`)
      // never catches the no-current case and the model menu raised a spurious
      // confirm whenever there was no current model.
      Self.log.debug("model override silent (no current model to replace) model=\(modelID, privacy: .public)")
      pendingState = nil
      _ = commit(modelID)  // silent path fires no load — result irrelevant
      return
    }
    if modelID == fromModel {
      Self.log.debug("model override silent (already selected) model=\(modelID, privacy: .public)")
      pendingState = nil
      _ = commit(modelID)  // silent path fires no load — result irrelevant
      return
    }
    let token = UUID()
    Self.log.info("model override pending confirm token=\(token, privacy: .public) profile=\(activeProfileID, privacy: .public) from=\(fromModel, privacy: .public) to=\(modelID, privacy: .public)")
    pendingState = PendingState(
      token: token,
      toProfileID: activeProfileID,
      fromModelID: fromModel,
      toModelID: modelID,
      commit: { commit(modelID) },
      // The model-override path has no keep-current outcome (the user
      // explicitly picked a model to LOAD).
      keepCurrentCommit: nil,
      setAsDefaultProfileID: activeProfileID
    )
  }

  /// Confirm the swap whose `PendingSwap.id` matches `token`. Stale
  /// callbacks (token does not match current pending) are silently
  /// dropped after a `.notice` log — review v2 F4. The popover
  /// captures its token at present time and passes it back here, so
  /// a re-entered swap's popover cannot confirm the new (different)
  /// pending by accident.
  ///
  /// `setAsDefault` persists the to-load model onto the pending's
  /// profile when the pending offered the checkbox (model override).
  public func confirm(token: UUID, setAsDefault: Bool) {
    guard let p = pendingState else {
      Self.log.notice("confirm token=\(token, privacy: .public) ignored: no pending")
      return
    }
    guard p.token == token else {
      Self.log.notice("confirm token=\(token, privacy: .public) mismatch (current=\(p.token, privacy: .public)) — stale callback dropped")
      return
    }
    let toModel = p.toModelID
    let toProfile = p.toProfileID
    let commit = p.commit
    // Capture the set-as-default target BEFORE clearing the pending; the
    // persist itself is deferred past the commit gate below so the chat-pin
    // commit is the single authority on whether the swap took effect.
    let setDefaultProfileID = setAsDefault ? p.setAsDefaultProfileID : nil
    pendingState = nil
    // Review F2 (#460): only proceed once the caller durably applied the swap.
    // A failed model-pin save returns false → skip BOTH the set-as-default
    // profile-default write and the load. Otherwise (#487) a failed pin would
    // still durably change the profile's default to a model the chat did not
    // adopt and fire no load — a divergent default surfaced only by the
    // pin-failure toast. The chat-pin commit gates everything that follows.
    guard commit() else { return }
    // Pin committed — now persist the optional "Set as default" choice.
    if let profileID = setDefaultProfileID {
      do {
        try setDefaultModel(profileID, toModel)
        defaultModelWriteError = nil
      } catch {
        // The model still loads below; only the persist failed. Surface
        // it (review F2) — never silent.
        defaultModelWriteError = "Could not set \(toModel) as the default for \(profileID): \(error)"
        Self.log.error("setDefaultModel failed profile=\(profileID, privacy: .public) model=\(toModel, privacy: .public): \(String(describing: error), privacy: .public)")
      }
    } else {
      defaultModelWriteError = nil
    }
    // #469: route the confirmed pick through the engine (re)launch on the
    // pending's profile — start a stopped engine bound to the pick, or
    // rebuild a running engine onto it — instead of a `/v1/models/load` that
    // a stopped engine no-ops and a running engine only acks for its boot
    // model.
    startLoad(modelID: toModel, profileID: toProfile)
  }

  /// Cancel the swap whose `PendingSwap.id` matches `token`. Idempotent
  /// for the matched-token case (re-fire after the pending was
  /// already cleared is a no-op); a stale token from a superseded
  /// pending is logged and dropped.
  public func cancel(token: UUID) {
    guard let p = pendingState else { return }
    guard p.token == token else {
      Self.log.notice("cancel token=\(token, privacy: .public) mismatch (current=\(p.token, privacy: .public)) — stale callback dropped")
      return
    }
    pendingState = nil
    // User moved on — clear any stale set-as-default error (review F2).
    defaultModelWriteError = nil
  }

  /// Third profile-swap outcome (#459, ported onto #460's single authority):
  /// switch to the new profile but KEEP the chat's current concrete model
  /// loaded — pin `Chat.modelID` to the current model (`fromModelID`) AND
  /// switch the profile, with NO reload (no `startLoad`/`loadModel`). The new
  /// profile's stored default is left untouched. Under the authority this is
  /// just the swap `commit` with the CURRENT model as the pin (instead of the
  /// new default), so it writes `Chat.modelID`, not the removed
  /// `viewModel.modelOverride`. Mirrors `confirm`/`cancel`'s token-checked
  /// stale-drop + single `pendingState = nil` discipline; the pin+profile
  /// write is F2-atomic (a failed pin leaves the profile unswitched).
  ///
  /// Only valid on the profile-swap path with a current model
  /// (`canKeepCurrentModel` ⇔ `keepCurrentCommit != nil`). A call against a
  /// model-override pending is dropped — the popover does not offer the
  /// button there, so this is defensive.
  public func keepCurrentModel(token: UUID) {
    guard let p = pendingState else {
      Self.log.notice("keepCurrentModel token=\(token, privacy: .public) ignored: no pending")
      return
    }
    guard p.token == token else {
      Self.log.notice("keepCurrentModel token=\(token, privacy: .public) mismatch (current=\(p.token, privacy: .public)) — stale callback dropped")
      return
    }
    guard let keepCurrent = p.keepCurrentCommit else {
      Self.log.notice("keepCurrentModel token=\(token, privacy: .public) ignored: not a profile-swap pending with a current model")
      return
    }
    Self.log.info("swap keep-current token=\(token, privacy: .public) profile=\(p.toProfileID, privacy: .public) keepModel=\(p.fromModelID ?? "—", privacy: .public) (no reload)")
    pendingState = nil
    // User moved on — clear any stale set-as-default error (review F2).
    defaultModelWriteError = nil
    // Switch the profile AND pin the current model as the chat's selection,
    // with NO startLoad — the resident/loading model stays and the new
    // profile's default is never loaded.
    _ = keepCurrent()
  }

  /// Dismissal-binding entry. SwiftUI's `.popover(isPresented:)`
  /// setter fires with `false` on click-outside / Esc but has no
  /// per-popover token to pass. This method clears the currently-
  /// pending swap unconditionally, treating "popover went away" as
  /// "user cancelled whatever was on screen." Re-entered swaps that
  /// happen in the same tick are SwiftUI's identity-tracking
  /// problem (the popover will simply re-present for the new item).
  public func dismissCurrentPending() {
    guard pendingState != nil else { return }
    pendingState = nil
    // User moved on — clear any stale set-as-default error (review F2).
    defaultModelWriteError = nil
  }

  /// Acknowledge / dismiss the surfaced set-as-default write error
  /// (review v2 F2) — mirrors `PersistenceStatus.acknowledgeLastError`
  /// so a UI affordance can clear the toolbar indicator explicitly.
  public func acknowledgeDefaultModelWriteError() {
    defaultModelWriteError = nil
  }

  /// #488: surface a DEFERRED pick's launch failure through the same
  /// channel as a direct pick's. A pick queued while the engine was
  /// mid-transition (`ActiveModelServeExecutor.deferredPick`) re-serves
  /// outside any `startLoad` Task, so its failure has no awaiting caller —
  /// the executor reports it here so the toolbar copy is identical either
  /// way. Mirrors `startLoad`'s catch verbatim.
  public func reportServeFailure(modelID: String, error: Error) {
    serveModelError = "Couldn’t load \(modelID): \(error)"
    Self.log.error("deferred serveModel failed model=\(modelID, privacy: .public): \(String(describing: error), privacy: .public)")
  }

  /// Direct-load entry — used when the user picks a model in the
  /// model pull-down (no confirmation needed; user explicitly chose).
  /// Short-circuits when the target is already resident and no load
  /// is in flight (review v1 F5) so picking the current model from
  /// the menu does not flash the indicator for a no-op reload.
  ///
  /// `profileID` is the active chat profile the engine (re)launch binds the
  /// model to (#469); the pre-#469 `/v1/models/load` path did not need it.
  public func loadDirect(modelID: String, profileID: String) {
    // User moved on to an explicit load — clear any stale set-as-default
    // error (review F2).
    defaultModelWriteError = nil
    if center.residentModelID == modelID {
      Self.log.debug("loadDirect short-circuit: model already resident id=\(modelID, privacy: .public)")
      return
    }
    startLoad(modelID: modelID, profileID: profileID)
  }

  /// Make the engine serve `modelID` (#469): route through the status-aware
  /// engine (re)launch executor — start a stopped engine, restart a running
  /// one onto a different model, or no-op when already resident — because v1
  /// pie binds the served model at boot and `/v1/models/load` cannot swap it
  /// (the endpoint is gone). A thrown executor failure the status poll won't
  /// reflect (a resolver reject) surfaces via `serveModelError`.
  private func startLoad(modelID: String, profileID: String) {
    // Clear synchronously BEFORE spawning the Task (review v2 F2): if the clear
    // rode inside the async Task, two rapid picks could interleave — pick 2's
    // clear wiping pick 1's surfaced error, or pick 1's late failure
    // resurrecting after pick 2 already succeeded. A synchronous clear at the
    // call point makes the dismissal deterministic; only the failure assignment
    // stays inside the Task.
    serveModelError = nil
    Task { @MainActor in
      do {
        try await serveModel(modelID, profileID)
      } catch {
        // #477: tooltip/accessibility copy comes from the taxonomy; the
        // raw error stays in the log line below.
        if let e = error as? EngineError {
          serveModelError = "Couldn’t load \(modelID). \(EngineProblem(statusCode: e.code, rawMessage: e.message).message)"
        } else {
          serveModelError = "Couldn’t load \(modelID)."
        }
        Self.log.error("serveModel failed model=\(modelID, privacy: .public) profile=\(profileID, privacy: .public): \(String(describing: error), privacy: .public)")
      }
    }
  }

  /// Inert coordinator for previews + snapshot tests. Uses
  /// `MockEngineClient` so SwiftUI bodies never accidentally hit a
  /// network during render, and a default-init `AppPreferences` so the
  /// process's real defaults aren't mutated by a preview pass. The
  /// returned coordinator publishes `pending == nil` and treats every
  /// `requestSwap` as silent (no model map injected) — exactly the
  /// pre-Phase-3.6 toolbar behavior.
  ///
  /// `#if DEBUG`-gated (review v1 F9) so a release build that forgets
  /// to inject a real coordinator fails loudly at the call site
  /// instead of silently using an orphan instance the rest of the
  /// app does not observe.
  #if DEBUG
  @MainActor
  public static func previewDefault() -> ProfileSwapCoordinator {
    ProfileSwapCoordinator(
      center: ModelLoadCenter(),
      serveModel: { _, _ in }
    )
  }
  #endif
}
