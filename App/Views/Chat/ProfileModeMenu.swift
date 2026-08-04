import SwiftUI

/// The chat-mode picker, presented directly above the composer's input field.
///
/// "Mode" and "profile" are the same choice in this app: `sendAssistantTurn`
/// routes a turn by reading the selected profile's config — a profile carrying
/// `treeOfThought` dispatches the tree search, one carrying `bestOfN` dispatches
/// a candidate round, and anything else is a normal chat completion. The
/// built-in profiles are named accordingly (Chat, Tree of Thought, Best of N,
/// JSON Think), so this one menu is what the user experiences as picking a mode.
///
/// It lived in `ContentToolbar` at the top of the window. Moving it next to the
/// input puts the choice where the sentence it applies to is being written,
/// rather than in window chrome the eye leaves once typing starts.
///
/// Extracted rather than inlined into `ComposerView` because selecting a profile
/// is not a composer concern: it can force a model swap, which needs the swap
/// coordinator, the chat's pinned model and the follow-default preference.
/// Keeping that here leaves the composer knowing only that it renders a control.
struct ProfileModeMenu: View {
  @ObservedObject var viewModel: ChatTranscriptViewModel
  let availableProfiles: [String]
  let profileDisplayName: (String) -> String
  /// #460: the chat's persisted model pin, and the active profile's default.
  /// Together they resolve the "from model" the swap policy compares against.
  let selectedModelID: String?
  let profileDefaultModel: String?
  let followProfileDefaultModel: Bool
  let commitSwap: (String, String?) -> Bool
  @ObservedObject var swapCoordinator: ProfileSwapCoordinator

  var body: some View {
    Menu {
      ForEach(availableProfiles, id: \.self) { id in
        Button { selectProfile(id) } label: {
          Text(profileDisplayName(id))
        }
        .accessibilityIdentifier(id)
        .accessibilityLabel(profileDisplayName(id))
      }
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "person.crop.circle")
        Text(profileDisplayName(viewModel.selectedProfileID))
      }
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    // Identifier deliberately unchanged despite the move: three cases in
    // S459_ProfileSwapKeepCurrentGUITests drive `menuButtons["toolbar.profile"]`,
    // and those are GUI tests that need a signed app and a seated session to
    // run. Renaming it blind — without being able to watch the suite go green —
    // would trade a cosmetic inaccuracy for a real risk of silently breaking
    // the swap-policy coverage. Rename it and S459 together, in one change.
    .accessibilityIdentifier("toolbar.profile")
    // Anchor for the swap-confirmation popover. #582: a coordinator-owned
    // `.applicationDefined` NSPopover replaces a transient SwiftUI `.popover`,
    // which AppKit auto-closed on resign-key — silently dropping a pending swap
    // when the user Cmd-Tabbed. The host captures the pending token at present
    // time (review v2 F4) and hands it back through `confirm`/`cancel`/
    // `keepCurrentModel`, so a stale callback from a superseded swap is
    // token-mismatched and dropped.
    //
    // The anchor moves with the menu: the popover points at the control the
    // user clicked, which is now above the composer rather than in the toolbar.
    .background(
      ProfileSwapPopoverHost(
        pending: swapCoordinator.pending,
        onConfirm: { token, setAsDefault in
          swapCoordinator.confirm(token: token, setAsDefault: setAsDefault)
        },
        onCancel: { token in swapCoordinator.cancel(token: token) },
        onKeepCurrent: { token in swapCoordinator.keepCurrentModel(token: token) }
      )
    )
#if DEBUG
    // Moved here with the menu: the seam drives this control, so it has to live
    // where the control does or S459 would be driving a toolbar that no longer
    // has a profile picker.
    .task(id: testAutoProfilePickTaskID) {
      await runTestAutoProfilePickIfNeeded()
    }
#endif
  }

  private var effectiveModelID: String? {
    ContentToolbar.effectiveModelID(selectedModelID: selectedModelID,
                                    profileDefaultModel: profileDefaultModel)
  }

  private func selectProfile(_ id: String) {
    // #460: compare against the chat's CURRENT model (`effectiveModelID`), not
    // engine residency. `commitSwap` persists the profile and — only on a
    // confirm-and-switch — the new pinned model; a silent swap preserves the
    // current model (`pinModel == nil`).
    // #459 "Keep Current Model" needs no `setOverride` under the single
    // authority: the coordinator builds the keep-current action from this same
    // `commitSwap`, pinning the CURRENT model (`fromModel`) instead of the new
    // default — both write `Chat.modelID`.
    swapCoordinator.requestSwap(
      toProfileID: id,
      fromModel: effectiveModelID,
      preserveExplicitModelSelection: ContentToolbar.shouldPreserveExplicitModelSelection(
        selectedModelID: selectedModelID,
        followProfileDefaultModel: followProfileDefaultModel),
      commit: commitSwap
    )
  }

#if DEBUG
  private static var testAutoPickProfileID: String? {
    guard let id = ProcessInfo.processInfo.environment["PIE_TEST_AUTO_PICK_PROFILE"],
          !id.isEmpty
    else { return nil }
    return id
  }

  private var testAutoProfilePickTaskID: String {
    // #582: the production swap popover is now a coordinator-owned
    // `.applicationDefined` NSPopover that survives the window resigning key,
    // so the seam no longer tracks pending-presence to re-raise a popover that
    // a focus blip killed. #579 added that re-raise because the old transient
    // `.popover` died on resign-key under a contended seated session — but that
    // re-raise also MASKED the real production gap. With the gap fixed at the
    // source, the auto-pick fires exactly once per stable pendable state, and
    // S459's resign-key-survival case asserts the production NSPopover itself.
    //
    // #581 — CONSTRAINT (do not re-key this on `swapCoordinator.pending`):
    // keying on pending-presence is what made #579's seam incompatible with a
    // Cancel-outcome assertion. `cancel(token:)` / `dismissCurrentPending()`
    // clear `pending` WITHOUT mutating `selectedProfileID` (only `commitSwap`
    // sets it), so a pending-keyed taskID flips back to its pendable value the
    // instant a deliberate Cancel clears the popover — re-raising the swap once
    // and bouncing the popover back into a test that asserted it stayed
    // dismissed. Keying on the stable `(profile, model)` selection instead
    // means a Cancel leaves the axis untouched (no re-fire), a Confirm trips
    // the `selectedProfileID != target` guard (no re-fire), so every outcome —
    // Confirm, Keep-Current, AND Cancel — is safe to assert. A future
    // cancel-driving GUI scenario relies on this; do not reintroduce pending.
    [
      Self.testAutoPickProfileID ?? "",
      viewModel.selectedProfileID,
      selectedModelID ?? "",
    ].joined(separator: "|")
  }

  @MainActor
  private func runTestAutoProfilePickIfNeeded() async {
    guard let target = Self.testAutoPickProfileID,
          selectedModelID != nil,
          viewModel.selectedProfileID != target,
          swapCoordinator.pending == nil
    else { return }

    // Settle briefly so a still-resolving model selection doesn't race the
    // pick. NO one-shot latch: the latch-before-await was the solo flake —
    // `.task(id:)` cancels this task whenever the id changes (e.g.
    // `selectedModelID` resolves nil→X during the sleep), so a latch set here
    // permanently skipped the cancelled `selectProfile` and the popover never
    // appeared. Re-checking after the await fires exactly once per stable
    // pendable state instead.
    try? await Task.sleep(nanoseconds: 300_000_000)
    guard !Task.isCancelled,
          viewModel.selectedProfileID != target,
          swapCoordinator.pending == nil
    else { return }
    selectProfile(target)
  }
#endif
}
