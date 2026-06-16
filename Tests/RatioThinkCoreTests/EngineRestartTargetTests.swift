import XCTest
@testable import RatioThinkCore

/// #668: an App-initiated engine restart ("Restart Engine" menu item,
/// engine-fault banner Retry) must preserve the running session's served
/// model instead of dropping the override to `nil` and letting
/// `LaunchSpecResolver` silently revert to `profile.model`. `EngineRestartTarget`
/// is the single derivation of that boot model; pinning its precedence here is
/// the mutation-proven lock for the fix (sandboxed XCUITest cannot spawn a real
/// pie to black-box the restart, insight:512).
final class EngineRestartTargetTests: XCTestCase {
  private func snapshot(served: String) -> EngineSessionSnapshot {
    EngineSessionSnapshot(port: EnginePort(exactly: 8080)!,
                          profileID: "chat",
                          servedModelID: served)
  }

  func test_running_session_preserves_served_model_over_marker() {
    // The live session's servedModelID wins — a restart reboots the SAME model.
    XCTAssertEqual(
      EngineRestartTarget.bootModel(currentSnapshot: snapshot(served: "repo/Pick-X.gguf"),
                                    lastServedModelID: "repo/Marker-Y.gguf"),
      "repo/Pick-X.gguf"
    )
  }

  func test_no_running_snapshot_falls_back_to_marker() {
    // Post-fault / stopped: the snapshot is gone, so the durable active-model
    // marker (last-served) preserves identity across the crash.
    XCTAssertEqual(
      EngineRestartTarget.bootModel(currentSnapshot: nil,
                                    lastServedModelID: "repo/Marker-Y.gguf"),
      "repo/Marker-Y.gguf"
    )
  }

  func test_empty_served_id_falls_back_to_marker() {
    // A legacy/pin snapshot can carry an empty servedModelID (no real model
    // resolution happened) — treat it as "unknown" and fall back to the marker.
    XCTAssertEqual(
      EngineRestartTarget.bootModel(currentSnapshot: snapshot(served: "   "),
                                    lastServedModelID: "repo/Marker-Y.gguf"),
      "repo/Marker-Y.gguf"
    )
  }

  func test_neither_known_returns_nil() {
    // Never-started engine, no marker: nil override -> resolver boots
    // profile.model, exactly the prior behavior.
    XCTAssertNil(
      EngineRestartTarget.bootModel(currentSnapshot: nil, lastServedModelID: nil)
    )
    XCTAssertNil(
      EngineRestartTarget.bootModel(currentSnapshot: nil, lastServedModelID: "  ")
    )
  }
}
