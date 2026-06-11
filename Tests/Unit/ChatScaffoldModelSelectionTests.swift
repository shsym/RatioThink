import XCTest
@testable import RatioThink

@MainActor
final class ChatScaffoldModelSelectionTests: XCTestCase {
  func test_nothing_resolvable_returns_nil_so_send_is_blocked() {
    // : no hidden fallback. With no pinned model and no profile default,
    // resolution yields nil — the caller blocks the send and shows the
    // no-model confirm rather than silently loading something.
    let selected = ChatScaffoldView.requestModelID(
      selectedModelID: nil,
      profileDefaultModel: nil
    )
    XCTAssertNil(selected)
  }

  func test_placeholder_models_include_seeded_default_profile_model() throws {
    let seededProfile = try Profile.parse(toml: ProfileStore.defaultChatTOML)

    XCTAssertTrue(
      ChatTranscriptViewModel.placeholderModels.contains(try XCTUnwrap(seededProfile.model)),
      "placeholderModels must include the seeded default profile model so the first-launch model picker matches chat.toml"
    )
  }

  // MARK: - #460 single-source selection resolution

  func test_pinned_model_takes_precedence_over_profile_default() {
    XCTAssertEqual(
      ChatScaffoldView.requestModelID(
        selectedModelID: "pinned-model",
        profileDefaultModel: "profile-default"
      ),
      "pinned-model"
    )
  }

  func test_unpinned_chat_falls_back_to_profile_default() {
    // The single source of truth resolves an UNPINNED chat to the active
    // profile's default — never engine residency.
    XCTAssertEqual(
      ChatScaffoldView.requestModelID(
        selectedModelID: nil,
        profileDefaultModel: "profile-default"
      ),
      "profile-default"
    )
  }

  // MARK: - AC4: model label is stable / derives from the selection authority

  func test_label_shows_pinned_model_leaf() {
    XCTAssertEqual(
      ContentToolbar.modelLabel(selectedModelID: "org/Repo/Big-Model-Q8.gguf",
                                profileDefaultModel: "org/Other/Other.gguf"),
      ModelDisplayName.leaf("org/Repo/Big-Model-Q8.gguf"),
      "a pinned model must render its own leaf, independent of the profile default"
    )
  }

  func test_label_falls_back_to_profile_default_leaf_when_unpinned() {
    XCTAssertEqual(
      ContentToolbar.modelLabel(selectedModelID: nil,
                                profileDefaultModel: "org/Other/Other.gguf"),
      ModelDisplayName.leaf("org/Other/Other.gguf")
    )
  }

  func test_label_is_profile_default_text_only_when_no_model_at_all() {
    XCTAssertEqual(
      ContentToolbar.modelLabel(selectedModelID: nil, profileDefaultModel: nil),
      "Profile default"
    )
  }

  /// AC4 stability: a no-default profile switch PRESERVES the pinned model
  /// (the coordinator's silent path leaves `Chat.modelID` untouched — proven
  /// in ProfileSwapCoordinatorTests), so the label is identical before and
  /// after the switch even though the new profile has no default of its own.
  func test_label_is_stable_across_a_no_default_profile_switch() {
    let pinned = "org/Repo/Pinned.gguf"
    let before = ContentToolbar.modelLabel(selectedModelID: pinned,
                                           profileDefaultModel: "org/A/Default-A.gguf")
    // After switching to a profile with no default, the pinned model is
    // preserved and the profile default is now nil.
    let after = ContentToolbar.modelLabel(selectedModelID: pinned,
                                          profileDefaultModel: nil)
    XCTAssertEqual(before, after, "the model label must not reset on a no-default profile switch")
  }

  // MARK: - review F1: residency seed adopts the served model ONLY when it is
  // this chat's profile default — never the engine's global resident model.

  func test_seed_adopts_served_model_when_it_is_the_profile_default() {
    XCTAssertEqual(
      ChatScaffoldView.seededModelID(
        currentPin: nil, servedID: "org/A/Default.gguf",
        profileDefault: "org/A/Default.gguf", isLoading: false),
      "org/A/Default.gguf",
      "unpinned + served == profile default → seed it"
    )
  }

  func test_seed_does_not_adopt_a_served_model_that_differs_from_profile_default() {
    // The engine serves a global model that is NOT this chat's default
    // (e.g. another chat loaded it). Seeding it would durably pin the wrong
    // model and freeze it there — the exact defect F1 flags.
    XCTAssertNil(
      ChatScaffoldView.seededModelID(
        currentPin: nil, servedID: "org/Other/Resident.gguf",
        profileDefault: "org/A/Default.gguf", isLoading: false),
      "unpinned + served != profile default → do NOT seed (follow the profile default)"
    )
  }

