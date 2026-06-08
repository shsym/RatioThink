import Foundation
import Combine
import os

/// Decision unit for "user picked profile X (or model Y) — should we
/// just swap, or confirm first?" Decoupled from any specific toolbar
/// view so the same coordinator can drive future entry points
/// (sidebar quick-switcher, command palette).
///
/// Policy ( — every real model load is always confirmed; the old
/// per-model skip-set is gone):
///   1. New profile's model unknown → swap silently, fire NO load. A
///      later send with nothing resident routes through the no-model
///      confirm gate; there is no deferred silent load here.
///   1.5. NO model is currently resident (engine stopped / nothing loaded)
///      → swap silently, fire NO load. There is no resident model to
///      REPLACE, so a swap-confirm would be a meaningless "swap from — to
///      X". The model loads later through the normal start gate.
///   2. New profile's model == currently-resident model → swap silently.
///   3. Otherwise → publish a `PendingSwap` so the toolbar can present
///      `ProfileSwapPopover`. The popover calls `confirm(token:setAsDefault:)`
///      or `cancel(token:)` based on the user's choice.
///
/// Model overrides from the toolbar model menu go through
/// `requestModelOverride`, which uses the same model-identity policy but
/// also offers "Set as default for this profile" on confirm.
///
/// Source-of-truth invariant (review v1 F4): comparisons against
/// "the model that is loaded right now" use `center.residentModelID`
/// — period. We do not look up the model of the from-profile and
/// fall back to resident; doing so collapses two distinct sources
/// and would silently skip the popover in cases the dialog was
/// designed to catch (profile→profile map says different model,
/// but engine happens to have that model resident).
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
    /// Value handed to `commit` on confirm. For a profile swap this is
    /// the profile id (commit sets the selected profile); for a model
    /// override it is the model id (commit sets the per-chat override).
    let commitArgument: String
    let commit: (String) -> Void
    /// Sets the per-chat model override (`{ id in viewModel.modelOverride
    /// = id }`). Used ONLY by `keepCurrentModel` to pin the resident model
    /// A onto the newly-switched profile without a reload. A no-op for the
    /// model-override path (which has no keep-current outcome). Kept a pure
    /// UI assignment per the `commit` caller contract.
    let setOverride: (String?) -> Void
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
        // Keep-current is the profile-swap-only third outcome: offered
        // when this is NOT a model-override pending and a resident model
        // A exists to keep.
        canKeepCurrentModel: setAsDefaultProfileID == nil && fromModelID != nil
      )
    }
  }

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

  private let center: ModelLoadCenter
  private let engine: EngineClient
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
    engine: EngineClient,
    modelForProfile: @escaping (String) -> String? = { _ in nil },
    setDefaultModel: @escaping (_ profileID: String, _ model: String) throws -> Void = { _, _ in }
  ) {
    self.center = center
    self.engine = engine
    self.modelForProfile = modelForProfile
    self.setDefaultModel = setDefaultModel
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
    engine: EngineClient,
    profileStore: ProfileStore
  ) {
    self.init(
      center: center,
      engine: engine,
      modelForProfile: { [weak profileStore] in profileStore?.model(forProfileID: $0) },
      setDefaultModel: { [weak profileStore] profileID, model in
        // Propagate the throw so `confirm` surfaces it via
        // `defaultModelWriteError` (review F2) rather than logging only.
        try profileStore?.setModel(model, forProfileID: profileID)
      }
    )
  }

  /// Entry point from the profile menu. `commit` is the assignment
  /// the toolbar would have made directly (e.g.
  /// `{ id in viewModel.selectedProfileID = id }`); deferring through
  /// here lets the coordinator gate it behind the popover when needed.
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
  /// it. Callers MUST keep `commit` a pure UI assignment (e.g.
  /// `{ id in viewModel.selectedProfileID = id }`) with no side
  /// effects that need explicit teardown if the swap is abandoned.
  /// If a caller needs an abandonment signal, plumb it through
  /// their own state — the coordinator deliberately does not invoke
  /// abandoned commits because doing so would commit a swap the
  /// user never confirmed.
  /// `setOverride` sets the per-chat model override (`{ id in
  /// viewModel.modelOverride = id }`) — used only when the user picks the
  /// new "Keep Current Model" outcome (#459), to pin the resident model A
  /// onto the switched profile without a reload. Defaulted to a no-op so the
  /// many existing two-outcome callers/tests are unchanged; the toolbar wires
  /// the real assignment. Must stay a pure UI assignment per the `commit`
  /// caller contract.
  public func requestSwap(
    toProfileID: String,
    commit: @escaping (String) -> Void,
    setOverride: @escaping (String?) -> Void = { _ in }
  ) {
    if let prior = pendingState {
      Self.log.notice("re-entrant requestSwap: discarding prior pending=\(prior.toProfileID, privacy: .public) for new=\(toProfileID, privacy: .public); prior commit is dropped without invocation (review v3 F4)")
    }
    // A fresh interaction begins — clear any stale set-as-default error
    // so it can't linger in the toolbar (review v2 F2).
    defaultModelWriteError = nil
    let toModelID = modelForProfile(toProfileID)
    let fromModelID = center.residentModelID

    guard let to = toModelID else {
      // Policy 1: unknown target model — commit the profile selection
      // but fire NO load. : there is no deferred silent load; a
      // later send with nothing resident routes through the no-model
      // confirm gate (ChatScaffoldView), never an implicit load here.
      Self.log.debug("swap silent (unknown target model) profile=\(toProfileID, privacy: .public)")
      pendingState = nil
      commit(toProfileID)
      return
    }
    guard let fromModelID else {
      // Policy 1.5: NOTHING is resident (engine stopped / no model loaded),
      // so there is no model to REPLACE — a swap-confirm ("swap from — to X")
      // is meaningless. This is the engine-stopped re-select case: with the
      // engine down `residentModelID` is nil (the lifecycle clears it on the
      // leave-`.running` edge), so the same-model check below would never
      // catch it and the swap would prompt for a no-op. Commit the profile
      // selection silently and fire NO load; the model loads later through
      // the normal start gate, never an implicit load here.
      Self.log.debug("swap silent (no resident model to replace) profile=\(toProfileID, privacy: .public) to=\(to, privacy: .public)")
      pendingState = nil
      commit(toProfileID)
      return
    }
    if to == fromModelID {
      Self.log.debug("swap silent (same model) profile=\(toProfileID, privacy: .public) model=\(to, privacy: .public)")
      pendingState = nil
      commit(toProfileID)
      return
    }
    let token = UUID()
    Self.log.info("swap pending confirm token=\(token, privacy: .public) profile=\(toProfileID, privacy: .public) from=\(fromModelID, privacy: .public) to=\(to, privacy: .public)")
    // Single assignment — review v3 F2. Replaces the prior pending
    // (if any) atomically; the bound popover binding never sees an
    // intermediate `pending == nil` view. A profile swap loads the
    // profile's stored default, so "Set as default" is not offered
    // (`setAsDefaultProfileID: nil`).
    pendingState = PendingState(
      token: token,
      toProfileID: toProfileID,
      fromModelID: fromModelID,
      toModelID: to,
      commitArgument: toProfileID,
      commit: commit,
      setOverride: setOverride,
      setAsDefaultProfileID: nil
    )
  }

  /// Entry point from the toolbar model menu. The user picked a
  /// specific model that overrides the active profile's default for
  /// this chat. Same model-identity policy as `requestSwap`: picking
  /// the already-resident model is silent (set the override, no load);
  /// any other model publishes a confirm that offers "Set as default
  /// for this profile" before loading. `commit` sets the per-chat
  /// override (`{ id in viewModel.modelOverride = id }`).
  public func requestModelOverride(
    modelID: String,
    activeProfileID: String,
    commit: @escaping (String) -> Void
  ) {
    // Fresh interaction — clear any stale set-as-default error (review
    // v2 F2). Covers the already-resident early return below too.
    defaultModelWriteError = nil
    let fromModelID = center.residentModelID
    if modelID == fromModelID {
      Self.log.debug("model override silent (already resident) model=\(modelID, privacy: .public)")
      pendingState = nil
      commit(modelID)
      return
    }
    let token = UUID()
    Self.log.info("model override pending confirm token=\(token, privacy: .public) profile=\(activeProfileID, privacy: .public) from=\(fromModelID ?? "—", privacy: .public) to=\(modelID, privacy: .public)")
    pendingState = PendingState(
      token: token,
      toProfileID: activeProfileID,
      fromModelID: fromModelID,
      toModelID: modelID,
      commitArgument: modelID,
      commit: commit,
      // The model-override path has no keep-current outcome (the user
      // explicitly picked a model to load), so this is never invoked.
      setOverride: { _ in },
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
    if setAsDefault, let profileID = p.setAsDefaultProfileID {
      do {
        try setDefaultModel(profileID, p.toModelID)
        defaultModelWriteError = nil
      } catch {
        // The model still loads below; only the persist failed. Surface
        // it (review F2) — never silent.
        defaultModelWriteError = "Could not set \(p.toModelID) as the default for \(profileID): \(error)"
        Self.log.error("setDefaultModel failed profile=\(profileID, privacy: .public) model=\(p.toModelID, privacy: .public): \(String(describing: error), privacy: .public)")
      }
    } else {
      defaultModelWriteError = nil
    }
    let toModel = p.toModelID
    let arg = p.commitArgument
    let commit = p.commit
    pendingState = nil
    commit(arg)
    startLoad(modelID: toModel)
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

  /// Third profile-swap outcome (#459): switch to the new profile but KEEP
  /// the already-resident model A loaded — commit the profile switch AND set
  /// the per-chat model override to the pending's `fromModelID` (A), with NO
  /// reload (no `startLoad`/`loadModel`). The profile's stored default B is
  /// left untouched. Mirrors `confirm`/`cancel`'s token-checked stale-drop +
  /// single `pendingState = nil` discipline.
  ///
  /// Only valid on the profile-swap path with a resident model
  /// (`canKeepCurrentModel`). A call against a model-override pending, or
  /// with no resident A, is dropped — the popover does not offer the button
  /// in those cases, so this is defensive.
  public func keepCurrentModel(token: UUID) {
    guard let p = pendingState else {
      Self.log.notice("keepCurrentModel token=\(token, privacy: .public) ignored: no pending")
      return
    }
    guard p.token == token else {
      Self.log.notice("keepCurrentModel token=\(token, privacy: .public) mismatch (current=\(p.token, privacy: .public)) — stale callback dropped")
      return
    }
    guard p.setAsDefaultProfileID == nil, let keep = p.fromModelID else {
      Self.log.notice("keepCurrentModel token=\(token, privacy: .public) ignored: not a profile-swap pending with a resident model")
      return
    }
    Self.log.info("swap keep-current token=\(token, privacy: .public) profile=\(p.toProfileID, privacy: .public) keepModel=\(keep, privacy: .public) (no reload)")
    let arg = p.commitArgument
    let commit = p.commit
    let setOverride = p.setOverride
    pendingState = nil
    // User moved on — clear any stale set-as-default error (review F2).
    defaultModelWriteError = nil
    commit(arg)            // switch profile: selectedProfileID = new profile
    setOverride(keep)      // serve A under the new profile — no reload
    // Deliberately NO startLoad: the resident model A stays loaded and the
    // new profile's stored default B is never touched.
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

  /// Direct-load entry — used when the user picks a model in the
  /// model pull-down (no confirmation needed; user explicitly chose).
  /// Short-circuits when the target is already resident and no load
  /// is in flight (review v1 F5) so picking the current model from
  /// the menu does not flash the indicator for a no-op reload.
  public func loadDirect(modelID: String) {
    // User moved on to an explicit load — clear any stale set-as-default
    // error (review F2).
    defaultModelWriteError = nil
    if !center.isLoading, center.residentModelID == modelID {
      Self.log.debug("loadDirect short-circuit: model already resident id=\(modelID, privacy: .public)")
      return
    }
    startLoad(modelID: modelID)
  }

  private func startLoad(modelID: String) {
    let engine = self.engine
    center.load(modelID: modelID) {
      engine.loadModel(modelID)
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
      engine: MockEngineClient()
    )
  }
  #endif
}
