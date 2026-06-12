import XCTest
import SwiftUI
@testable import RatioThink

/// Review v8 F50 contract: the F44 lift moved the search session
/// state from pane-local `@State` onto a sheet-scoped `@State
/// HFSession` passed to the pane as `@Binding`. The test below
/// pins the *display-state persistence* half of that contract:
/// the user's `query`, `results`, etc. must survive a Picker swap
/// (modelled here by constructing a pane, discarding it, and
/// constructing a fresh pane against the same binding).
///
/// The F47/F48/F49 corollary — `inFlight`, `searchEpoch`,
/// `fileTasks` MUST stay pane-local so that pane lifecycle drives
/// Task cancellation — is pinned by the Mirror-based test below.
/// Together they fence the v8 refactor: lift only display state,
/// keep task plumbing pane-local.
final class HuggingFaceSearchPaneSessionTests: XCTestCase {

  func test_hfSession_data_survives_pane_recreation() {
    var stored = HFSession()
    let binding = Binding<HFSession>(
      get: { stored },
      set: { stored = $0 }
    )

    // First pane lifetime — equivalent to SwiftUI building the
    // subtree on first appear. The pane is constructed, the
    // user's query is written through the parent-owned binding,
    // and then the pane goes out of scope (Picker swap).
    do {
      _ = HuggingFaceSearchPane(availability: ModelAvailability(), onPick: { _, _ in }, session: binding)
      binding.wrappedValue.query = "test"
    }

    // Re-mount against the SAME binding. Under the F44 lift, the
    // rebuilt pane reads `query` through the binding's get-closure
    // — value persists across the reconstruction. A regression
    // that re-puts the search state on the pane as `@State` would
    // re-initialise to a fresh `HFSession()` on the rebuilt pane
    // and the assertion would fire.
    let rebuilt = HuggingFaceSearchPane(availability: ModelAvailability(), onPick: { _, _ in }, session: binding)

    XCTAssertEqual(
      rebuilt.session.query, "test",
      "the rebuilt pane MUST read the parent-owned session through the Binding (review v8 F50) — a regression that puts `query` back on the pane as `@State` would surface an empty string here")
    XCTAssertEqual(stored.query, "test",
                   "parent-owned storage must still carry the query after both pane lifetimes")
  }

  func test_hfSession_full_payload_survives_pane_recreation() {
    var stored = HFSession()
    stored.query = "phi"
    stored.results = []
    stored.expanded = ["acme/repo"]
    stored.fileErrors = ["acme/repo": "transient"]
    stored.status = nil
    stored.droppedCount = 3
    stored.rawCount = 10
    let binding = Binding<HFSession>(get: { stored }, set: { stored = $0 })

    _ = HuggingFaceSearchPane(availability: ModelAvailability(), onPick: { _, _ in }, session: binding)
    // Pane discarded — Picker swap equivalent.
    let rebuilt = HuggingFaceSearchPane(availability: ModelAvailability(), onPick: { _, _ in }, session: binding)

    XCTAssertEqual(rebuilt.session.query, "phi")
    XCTAssertEqual(rebuilt.session.expanded, ["acme/repo"])
    XCTAssertEqual(rebuilt.session.fileErrors["acme/repo"], "transient",
                   "per-row error captions must survive the swap — these were the F22/F3 carryovers F44 was lifted to preserve")
    XCTAssertEqual(rebuilt.session.droppedCount, 3,
                   "F22 schema-drift counter must survive the swap")
    XCTAssertEqual(rebuilt.session.rawCount, 10)
  }

  /// Pin the v8 refactor's pane-local task-management invariant.
  /// `inFlight`, `searchEpoch`, and `fileTasks` MUST live as
  /// `@State` on `HuggingFaceSearchPane`; if a future regression
  /// hoists them to sheet scope (which is how the F47/F48/F49
  /// races were introduced), the storage type changes from
  /// `State<…>` to `Binding<…>` and this test fires.
  func test_task_plumbing_is_pane_local_state_not_lifted_binding() {
    let binding = Binding<HFSession>(get: { HFSession() }, set: { _ in })
    let pane = HuggingFaceSearchPane(availability: ModelAvailability(), onPick: { _, _ in }, session: binding)
    let mirror = Mirror(reflecting: pane)

    // `_session` is the @Binding — sanity check.
    guard let sessionStorage = mirror.children.first(where: { $0.label == "_session" }) else {
      XCTFail("HuggingFaceSearchPane must store its session under property-wrapper `_session`")
      return
    }
    let sessionType = String(describing: type(of: sessionStorage.value))
    XCTAssertTrue(sessionType.hasPrefix("Binding<"),
                  "`_session` MUST be Binding<HFSession>; got `\(sessionType)`")

    // `_inFlight`, `_searchEpoch`, `_fileTasks` must each be @State.
    for label in ["_inFlight", "_searchEpoch", "_fileTasks"] {
      guard let child = mirror.children.first(where: { $0.label == label }) else {
        XCTFail("HuggingFaceSearchPane is missing `\(label)` — the v8 refactor's pane-local task plumbing is gone")
        continue
      }
      let typeName = String(describing: type(of: child.value))
      XCTAssertTrue(typeName.hasPrefix("State<"),
                    "`\(label)` MUST be State<…> (pane-local); got `\(typeName)`. A regression that hoists task plumbing to sheet scope is exactly the bug class F47/F48/F49 closed.")
    }
  }
}