  func test_seed_never_overwrites_an_explicit_pin() {
    XCTAssertNil(
      ChatScaffoldView.seededModelID(
        currentPin: "org/Pinned/Pick.gguf", servedID: "org/Pinned/Pick.gguf",
        profileDefault: "org/Pinned/Pick.gguf", isLoading: false),
      "already pinned → never overwrite, even when everything agrees"
    )
  }

  func test_seed_is_a_noop_while_a_load_is_in_flight() {
    XCTAssertNil(
      ChatScaffoldView.seededModelID(
        currentPin: nil, servedID: "org/A/Default.gguf",
        profileDefault: "org/A/Default.gguf", isLoading: true),
      "loading → no-op (the load's target is the user's choice, not yet served)"
    )
  }

  func test_seed_is_a_noop_when_nothing_is_served() {
    XCTAssertNil(
      ChatScaffoldView.seededModelID(
        currentPin: nil, servedID: nil,
        profileDefault: "org/A/Default.gguf", isLoading: false))
  }

  // MARK: - #501 centralization: the pin-over-default sites delegate to the
  // single resolver (`ModelTarget.resolve`) with identical results. The
  // precedence itself is owned and exhaustively tested by `ModelTargetTests`
  // (SPM); these guard that each folded call site stays a thin pass-through.

  /// The pin/default matrix the resolver covers — pin beats default; blank/nil
  /// counts as absent; nothing resolvable is `nil`.
  private static let pinDefaultMatrix: [(pin: String?, def: String?)] = [
    ("pinned-model", "profile-default"),  // pin wins
    (nil, "profile-default"),             // unpinned → default
    ("pinned-model", nil),                // pinned, no default
    (nil, nil),                           // nothing → nil
  ]

  func test_requestModelID_equals_ModelTarget_resolve() {
    // `requestModelID` IS the resolver's pick → default → nil — no parallel
    // send-model override (#504 retired `PIE_TEST_CHAT_MODEL`).
    for c in Self.pinDefaultMatrix {
      XCTAssertEqual(
        ChatScaffoldView.requestModelID(
          selectedModelID: c.pin, profileDefaultModel: c.def),
        ModelTarget.resolve(selectedModelID: c.pin, profileDefault: c.def)?.modelID,
        "requestModelID must equal ModelTarget.resolve for pin=\(String(describing: c.pin)) default=\(String(describing: c.def))"
      )
    }
  }

  func test_effectiveModelID_equals_ModelTarget_resolve() {
    // The swap policy's "current model" is the same pin-over-default pick.
    for c in Self.pinDefaultMatrix {
      XCTAssertEqual(
        ContentToolbar.effectiveModelID(
          selectedModelID: c.pin, profileDefaultModel: c.def),
        ModelTarget.resolve(selectedModelID: c.pin, profileDefault: c.def)?.modelID,
        "effectiveModelID must equal ModelTarget.resolve for pin=\(String(describing: c.pin)) default=\(String(describing: c.def))"
      )
    }
  }

  func test_effectiveModelID_pins_over_default_and_nils_when_empty() {
    XCTAssertEqual(
      ContentToolbar.effectiveModelID(selectedModelID: "pinned-model",
                                      profileDefaultModel: "profile-default"),
      "pinned-model")
    XCTAssertEqual(
      ContentToolbar.effectiveModelID(selectedModelID: nil,
                                      profileDefaultModel: "profile-default"),
      "profile-default")
    XCTAssertNil(
      ContentToolbar.effectiveModelID(selectedModelID: nil, profileDefaultModel: nil))
  }

  func test_profile_swap_preserves_explicit_pin_by_default() {
    XCTAssertTrue(
      ContentToolbar.shouldPreserveExplicitModelSelection(
        selectedModelID: "pinned-model",
        followProfileDefaultModel: false),
      "a concrete model selection should suppress later profile-default swap prompts by default")
  }

  func test_profile_swap_does_not_preserve_unpinned_app_run_state() {
    XCTAssertFalse(
      ContentToolbar.shouldPreserveExplicitModelSelection(
        selectedModelID: nil,
        followProfileDefaultModel: false),
      "a fresh app-run/chat with no explicit concrete row selected should keep follow-default behavior")
  }

  func test_follow_profile_default_toggle_reenables_compatibility_prompting() {
    XCTAssertFalse(
      ContentToolbar.shouldPreserveExplicitModelSelection(
        selectedModelID: "pinned-model",
        followProfileDefaultModel: true),
      "the compatibility toggle should let profile changes ask/suggest the destination default again")
  }

  // MARK: - Review v1 F1: toolbar concrete picks compare against effective model

