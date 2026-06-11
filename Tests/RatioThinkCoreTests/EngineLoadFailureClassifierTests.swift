import XCTest
@testable import RatioThinkCore

final class EngineLoadFailureClassifierTests: XCTestCase {
  func test_structured_engine_code_classifies_unsupported_model() {
    let error = HTTPEngineError.api(
      status: 400,
      code: "unsupported_model",
      message: "unsupported architecture llama-next"
    )

    let classified = EngineLoadFailureClassifier.classify(error)

    XCTAssertEqual(classified?.kind, .unsupportedModel)
    XCTAssertEqual(classified?.underlyingReason, "unsupported architecture llama-next")
  }

  func test_narrow_stderr_signature_classifies_unsupported_model() {
    let error = PieControlLauncher.LaunchError.engineExitedEarly(
      code: 1,
      reason: .exit,
      stderrTail: "load_model: unsupported model architecture 'mamba2'"
    )

    let classified = EngineLoadFailureClassifier.classify(error)

    XCTAssertEqual(classified?.kind, .unsupportedModel)
    XCTAssertTrue(classified?.underlyingReason.contains("unsupported model architecture") ?? false)
  }

  func test_generic_engine_crash_is_not_misclassified_as_unsupported() {
    let panic = HTTPEngineError.http(
      status: 503,
      body: Data("handler-panic".utf8),
      retryAfter: 1
    )

    XCTAssertNil(EngineLoadFailureClassifier.classify(panic),
                 "generic crash/restart fault classes must remain generic, not unsupported")
  }

  func test_driver_unsupported_is_not_misclassified_as_model_unsupported() {
    let error = PieControlLauncher.LaunchError.driverUnsupported(
      requested: "metal",
      binary: "/tmp/pie",
      details: "unsupported model architecture should not matter on this helper-side fault"
    )

    XCTAssertNil(EngineLoadFailureClassifier.classify(error))
  }

  func test_unsupported_user_message_names_model_and_recovery_path() {
    let error = HTTPEngineError.stream(
      code: "unsupported_format",
      message: "unsupported gguf tensor type"
    )

    let message = EngineLoadFailureClassifier.userFacingLoadFailureMessage(
      modelID: "org/Repo/model.gguf",
      error: error
    )

    XCTAssertTrue(message.contains("org/Repo/model.gguf"))
    XCTAssertTrue(message.contains("choose a curated model"))
    XCTAssertTrue(message.contains("remove or fix the cached repo"))
    XCTAssertTrue(message.contains("install a supported artifact"))
    XCTAssertTrue(message.contains("unsupported gguf tensor type"))
  }
}
