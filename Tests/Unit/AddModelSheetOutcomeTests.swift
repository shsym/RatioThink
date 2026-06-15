import XCTest
@testable import RatioThink

/// Pins the v3 F21 contract: every URL the user drops on `LocalFilePane`
/// must end up visible to the parent — successes by inclusion in the
/// `successes` array, failures by inclusion in `failures`. Previously,
/// the first successful import triggered `dismiss()` and subsequent
/// loop iterations wrote their failure summary to a torn-down view.
///
/// The brief's exact test recommendation: "drop 3 .gguf files where 2
/// fail validation; assert the parent sees both failures."
final class AddModelSheetOutcomeTests: XCTestCase {

  func test_format_drop_three_two_failures_surfaces_both_reasons() {
    let success = URL(fileURLWithPath: "/tmp/keeper.gguf")
    let failures = [
      AddModelSheet.BatchFailure(
        filename: "wrong-ext.bin",
        reason: "ModelImporter: '/tmp/wrong-ext.bin' must have a .gguf extension"
      ),
      AddModelSheet.BatchFailure(
        filename: "dupe.gguf",
        reason: "ModelImporter: a model already exists at /tmp/dupe.gguf"
      ),
    ]
    let formatted = ModelsSettingsTab.formatImportOutcome(
      successes: [success],
      failures: failures
    )
    let unwrapped = try? XCTUnwrap(formatted,
                                   "partial-failure batch must produce a non-nil actionError so the user sees both reasons (review v3 F21)")
    let s = unwrapped ?? ""
    XCTAssertTrue(s.contains("Imported 1 of 3"),
                  "header must reflect the FULL batch size including failures; got: \(s)")
    XCTAssertTrue(s.contains("wrong-ext.bin"),
                  "first failure filename must appear in the summary; got: \(s)")
    XCTAssertTrue(s.contains("dupe.gguf"),
                  "second failure filename must appear in the summary; got: \(s)")
    XCTAssertTrue(s.contains("extension"),
                  "first failure reason must appear; got: \(s)")
    XCTAssertTrue(s.contains("already exists"),
                  "second failure reason must appear; got: \(s)")
  }

  func test_format_clean_batch_returns_nil() {
    let url = URL(fileURLWithPath: "/tmp/clean.gguf")
    XCTAssertNil(ModelsSettingsTab.formatImportOutcome(successes: [url], failures: []),
                 "a clean batch must produce nil so the actionError slot clears")
  }

  func test_format_all_failure_batch_shows_zero_successes() {
    let failures = [
      AddModelSheet.BatchFailure(filename: "a.gguf", reason: "copy failed"),
      AddModelSheet.BatchFailure(filename: "b.gguf", reason: "extension"),
    ]
    let formatted = ModelsSettingsTab.formatImportOutcome(successes: [], failures: failures) ?? ""
    XCTAssertTrue(formatted.contains("Imported 0 of 2"),
                  "all-failure case must still be visible — not silently dropped; got: \(formatted)")
  }

  func test_delete_referenced_model_message_names_profiles_and_clears_defaults() {
    let row = InstalledModel(
      filename: "Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf",
      url: URL(fileURLWithPath: "/tmp/Qwen3-0.6B-Q8_0.gguf"),
      sizeBytes: 10,
      modifiedAt: Date(timeIntervalSince1970: 0),
      isPartial: false
    )
    let message = ModelsSettingsTab.deleteReferencedModelMessage(
      row: row,
      affectedProfiles: [
        ProfileModelReference(id: "chat", name: "Chat"),
        ProfileModelReference(id: "fast-think", name: "Repeat Boost"),
      ]
    )

    XCTAssertTrue(message.contains("2 profiles use this model as its default"),
                  "message must show the affected count; got: \(message)")
    XCTAssertTrue(message.contains("Chat, Repeat Boost"),
                  "message must name affected profiles; got: \(message)")
    XCTAssertTrue(message.contains("profile defaults will be cleared"),
                  "message must make the destructive profile cleanup explicit; got: \(message)")
    XCTAssertTrue(message.contains("Choose/Download actions"),
                  "message must tell users the cleared profiles enter no-default recovery UI; got: \(message)")
    XCTAssertTrue(message.contains("running engine is not stopped"),
                  "message must define behavior when the model is currently loaded/running; got: \(message)")
  }

  func test_delete_installed_model_restores_profile_defaults_when_trash_fails() throws {
    let temp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("delete-profile-defaults-\(UUID().uuidString)", isDirectory: true)
    let profiles = temp.appendingPathComponent("profiles", isDirectory: true)
    let models = temp.appendingPathComponent("models", isDirectory: true)
    try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }

    let shared = "deleted-model.gguf"
    for (filename, id, name) in [
      ("chat.toml", "chat", "Chat"),
      ("fast.toml", "fast", "Repeat Boost"),
    ] {
      let body = """
      id = "\(id)"
      name = "\(name)"
      model = "\(shared)"
      inferlet = "chat-apc"
      """
      try body.write(to: profiles.appendingPathComponent(filename),
                     atomically: true,
                     encoding: .utf8)
    }
    let modelURL = models.appendingPathComponent(shared)
    try Data("model".utf8).write(to: modelURL)
    let store = ProfileStore(directory: profiles)
    try store.start()
    defer { store.stop() }
    let row = InstalledModel(
      filename: shared,
      url: modelURL,
      sizeBytes: 5,
      modifiedAt: Date(timeIntervalSince1970: 0),
      isPartial: false
    )

    XCTAssertThrowsError(try ModelsSettingsTab.deleteInstalledModel(
      row: row,
      profileStore: store,
      trashModel: { _ in throw DeleteModelProbeError.trashFailed },
      trashSidecar: { _ in }
    )) { error in
      XCTAssertTrue(String(describing: error).contains("restored"),
                    "delete failure should tell the user profile defaults were restored; got: \(error)")
    }

    XCTAssertEqual(store.model(forProfileID: "chat"), shared)
    XCTAssertEqual(store.model(forProfileID: "fast"), shared)
    XCTAssertTrue(FileManager.default.fileExists(atPath: modelURL.path),
                  "failed Trash move should leave the installed model in place")
  }

  // #469 F1: deleting the model that the durable active-model marker names must
  // clear the marker, so a later menu-bar Resume / crash auto-relaunch resolves
  // the still-valid profile default instead of dead-ending on the now-missing
  // marker model.
  func test_delete_installed_model_clears_active_model_marker_for_the_deleted_file() throws {
    let temp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("delete-marker-\(UUID().uuidString)", isDirectory: true)
    let profiles = temp.appendingPathComponent("profiles", isDirectory: true)
    let models = temp.appendingPathComponent("models", isDirectory: true)
    try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }

    let deleted = "deleted-model.gguf"
    try """
    id = "chat"
    name = "Chat"
    model = "\(deleted)"
    inferlet = "chat-apc"
    """.write(to: profiles.appendingPathComponent("chat.toml"), atomically: true, encoding: .utf8)
    let modelURL = models.appendingPathComponent(deleted)
    try Data("model".utf8).write(to: modelURL)
    let store = ProfileStore(directory: profiles)
    try store.start()
    defer { store.stop() }
    try store.setActiveModelID(deleted)   // marker == the model being deleted
    XCTAssertEqual(store.activeModelID, deleted, "precondition: marker set")

    let row = InstalledModel(filename: deleted, url: modelURL, sizeBytes: 5,
                             modifiedAt: Date(timeIntervalSince1970: 0), isPartial: false)
    try ModelsSettingsTab.deleteInstalledModel(
      row: row, profileStore: store,
      trashModel: { try FileManager.default.removeItem(at: $0) },
      trashSidecar: { _ in })

    XCTAssertNil(store.activeModelID,
                 "deleting the active model must clear the marker so Resume falls through to the profile default")
  }

  func test_delete_installed_model_preserves_marker_for_a_different_model() throws {
    let temp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("delete-marker-other-\(UUID().uuidString)", isDirectory: true)
    let profiles = temp.appendingPathComponent("profiles", isDirectory: true)
    let models = temp.appendingPathComponent("models", isDirectory: true)
    try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }

    let deleted = "deleted-model.gguf"
    let other = "still-resident.gguf"
    try """
    id = "chat"
    name = "Chat"
    model = "\(other)"
    inferlet = "chat-apc"
    """.write(to: profiles.appendingPathComponent("chat.toml"), atomically: true, encoding: .utf8)
    let modelURL = models.appendingPathComponent(deleted)
    try Data("model".utf8).write(to: modelURL)
    let store = ProfileStore(directory: profiles)
    try store.start()
    defer { store.stop() }
    try store.setActiveModelID(other)   // marker names a DIFFERENT model

    let row = InstalledModel(filename: deleted, url: modelURL, sizeBytes: 5,
                             modifiedAt: Date(timeIntervalSince1970: 0), isPartial: false)
    try ModelsSettingsTab.deleteInstalledModel(
      row: row, profileStore: store,
      trashModel: { try FileManager.default.removeItem(at: $0) },
      trashSidecar: { _ in })

    XCTAssertEqual(store.activeModelID, other,
                   "deleting a different model must not clear an unrelated active-model marker")
  }

  // MARK: - F38: emit-gate helper (review v5)

  // The drop closure's gate condition lives in
  // `AddModelSheet.shouldEmitBatch`. Pinning that helper directly
  // is what review v5 F38 asked for — the previous test only
  // exercised the formatter and would have stayed green against a
  // regression to `if !successes.isEmpty`.

  func test_shouldEmitBatch_emits_when_only_successes() {
    let url = URL(fileURLWithPath: "/tmp/a.gguf")
    XCTAssertTrue(AddModelSheet.shouldEmitBatch(successes: [url], failures: []),
                  "a clean drop must emit so the parent re-scans the installed dir")
  }

  func test_shouldEmitBatch_emits_when_only_failures() {
    let f = AddModelSheet.BatchFailure(filename: "x.gguf", reason: "extension")
    XCTAssertTrue(AddModelSheet.shouldEmitBatch(successes: [], failures: [f]),
                  "an all-failure drop must STILL emit so the parent's actionError can render the aggregate (review v4 F30)")
  }

  func test_shouldEmitBatch_emits_when_both_non_empty() {
    let url = URL(fileURLWithPath: "/tmp/keep.gguf")
    let f = AddModelSheet.BatchFailure(filename: "drop.gguf", reason: "already exists")
    XCTAssertTrue(AddModelSheet.shouldEmitBatch(successes: [url], failures: [f]))
  }

  func test_shouldEmitBatch_does_not_emit_when_both_empty() {
    XCTAssertFalse(AddModelSheet.shouldEmitBatch(successes: [], failures: []),
                   "an empty drop must NOT emit — there is nothing to report and dismissing on an empty drop would be surprising UX")
  }

  // MARK: - F43: Done routes captured localFileError through .imported

  // Pre-F43, `Button("Done")` and Esc both emitted `.cancelled`
  // unconditionally — `ModelsSettingsTab.handleSheetOutcome(.cancelled)`
  // early-returns, so any caption sitting in
  // `AddModelSheet.localFileError` from a failed `Choose File…`
  // pick was destroyed with the sheet's `@State`. The user saw
  // the red caption, mentally registered "will close and try
  // again", and the diagnostic vanished. F43 routes a captured
  // caption through `.imported(successes: [], failures:
  // [BatchFailure])` so it lands in `actionError` like every
  // other import diagnostic.

  func test_doneOutcome_with_captured_caption_routes_through_imported() {
    let outcome = AddModelSheet.doneOutcome(
      localFileError: "ModelImporter: '/tmp/x.bin' must have a .gguf extension")
    guard case .imported(let successes, let failures) = outcome else {
      XCTFail("expected .imported when a localFileError is captured; got \(outcome)")
      return
    }
    XCTAssertEqual(successes, [],
                   "Done dismissal cannot synthesize success URLs — the user did not import anything")
    XCTAssertEqual(failures.count, 1,
                   "the captured caption must surface as a single BatchFailure so `formatImportOutcome` renders it")
    XCTAssertEqual(failures[0].reason,
                   "ModelImporter: '/tmp/x.bin' must have a .gguf extension",
                   "the captured caption must travel verbatim — not be wrapped or paraphrased")
    XCTAssertEqual(failures[0].filename, "(file picker)",
                   "BatchFailure.filename should carry a stable, opaque label so the parent's formatter renders cleanly without inventing a path")
  }

  func test_doneOutcome_with_no_caption_emits_cancelled() {
    XCTAssertEqual(AddModelSheet.doneOutcome(localFileError: nil),
                   .cancelled,
                   "Done with no captured local-file caption must still emit .cancelled so the parent's actionError isn't blanked by a phantom empty-failures aggregate")
  }

  func test_doneOutcome_routed_failure_formats_visible_in_actionError() {
    // End-to-end shape check: F43 routes through `.imported`,
    // and `handleSheetOutcome(.imported)` feeds `actionError`
    // via `formatImportOutcome`. Pin the rendered string so a
    // future regression to ".cancelled OR null-formatting"
    // can't slip past silently.
    let outcome = AddModelSheet.doneOutcome(
      localFileError: "ModelImporter: bad ext")
    guard case .imported(let successes, let failures) = outcome else {
      XCTFail("expected .imported")
      return
    }
    let formatted = ModelsSettingsTab.formatImportOutcome(
      successes: successes,
      failures: failures)
    let s = formatted ?? ""
    XCTAssertTrue(s.contains("Imported 0 of 1"),
                  "F43 routed failure must format as a 0-of-1 batch; got: \(s)")
    XCTAssertTrue(s.contains("(file picker)"),
                  "the opaque filename must appear so the user can attribute the caption to the chooser; got: \(s)")
    XCTAssertTrue(s.contains("bad ext"),
                  "the captured caption must survive to the rendered actionError; got: \(s)")
  }

  func test_outcome_enum_carries_both_arrays_through_pattern_match() {
    let success = URL(fileURLWithPath: "/tmp/ok.gguf")
    let failure = AddModelSheet.BatchFailure(filename: "bad.gguf", reason: "extension")
    let outcome: AddModelSheet.Outcome = .imported(successes: [success], failures: [failure])
    switch outcome {
    case .imported(let successes, let failures):
      XCTAssertEqual(successes, [success])
      XCTAssertEqual(failures.count, 1)
      XCTAssertEqual(failures[0].filename, "bad.gguf")
    default:
      XCTFail("expected .imported associated values to pattern-match")
    }
  }
}

private enum DeleteModelProbeError: Error {
  case trashFailed
}