  func test_toolbar_model_pick_from_unpinned_profile_default_raises_and_loads_override() async {
    let center = ModelLoadCenter(initialResident: "profile-default-A")
    let coord = ProfileSwapCoordinator(
      center: center,
      modelForProfile: { _ in nil },
      serveModel: { modelID, _ in center.reconcileEngineResident(modelID) }
    )
    let option = ToolbarModelOptions.Option(
      slug: "picked-model-B",
      displayName: "picked-model-B",
      source: nil,
      isCurrent: false,
      isProfileDefault: false
    )
    var committed: String?

    ContentToolbar.performModelSelection(
      option,
      selectedModelID: nil,
      profileDefaultModel: "profile-default-A",
      activeProfileID: "chat",
      swapCoordinator: coord,
      commitModel: { committed = $0; return true },
      onUseProfileDefault: {}
    )

    XCTAssertNil(committed, "cross-model pick must wait for explicit confirmation")
    guard let token = coord.pending?.id else {
      return XCTFail("unpinned default A -> pick B must raise the override confirm instead of silently pinning")
    }
    coord.confirm(token: token, setAsDefault: false)
    await waitUntil(timeout: 2.0) { center.residentModelID == "picked-model-B" }
    XCTAssertEqual(committed, "picked-model-B")
    XCTAssertEqual(center.residentModelID, "picked-model-B",
                   "confirming the toolbar pick must execute the override serve path")
  }

  func test_toolbar_model_pick_with_no_resolvable_model_stays_silent_and_does_not_load() {
    let center = ModelLoadCenter()
    let coord = ProfileSwapCoordinator(
      center: center,
      modelForProfile: { _ in nil },
      serveModel: { modelID, _ in center.reconcileEngineResident(modelID) }
    )
    let option = ToolbarModelOptions.Option(
      slug: "picked-model",
      displayName: "picked-model",
      source: nil,
      isCurrent: false,
      isProfileDefault: false
    )
    var committed: String?

    ContentToolbar.performModelSelection(
      option,
      selectedModelID: nil,
      profileDefaultModel: nil,
      activeProfileID: "chat",
      swapCoordinator: coord,
      commitModel: { committed = $0; return true },
      onUseProfileDefault: {}
    )

    XCTAssertEqual(committed, "picked-model",
                   "with no effective current model, the intentional silent branch still just pins the pick")
    XCTAssertNil(coord.pending)
    XCTAssertNil(center.residentModelID,
                 "no-resolvable-model picks must not serve until the normal start gate runs")
  }

  // MARK: - #527 send-time explicit pin vs resident engine mismatch

  func test_send_gate_blocks_explicit_pin_that_differs_from_resident_model() throws {
    let decision = ChatScaffoldView.sendGateDecision(
      engineStatus: .running(EngineSessionSnapshot(
        port: try XCTUnwrap(EnginePort(exactly: 48484)),
        profileID: "chat",
        servedModelID: "resident-model")),
      selectedModelID: "pinned-model",
      profileDefaultModel: "profile-default",
      residentModelID: "resident-model"
    )

    XCTAssertEqual(
      decision,
      .pinnedModelMismatch(pinnedModelID: "pinned-model",
                           residentModelID: "resident-model"),
      "an explicit Chat.modelID pin must not send into an engine serving a different model")
  }

  func test_send_gate_allows_explicit_pin_when_it_matches_resident_model() throws {
    let decision = ChatScaffoldView.sendGateDecision(
      engineStatus: .running(EngineSessionSnapshot(
        port: try XCTUnwrap(EnginePort(exactly: 48484)),
        profileID: "chat",
        servedModelID: "pinned-model")),
      selectedModelID: "pinned-model",
      profileDefaultModel: "profile-default",
      residentModelID: "pinned-model"
    )

    XCTAssertEqual(decision, .ready(modelID: "pinned-model"))
  }

  func test_send_gate_does_not_treat_unpinned_profile_default_as_pin_mismatch() throws {
    let decision = ChatScaffoldView.sendGateDecision(
      engineStatus: .running(EngineSessionSnapshot(
        port: try XCTUnwrap(EnginePort(exactly: 48484)),
        profileID: "chat",
        servedModelID: "resident-model")),
      selectedModelID: nil,
      profileDefaultModel: "profile-default",
      residentModelID: "resident-model"
    )

    XCTAssertEqual(
      decision,
      .ready(modelID: "profile-default"),
      "the #527 prompt is scoped to explicit per-chat pins; follow-default gaps remain out of scope for #528")
  }


  // MARK: - #516 review F6: status edge must not fire before residency reconcile

