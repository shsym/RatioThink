import XCTest
@testable import RatioThink

final class NoSurpriseFeedbackCopyTests: XCTestCase {
  func test_model_delete_copy_names_move_to_trash() {
    XCTAssertEqual(ModelsSettingsTab.moveToTrashConfirmTitle(affectedDefaults: 0), "Move to Trash")
    XCTAssertEqual(ModelsSettingsTab.moveToTrashConfirmTitle(affectedDefaults: 2), "Move to Trash and Clear Defaults")
    XCTAssertEqual(ModelsSettingsTab.moveToTrashInFlightMessage(filename: "model.gguf"), "Moving 'model.gguf' to Trash…")
    XCTAssertEqual(ModelsSettingsTab.moveToTrashSuccessMessage(filename: "model.gguf"), "Moved 'model.gguf' to Trash.")
  }

  func test_local_api_external_access_restart_copy_names_restart_and_completion() {
    let enabling = LocalAPIView.externalAccessRestartCopy(enabled: true)
    XCTAssertEqual(enabling.title, "Restart engine for external access?")
    XCTAssertTrue(enabling.message.contains("stops and restarts the shared engine"))
    XCTAssertEqual(enabling.confirmTitle, "Restart Engine")
    XCTAssertEqual(LocalAPIView.externalAccessRestartingMessage(enabled: true), "Restarting engine for external access…")
    XCTAssertEqual(LocalAPIView.externalAccessRestartSuccessMessage(enabled: true), "Engine restarted with external access enabled.")

    let disabling = LocalAPIView.externalAccessRestartCopy(enabled: false)
    XCTAssertEqual(disabling.title, "Restart engine for loopback-only access?")
    XCTAssertEqual(LocalAPIView.externalAccessRestartSuccessMessage(enabled: false), "Engine restarted with loopback-only access.")
  }

  func test_local_file_import_completion_copy() {
    XCTAssertEqual(LocalFilePane.importSuccessMessage(count: 1), "Imported 1 model.")
    XCTAssertEqual(LocalFilePane.importSuccessMessage(count: 2), "Imported 2 models.")
  }

  func test_profile_default_model_reload_success_copy() {
    XCTAssertEqual(
      ProfileEditor.engineReloadSuccessMessage(modelID: "Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf"),
      "The new default was saved and the engine reloaded Qwen3-0.6B-Q8_0.gguf."
    )
  }

  func test_diagnostics_collection_copy() {
    let zip = URL(fileURLWithPath: "/tmp/Rational-Diagnostics.zip")
    XCTAssertEqual(DiagnosticsCollector.runningMessage, "Collecting diagnostics…")
    XCTAssertEqual(DiagnosticsCollector.successMessage(zip), "Diagnostics bundle created: Rational-Diagnostics.zip")
  }
}
