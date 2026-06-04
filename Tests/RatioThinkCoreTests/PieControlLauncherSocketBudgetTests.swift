import XCTest
import Foundation
@testable import RatioThinkCore

/// Regression guard: a `PIE_HOME` deep enough that the engine's aux Unix
/// socket `$PIE_HOME/standalone/<pid>/g0/aux.sock` would overrun Darwin's
/// `sun_path` limit must fail LOUD before spawning, not hang at model
/// load. Exercises the pure `auxSocketBudgetError` budget helper + the
/// driver-conditional gate, so it needs no real binary/engine.
final class PieControlLauncherSocketBudgetTests: XCTestCase {

  private func pieHome(ofLength n: Int) -> URL {
    // Absolute path exactly `n` chars: "/" + (n-1) filler bytes.
    precondition(n >= 1)
    return URL(fileURLWithPath: "/" + String(repeating: "a", count: n - 1))
  }

  func test_short_pieHome_has_no_budget_error() {
    XCTAssertNil(
      PieControlLauncher.auxSocketBudgetError(pieHome: pieHome(ofLength: 17)),
      "a short /tmp pieHome must pass the aux-socket budget"
    )
  }

  /// Production uses `~/Library/Application Support/RatioThink` — must
  /// remain valid.
  func test_production_like_pieHome_has_no_budget_error() {
    let prod = URL(fileURLWithPath: "/Users/example/Library/Application Support/RatioThink")
    XCTAssertLessThanOrEqual(prod.path.utf8.count, PieControlLauncher.maxSafePieHomePathLength)
    XCTAssertNil(PieControlLauncher.auxSocketBudgetError(pieHome: prod))
  }

  func test_pieHome_at_exact_limit_passes() {
    let limit = PieControlLauncher.maxSafePieHomePathLength
    XCTAssertNil(
      PieControlLauncher.auxSocketBudgetError(pieHome: pieHome(ofLength: limit)),
      "a pieHome at exactly the max safe length must still pass"
    )
  }

  func test_pieHome_one_over_limit_fails_with_explicit_diagnostic() {
    let limit = PieControlLauncher.maxSafePieHomePathLength
    let over = pieHome(ofLength: limit + 1)
    guard let error = PieControlLauncher.auxSocketBudgetError(pieHome: over) else {
      return XCTFail("a pieHome one byte over the limit must produce a budget error")
    }
    guard case let .pieHomePathTooLong(reportedPath, length, reportedLimit) = error else {
      return XCTFail("expected .pieHomePathTooLong, got \(error)")
    }
    XCTAssertEqual(reportedPath, over.path)
    XCTAssertEqual(length, limit + 1)
    XCTAssertEqual(reportedLimit, limit)
    // The diagnostic must name the offending path, the sun_path limit,
    // and the aux-socket cause so an operator can act on it.
    let message = error.description
    XCTAssertTrue(message.contains("PIE_HOME path too long"), "got: \(message)")
    XCTAssertTrue(message.contains("aux socket"), "got: \(message)")
    XCTAssertTrue(message.contains("\(PieControlLauncher.auxSocketSunPathBytes)"), "got: \(message)")
    XCTAssertTrue(message.contains("shorter PIE_HOME"), "got: \(message)")
  }

  /// A deep `NSTemporaryDirectory()`-style pieHome is exactly the failure
  /// mode the guard prevents — model it and assert the guard fires.
  func test_deep_temp_style_pieHome_fails() {
    let deep = URL(fileURLWithPath:
      "/var/folders/q5/9x7k1234567890abcdefghij_klmn/T/pie-real-engine-deadbeef-extra-nesting/run")
    XCTAssertGreaterThan(deep.path.utf8.count, PieControlLauncher.maxSafePieHomePathLength)
    XCTAssertNotNil(
      PieControlLauncher.auxSocketBudgetError(pieHome: deep),
      "a deep temp-dir pieHome that would overrun sun_path must fail loud"
    )
  }

  /// The dummy driver binds no aux socket, so its launches are exempt
  /// from the budget — this is what keeps the long-pieHome dummy-driver
  /// CLI scenarios (IsolatedTestCase) valid.
  func test_only_real_drivers_are_subject_to_budget() {
    XCTAssertFalse(PieControlLauncher.modelConfigBindsAuxSocket(.dummy))
    XCTAssertTrue(PieControlLauncher.modelConfigBindsAuxSocket(.metal(modelID: "m")))
    XCTAssertTrue(PieControlLauncher.modelConfigBindsAuxSocket(
      .portable(modelSlug: "s", modelsRoot: URL(fileURLWithPath: "/tmp/models"))))
    XCTAssertTrue(PieControlLauncher.modelConfigBindsAuxSocket(
      .portableResolved(servedModelID: "id", modelRef: "/tmp/models/m.gguf")))
  }
}