  /// The full ordering the review names: arm with target A; the `.running`
  /// status flip arrives while the chat pin still says A but residency is
  /// unreconciled (the engine may be serving B) → HOLD. Then the reconcile
  /// lands: residency B (relaunch booted a different model) → DISARM;
  /// residency A → FIRE. `resolutionProbe` is the status-edge gate and
  /// `PendingAutoSend.verdict` the decision — composed here exactly as
  /// `resolutionEdge` composes them.
  func test_516_status_edge_holds_until_residency_reconciles_then_settles() {
    let chatID = UUID()
    let pending = PendingAutoSend.arm(
      chatID: chatID, targetModelID: "org/A", messageText: "hello")!

    // Status edge: pin resolves to A, but residency not reconciled yet —
    // the probe must report nothing resolved, so the verdict holds.
    let preReconcile = ChatScaffoldView.resolutionProbe(
      resolvedModelID: "org/A", residentModelID: nil, requiresResidency: true)
    XCTAssertNil(preReconcile, "status edge must treat an unreconciled engine as unresolved")
    XCTAssertEqual(pending.verdict(chatID: chatID, resolvedModelID: preReconcile, isSending: false),
                   .hold)

    // Reconcile lands on B (relaunch booted the active-profile marker's
    // model): the selection authority re-seeds to B → stale pending drops.
    XCTAssertEqual(pending.verdict(chatID: chatID, resolvedModelID: "org/B", isSending: false),
                   .disarm)

    // Reconcile lands on A: the residency edge passes A through (no
    // residency pre-check on post-reconcile edges) → the pending fires.
    let postReconcile = ChatScaffoldView.resolutionProbe(
      resolvedModelID: "org/A", residentModelID: "org/A", requiresResidency: false)
    XCTAssertEqual(pending.verdict(chatID: chatID, resolvedModelID: postReconcile, isSending: false),
                   .fire)
  }

  // MARK: - #516 review F8: bounded reconcile failure must settle, never strand

  /// The liveness contract: with a pending send armed, a reconcile that
  /// exhausts its bounded retries earns ONE backed-off retry round, and the
  /// final failure falls back to the residency-free resolution edge — the
  /// pending settles (fires or disarms via the pre-F6 evidence) instead of
  /// holding forever against equal `.running` polls that never re-run the
  /// reconcile task. Without a pending there is nothing to settle.
  func test_516_reconcile_failure_settles_an_armed_pending_send() {
    XCTAssertEqual(
      ChatScaffoldView.reconcileFailureStep(hasPendingAutoSend: true, isRetryPass: false),
      .retry, "first bounded failure while armed → one backed-off retry round")
    XCTAssertEqual(
      ChatScaffoldView.reconcileFailureStep(hasPendingAutoSend: true, isRetryPass: true),
      .fallbackEdge, "final failure while armed → residency-free edge so the pending settles")
    XCTAssertEqual(
      ChatScaffoldView.reconcileFailureStep(hasPendingAutoSend: false, isRetryPass: false),
      .none, "no pending → nothing to settle (NSLog-only behavior stands)")
    XCTAssertEqual(
      ChatScaffoldView.reconcileFailureStep(hasPendingAutoSend: false, isRetryPass: true),
      .none)

    // The fallback edge re-evaluates with the pre-F6 evidence: the chat's
    // selection authority settles the verdict — fire on the intended model,
    // disarm on a mismatch — bounded, never an infinite hold.
    let chatID = UUID()
    let pending = PendingAutoSend.arm(chatID: chatID, targetModelID: "org/A", messageText: "hi")!
    let fallback = ChatScaffoldView.resolutionProbe(
      resolvedModelID: "org/A", residentModelID: nil, requiresResidency: false)
    XCTAssertEqual(pending.verdict(chatID: chatID, resolvedModelID: fallback, isSending: false), .fire)
  }

  // MARK: - #516 review F9: sheet dismissal keys on the probe, not raw resolution

  /// On a residency-required edge that evaluates to hold, the probe is nil —
  /// and the sheet dismissal is keyed on that SAME probe result, so the gate
  /// stays up (no false success signal) while the fire is held. Once
  /// residency reconciles, the probe passes resolution through and the
  /// sheet may dismiss with the verdict settled on the same evidence.
  func test_516_sheet_stays_up_while_a_residency_required_edge_holds() {
    XCTAssertNil(
      ChatScaffoldView.resolutionProbe(
        resolvedModelID: "org/A", residentModelID: nil, requiresResidency: true),
      "held edge → probe nil → the probe-keyed dismissal leaves the sheet up")
    XCTAssertEqual(
      ChatScaffoldView.resolutionProbe(
        resolvedModelID: "org/A", residentModelID: "org/A", requiresResidency: true),
      "org/A",
      "reconciled → probe passes resolution → dismissal and verdict settle on the same evidence")
  }

  private func waitUntil(
    timeout: TimeInterval,
    condition: () -> Bool
  ) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
  }
}
