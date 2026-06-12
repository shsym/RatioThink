import XCTest
@testable import RatioThinkCore

/// #474: `ModelLoadCenter` holds the launched engine's effective `max_tokens`
/// ceiling (from `GET /v1/models`) so the chat send path can clamp to it. The
/// ceiling must update on every reconcile — including when the resident model
/// id is unchanged (a memory-guardrail change or reload can re-launch the same
/// model with a different ceiling) — and must clear wherever residency clears
/// so a stale ceiling never outlives its engine.
@MainActor
final class ModelLoadCenterCeilingTests: XCTestCase {

  func test_setResidentMaxOutputTokens_stores_value() {
    let center = ModelLoadCenter()
    XCTAssertNil(center.residentMaxOutputTokens)
    center.setResidentMaxOutputTokens(512)
    XCTAssertEqual(center.residentMaxOutputTokens, 512)
  }

  /// The setter does NOT short-circuit on an unchanged model id (unlike
  /// `reconcileEngineResident`): a guardrail change can hand the same model a
  /// lower ceiling, and the send path must see it.
  func test_ceiling_updates_even_when_model_id_unchanged() {
    let center = ModelLoadCenter()
    center.reconcileEngineResident("qwen3")
    center.setResidentMaxOutputTokens(2048)
    XCTAssertEqual(center.residentMaxOutputTokens, 2048)
    // Same model id, tighter guardrail → lower ceiling.
    center.reconcileEngineResident("qwen3")  // no-op (unchanged id)
    center.setResidentMaxOutputTokens(512)
    XCTAssertEqual(center.residentMaxOutputTokens, 512)
  }

  /// A nil reconcile (pre-#474 engine reporting no field) clears the ceiling
  /// so the send path falls back to "unknown / no clamp".
  func test_nil_ceiling_clears() {
    let center = ModelLoadCenter()
    center.setResidentMaxOutputTokens(512)
    center.setResidentMaxOutputTokens(nil)
    XCTAssertNil(center.residentMaxOutputTokens)
  }

  func test_markUnloaded_clears_ceiling() {
    let center = ModelLoadCenter()
    center.setResidentMaxOutputTokens(512)
    center.markUnloaded()
    XCTAssertNil(center.residentMaxOutputTokens)
  }

  func test_engineLeftRunning_clears_ceiling() {
    let center = ModelLoadCenter()
    center.reconcileEngineResident("qwen3")
    center.setResidentMaxOutputTokens(512)
    center.engineLeftRunning()
    XCTAssertNil(center.residentMaxOutputTokens)
    XCTAssertNil(center.residentModelID)
  }

  func test_engineServesNoModel_clears_ceiling() {
    let center = ModelLoadCenter()
    center.reconcileEngineResident("qwen3")
    center.setResidentMaxOutputTokens(512)
    center.engineServesNoModel()
    XCTAssertNil(center.residentMaxOutputTokens)
  }
}
