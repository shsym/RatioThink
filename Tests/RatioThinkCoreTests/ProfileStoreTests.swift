import XCTest
import Foundation
import os
@testable import RatioThinkCore

/// Integration tests for `ProfileStore`. Each test runs in an
/// ephemeral temp dir so the FS watcher under test sees a clean
/// inode and parallel test runs (when enabled) cannot collide on a
/// shared profiles directory.
///
/// Async waiting strategy: the dispatch source schedules reloads on
/// the store's serial queue (with a debounce window). Tests register
/// a listener that fulfills an `XCTestExpectation` and then wait
/// with a generous timeout — FS notifications on macOS are usually
/// sub-100ms but CI under load can take longer.
final class ProfileStoreTests: XCTestCase {

  // MARK: - seeding

  /// #702: the `chat` built-in is an immutable in-code BASE profile. It must
  /// be present in `entries` on an empty dir WITHOUT being written to disk —
  /// so a user delete / stale install can never strand it.
  func test_base_chat_present_without_writing_a_file_on_first_launch() throws {
    try withTempProfilesDir { dir in
      let store = ProfileStore(directory: dir)
      try store.start()
      defer { store.stop() }

      let onDisk = dir.appendingPathComponent(ProfileStore.defaultChatFilename)
      XCTAssertFalse(FileManager.default.fileExists(atPath: onDisk.path),
                     "#702: base built-ins are in-code; nothing is seeded into the writable dir")

      let entry = try XCTUnwrap(store.entries.first { $0.profile?.id == "chat" })
      XCTAssertNotNil(entry.profile)
      XCTAssertNil(entry.error)
      XCTAssertEqual(entry.profile?.id, "chat")
      XCTAssertEqual(entry.warnings, [])
    }
  }

  /// #413 / #702: the example tree-of-thought profile is a BASE built-in,
  /// present in `entries` on a fresh install without being written to disk.
  /// chat stays the active default; the ToT profile is a valid ToT profile.
  func test_base_tree_of_thought_present_on_first_launch() throws {
    try withTempProfilesDir { dir in
      let active = dir.deletingLastPathComponent().appendingPathComponent("active-profile")
      let store = ProfileStore(directory: dir, activeProfileURL: active)
      try store.start()
      defer { store.stop() }

      let onDisk = dir.appendingPathComponent(ProfileStore.treeOfThoughtFilename)
      XCTAssertFalse(FileManager.default.fileExists(atPath: onDisk.path),
                     "#702: the ToT built-in is in-code; nothing is seeded into the writable dir")

      let entry = try XCTUnwrap(store.entries.first { $0.profile?.id == "tree-of-thought" })
      let profile = try XCTUnwrap(entry.profile)
      XCTAssertEqual(profile.id, "tree-of-thought")
      XCTAssertEqual(profile.inferlet, "chat-apc", "ToT is a dispatch mode; the launched inferlet stays chat-apc")
      XCTAssertEqual(profile.treeOfThought, ToTProfileConfig(breadth: 3, depth: 2, beamWidth: 2, maxTokensPerNode: 256))
      // chat remains the active default (marker seeded on this fresh install);
      // ToT is opt-in via profile switch.
      XCTAssertEqual(store.activeProfileID, "chat")
    }
  }

  // MARK: - #469 active-model marker

  func test_activeModel_marker_roundTrips_and_clears() throws {
    try withTempProfilesDir { dir in
      let active = dir.deletingLastPathComponent().appendingPathComponent("active-profile")
      let store = ProfileStore(directory: dir, activeProfileURL: active)
      try store.start()
      defer { store.stop() }

      XCTAssertNil(store.activeModelID, "no marker before any launch")

      try store.setActiveModelID("Org/Repo/picked.gguf")
      XCTAssertEqual(store.activeModelID, "Org/Repo/picked.gguf")
      // Default marker location is a sibling of active-profile.
      XCTAssertTrue(FileManager.default.fileExists(atPath: store.activeModelURL.path),
                    "setActiveModelID must persist the marker on disk")

      // Overwrite is last-write-wins.
      try store.setActiveModelID("Org/Repo/other.gguf")
      XCTAssertEqual(store.activeModelID, "Org/Repo/other.gguf")

      try store.clearActiveModelID()
      XCTAssertNil(store.activeModelID, "clear removes the marker")
      try store.clearActiveModelID()  // idempotent when already absent
    }
  }

  func test_activeModel_marker_is_durable_across_store_instances() throws {
    // The marker is the durable source of truth the Helper boots from after a
    // relaunch (#469): a fresh ProfileStore over the same directory reads it.
    try withTempProfilesDir { dir in
      let active = dir.deletingLastPathComponent().appendingPathComponent("active-profile")
      let writer = ProfileStore(directory: dir, activeProfileURL: active)
      try writer.start()
      try writer.setActiveModelID("Org/Repo/durable.gguf")
      writer.stop()

      let reader = ProfileStore(directory: dir, activeProfileURL: active)
      try reader.start()
      defer { reader.stop() }
      XCTAssertEqual(reader.activeModelID, "Org/Repo/durable.gguf",
                     "a relaunched Helper must read the last-launched model from disk")
    }
  }

  func test_activeModel_marker_blankFile_readsAsNil() throws {
    try withTempProfilesDir { dir in
      let active = dir.deletingLastPathComponent().appendingPathComponent("active-profile")
      let store = ProfileStore(directory: dir, activeProfileURL: active)
      try store.start()
      defer { store.stop() }
      try "   \n".write(to: store.activeModelURL, atomically: true, encoding: .utf8)
      XCTAssertNil(store.activeModelID, "a blank/whitespace marker reads as no selection")
    }
  }

  /// #413 / #702: an EXISTING install whose dir holds a byte-equal seeded
  /// `chat.toml` from before #702 must STILL surface the ToT profile (base
  /// layer) — and the redundant seeded chat.toml is removed by the migration
  /// while the base chat stays present. (Reproduces the operator's "ToT
  /// profile appears nowhere" on an upgraded install.)
  func test_base_tree_of_thought_present_in_existing_install() throws {
    try withTempProfilesDir { dir in
      try ProfileStore.defaultChatTOML.write(
        to: dir.appendingPathComponent(ProfileStore.defaultChatFilename),
        atomically: true, encoding: .utf8)
      let active = dir.deletingLastPathComponent().appendingPathComponent("active-profile")
      try "chat".write(to: active, atomically: true, encoding: .utf8)

      let store = ProfileStore(directory: dir, activeProfileURL: active)
      try store.start()
      defer { store.stop() }

      // The byte-equal seeded copy is redundant (base provides it) -> removed.
      XCTAssertFalse(FileManager.default.fileExists(
        atPath: dir.appendingPathComponent(ProfileStore.defaultChatFilename).path),
        "#702: a byte-equal seeded built-in is removed; base layer provides it")
      // ToT + chat both come from the base layer.
      let tot = try XCTUnwrap(store.entries.first { $0.profile?.id == "tree-of-thought" })
      XCTAssertNotNil(tot.profile?.treeOfThought)
      XCTAssertNotNil(store.entries.first { $0.profile?.id == "chat" }?.profile)
      XCTAssertEqual(store.activeProfileID, "chat", "migration must not change the active profile")
    }
  }

  /// #413: the backfill is write-IF-ABSENT — it must never clobber a
  /// user-edited tree-of-thought.toml.
  func test_backfill_does_not_clobber_user_edited_tree_of_thought_profile() throws {
    try withTempProfilesDir { dir in
      try ProfileStore.defaultChatTOML.write(
        to: dir.appendingPathComponent(ProfileStore.defaultChatFilename),
        atomically: true, encoding: .utf8)
      let edited = """
      id = "tree-of-thought"
      name = "My ToT"
      model = "Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf"
      inferlet = "chat-apc"

      [inferlet_args]
      mode = "tree-of-thought"
      breadth = 5
      """
      let totURL = dir.appendingPathComponent(ProfileStore.treeOfThoughtFilename)
      try edited.write(to: totURL, atomically: true, encoding: .utf8)

      let store = ProfileStore(directory: dir)
      try store.start()
      defer { store.stop() }

      XCTAssertEqual(try String(contentsOf: totURL, encoding: .utf8), edited,
                     "backfill must not clobber a user-edited tree-of-thought.toml")
      XCTAssertEqual(
        store.entries.first { $0.url.lastPathComponent == "tree-of-thought.toml" }?.profile?.treeOfThought?.breadth,
        5)
    }
  }

  /// : seeding the default `chat.toml` on a fresh install
  /// must also write the active-profile marker. Without this, the
  /// menu-bar Resume click returns `.noActiveProfile` on first launch
  /// (the seeded entry is present in `entries` but `activeProfileID`
  /// is nil) and the user has no in-product affordance to pick one.
  func test_seed_also_writes_default_active_profile_marker_on_first_launch() throws {
    try withTempProfilesDir { dir in
      let active = dir.deletingLastPathComponent()
        .appendingPathComponent("active-profile", isDirectory: false)
      let store = ProfileStore(directory: dir, activeProfileURL: active)
      try store.start()
      defer { store.stop() }

      XCTAssertTrue(FileManager.default.fileExists(atPath: active.path),
                    "first-launch seed must also write the active-profile marker so Resume is not a silent no-op")
      let markerBody = try String(contentsOf: active, encoding: .utf8)
      XCTAssertEqual(markerBody, "chat",
                     "seeded marker must point at the seeded chat profile id")
      XCTAssertEqual(store.activeProfileID, "chat",
                     "store must surface the seeded active id immediately on start()")
      XCTAssertNil(store.lastActiveProfileError,
                   "seeded marker must not surface a read error")
      XCTAssertEqual(store.activeProfile?.id, "chat",
                     "activeProfile must resolve to the seeded chat profile")
    }
  }

  /// : when the profiles dir already has tomls (i.e. seed
  /// is a no-op), the seed step must NOT plant an active-profile
  /// marker. Doing so would override the operator's "I have not
  /// chosen yet" state on subsequent launches.
  func test_seed_does_not_write_marker_when_profiles_directory_is_populated() throws {
    try withTempProfilesDir { dir in
      try writeProfile(into: dir, name: "chat.toml", id: "chat", displayName: "Chat")
      let active = dir.deletingLastPathComponent()
        .appendingPathComponent("active-profile", isDirectory: false)
      let store = ProfileStore(directory: dir, activeProfileURL: active)
      try store.start()
      defer { store.stop() }

      XCTAssertFalse(FileManager.default.fileExists(atPath: active.path),
                     "seed step must be a no-op when tomls already exist; marker must remain absent")
      XCTAssertNil(store.activeProfileID,
                   "absent marker must remain the clean 'no selection yet' state")
    }
  }

  /// : if the operator has already chosen a profile (marker
  /// file present) BEFORE the seed step ever ran, the seed must not
  /// clobber that choice when it later runs against an empty dir
  /// (rare but defensible — e.g. profiles were manually removed). The
  /// existing marker wins.
  func test_seed_preserves_existing_active_profile_marker() throws {
    try withTempProfilesDir { dir in
      let active = dir.deletingLastPathComponent()
        .appendingPathComponent("active-profile", isDirectory: false)
      try "custom".write(to: active, atomically: true, encoding: .utf8)

      let store = ProfileStore(directory: dir, activeProfileURL: active)
      try store.start()
      defer { store.stop() }

      let markerBody = try String(contentsOf: active, encoding: .utf8)
      XCTAssertEqual(markerBody, "custom",
                     "seed must not overwrite a pre-existing active-profile marker")
    }
  }

  ///  review v1 F4: `defaultProfileID` and the `id =`
  /// literal inside `defaultChatTOML` are two free-floating constants.
  /// A future edit that touches one without the other reintroduces
  /// the silent-no-op (marker points at a non-existent profile id;
  /// `activeProfile?` resolves to nil; Resume returns
  /// `.noActiveProfile`). Parse the seeded TOML and pin the invariant
  /// at CI so drift fails loudly.
  func test_default_profile_id_matches_default_chat_toml_id() throws {
    let parsed = try Profile.parse(toml: ProfileStore.defaultChatTOML)
    XCTAssertEqual(parsed.id, ProfileStore.defaultProfileID,
                   "defaultProfileID must equal the `id =` literal inside defaultChatTOML; drift reproduces ")
  }

  ///  review v1 F2 + F8 (refined under review v2 F1):
  /// marker-write failure must surface `.activeProfileSeedFailed`
  /// via `lastActiveProfileError`. The fault must break ONLY the
  /// write path — otherwise the test fails to pin F2's `start()`
  /// override (reverting that override would still satisfy a test
  /// that accepts `.activeProfileReadFailed` from the readback).
  ///
  /// Mechanism: chmod 0o500 on the marker parent dir (`r-x------`).
  /// `open(O_CREAT|O_EXCL|O_WRONLY)` needs write + exec on the parent
  /// → `EACCES`. The marker file itself never exists, so
  /// `readActiveProfileIDFromDisk` returns `.absent`, and the read
  /// commit clears `_activeProfileError` to nil. Without the F2
  /// override in `start()`, `lastActiveProfileError` would stay nil
  /// (the silent-no-op the fix targets); with it, the snapshot
  /// carries `.activeProfileSeedFailed`.
  ///
  /// Pinned EXACTLY against `.activeProfileSeedFailed` per review v2
  /// F1 — no accept-either fallback.
  func test_seed_marker_write_failure_surfaces_activeProfileSeedFailed() throws {
    try withTempProfilesDir { dir in
      let active = dir.deletingLastPathComponent()
        .appendingPathComponent("active-profile", isDirectory: false)
      let activeParent = active.deletingLastPathComponent()

      // Profiles dir lives below `activeParent` at 0o755, so the
      // chat.toml seed (which writes inside `profiles/`) still
      // succeeds — exec on `activeParent` traverses fine, only
      // file CREATION inside `activeParent` is blocked.
      try setPermissions(activeParent, mode: 0o500)
      defer { try? setPermissions(activeParent, mode: 0o755) }

      let store = ProfileStore(directory: dir, activeProfileURL: active)
      try store.start()
      defer { store.stop() }

      guard case .activeProfileSeedFailed(let path, _) = store.lastActiveProfileError else {
        return XCTFail("review v2 F1: must pin .activeProfileSeedFailed exactly; got \(String(describing: store.lastActiveProfileError))")
      }
      XCTAssertEqual(path, active.path,
                     "error must carry the marker path that failed")
      XCTAssertNil(store.activeProfileID,
                   "snapshot mask: activeProfileID must be nil while error is live")
    }
  }

  /// Companion to the F1 test above: when an operator (or stray
  /// process) leaves a DIRECTORY at the marker path, the EEXIST
  /// branch in `seedActiveProfileMarker` must NOT log "existing
  /// marker wins" — it must surface `.activeProfileSeedFailed` with
  /// the inode-type tag (review v2 F4). Otherwise an operator
  /// grepping logs sees "seed succeeded" while Resume silently
  /// fails downstream.
  func test_seed_marker_existing_directory_surfaces_seedFailed() throws {
    try withTempProfilesDir { dir in
      let active = dir.deletingLastPathComponent()
        .appendingPathComponent("active-profile", isDirectory: false)
      try FileManager.default.createDirectory(at: active,
                                              withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: active) }

      let store = ProfileStore(directory: dir, activeProfileURL: active)
      try store.start()
      defer { store.stop() }

      // Either `.activeProfileSeedFailed` (review v2 F4 path:
      // EEXIST → lstat → not S_IFREG) or `.activeProfileReadFailed`
      // (readback hit the directory first and the F2 override
      // preserves its priority per review v2 F2). Both are
      // acceptable here because the contract under test is "an
      // existing directory at the marker path MUST surface an
      // actionable error" — the v2 F2 fix explicitly prefers the
      // read error when both fire.
      switch store.lastActiveProfileError {
      case .activeProfileSeedFailed, .activeProfileReadFailed:
        break
      default:
        XCTFail("expected .activeProfileSeedFailed or .activeProfileReadFailed; got \(String(describing: store.lastActiveProfileError))")
      }
      XCTAssertNil(store.activeProfileID)
    }
  }

  func test_does_not_overwrite_existing_chat_toml() throws {
    try withTempProfilesDir { dir in
      let existing = dir.appendingPathComponent("chat.toml")
      let customBody = """
      id = "chat"
      name = "Custom Chat"
      model = "custom-model"
      inferlet = "custom-inferlet"
      """
      try customBody.write(to: existing, atomically: true, encoding: .utf8)

      let store = ProfileStore(directory: dir)
      try store.start()
      defer { store.stop() }

      let body = try String(contentsOf: existing, encoding: .utf8)
      XCTAssertEqual(body, customBody,
                     "existing chat.toml must not be clobbered by the seed step")

      let entry = try XCTUnwrap(store.entries.first { $0.url.lastPathComponent == "chat.toml" })
      XCTAssertEqual(entry.profile?.name, "Custom Chat")
    }
  }

  // MARK: - initial scan

  func test_initial_scan_returns_all_existing_profiles_sorted() throws {
    try withTempProfilesDir { dir in
      try writeProfile(into: dir, name: "zeta.toml", id: "zeta", displayName: "Zeta")
      try writeProfile(into: dir, name: "alpha.toml", id: "alpha", displayName: "Alpha")

      // Opt out of the #413 example-profile backfill so this scan-ordering
      // fixture stays hermetic (alpha + zeta only).
      let store = ProfileStore(directory: dir, seedsExampleProfiles: false)
      try store.start()
      defer { store.stop() }

      let names = store.entries.map { $0.url.lastPathComponent }
      // #702: the base layer (chat, repeat-boost, json-think) is always
      // present and merged in by filename; tree-of-thought is the example,
      // excluded here by seedsExampleProfiles=false. They appear alongside the
      // authored profiles, sorted.
      XCTAssertEqual(names, ["alpha.toml", "chat.toml", "json-think.toml", "repeat-boost.toml", "zeta.toml"],
                     "entries must be sorted by filename for stable UI ordering")
    }
  }

  // MARK: - built-in JSON Think seed (#572)

  func test_seeds_builtin_json_think_profile_into_populated_dir() throws {
    try withTempProfilesDir { dir in
      // A populated dir (the empty-dir chat seed is a no-op here) must
      // still gain the built-in JSON Think profile on start.
      try writeProfile(into: dir, name: "alpha.toml", id: "alpha", displayName: "Alpha")

      let store = ProfileStore(directory: dir)
      try store.start()
      defer { store.stop() }

      let jsonThink = store.entries.first { $0.profile?.id == ProfileStore.defaultJSONThinkProfileID }
      let profile = try XCTUnwrap(jsonThink?.profile, "JSON Think profile must be seeded")
      XCTAssertEqual(profile.responseFormat, .jsonObject)
      XCTAssertNil(store.lastDirectoryError, "a clean seed must not surface a directory error")
    }
  }

  func test_response_format_accessor_reads_seeded_json_think() throws {
    try withTempProfilesDir { dir in
      let store = ProfileStore(directory: dir)
      try store.start()
      defer { store.stop() }

      XCTAssertEqual(
        store.responseFormat(forProfileID: ProfileStore.defaultJSONThinkProfileID),
        .jsonObject)
      // The default chat profile carries no constraint.
      XCTAssertNil(store.responseFormat(forProfileID: ProfileStore.defaultProfileID))
    }
  }

  func test_does_not_overwrite_existing_json_think_toml() throws {
    try withTempProfilesDir { dir in
      // A user edit to json-think.toml must survive a restart (existence-gated).
      let edited = """
      id = "json-think"
      name = "My JSON"
      model = "m"
      inferlet = "chat-apc"
      """
      try edited.write(to: dir.appendingPathComponent(ProfileStore.defaultJSONThinkFilename),
                       atomically: true, encoding: .utf8)

      let store = ProfileStore(directory: dir)
      try store.start()
      defer { store.stop() }

      let jsonThink = store.entries.first { $0.profile?.id == ProfileStore.defaultJSONThinkProfileID }
      XCTAssertEqual(jsonThink?.profile?.name, "My JSON", "user edit must not be overwritten")
    }
  }

  // MARK: - FS watcher

  func test_watcher_picks_up_newly_added_profile() throws {
    try withTempProfilesDir { dir in
      let store = ProfileStore(directory: dir)
      let expect = expectation(description: "watcher fires after profile addition")
      let nameMatch = "added.toml"
      let listenerLock = NSLock()
      var fired = false
      store.addListener { snap in
        let hasNew = snap.entries.contains { $0.url.lastPathComponent == nameMatch }
        listenerLock.lock()
        defer { listenerLock.unlock() }
        if hasNew && !fired {
          fired = true
          expect.fulfill()
        }
      }
      try store.start()
      defer { store.stop() }

      try writeProfile(into: dir, name: nameMatch, id: "added", displayName: "Added")

      wait(for: [expect], timeout: 5.0)
      XCTAssertTrue(store.entries.contains { $0.url.lastPathComponent == nameMatch })
    }
  }

  func test_watcher_picks_up_deletion() throws {
    try withTempProfilesDir { dir in
      try writeProfile(into: dir, name: "ephemeral.toml", id: "eph", displayName: "Eph")

      let store = ProfileStore(directory: dir)
      try store.start()
      defer { store.stop() }

      // Register the listener AFTER start so the replay snapshot
      // already contains ephemeral.toml. Otherwise the
      // pre-initial-scan replay (empty entries) would fulfill the
      // expectation immediately because `stillThere == false` then.
      let expect = expectation(description: "watcher fires after profile deletion")
      let listenerLock = NSLock()
      var sawFile = false
      var fired = false
      store.addListener { snap in
        let stillThere = snap.entries.contains { $0.url.lastPathComponent == "ephemeral.toml" }
        listenerLock.lock()
        defer { listenerLock.unlock() }
        if stillThere { sawFile = true }
        if sawFile && !stillThere && !fired {
          fired = true
          expect.fulfill()
        }
      }

      try FileManager.default.removeItem(at: dir.appendingPathComponent("ephemeral.toml"))

      wait(for: [expect], timeout: 5.0)
      XCTAssertFalse(store.entries.contains { $0.url.lastPathComponent == "ephemeral.toml" })
    }
  }

  // MARK: - per-section validation

  func test_v2_sections_load_as_warnings_not_errors() throws {
    try withTempProfilesDir { dir in
      // `mcp_servers` wrong shape (scalar instead of table) → warning.
      // `routine` correct shape → no warning.
      let body = """
      id = "warn"
      name = "Warn"
      model = "m"
      inferlet = "i"

      mcp_servers = "should-be-a-table"

      [routine]
      kind = "ok"
      """
      let url = dir.appendingPathComponent("warn.toml")
      try body.write(to: url, atomically: true, encoding: .utf8)

      let store = ProfileStore(directory: dir)
      try store.start()
      defer { store.stop() }

      let entry = try XCTUnwrap(store.entries.first { $0.url.lastPathComponent == "warn.toml" })
      XCTAssertNotNil(entry.profile, "v2-section warnings must NOT reject the profile")
      XCTAssertNil(entry.error)
      XCTAssertEqual(entry.warnings.count, 1)
      XCTAssertEqual(entry.warnings.first?.section, "mcp_servers")
    }
  }

  func test_top_level_required_field_missing_is_a_hard_error() throws {
    try withTempProfilesDir { dir in
      let body = """
      name = "no-id"
      model = "m"
      inferlet = "i"
      """
      let url = dir.appendingPathComponent("broken.toml")
      try body.write(to: url, atomically: true, encoding: .utf8)

      let store = ProfileStore(directory: dir)
      try store.start()
      defer { store.stop() }

      let entry = try XCTUnwrap(store.entries.first { $0.url.lastPathComponent == "broken.toml" })
      XCTAssertNil(entry.profile)
      XCTAssertEqual(entry.error, .missingField("id"))
    }
  }

  func test_parse_failure_surfaced_per_file_does_not_poison_other_entries() throws {
    try withTempProfilesDir { dir in
      try writeProfile(into: dir, name: "good.toml", id: "good", displayName: "Good")

      let bad = dir.appendingPathComponent("bad.toml")
      try "this is not = valid [[[toml".write(to: bad, atomically: true, encoding: .utf8)

      let store = ProfileStore(directory: dir)
      try store.start()
      defer { store.stop() }

      let good = try XCTUnwrap(store.entries.first { $0.url.lastPathComponent == "good.toml" })
      let badEntry = try XCTUnwrap(store.entries.first { $0.url.lastPathComponent == "bad.toml" })
      XCTAssertTrue(good.isValid)
      XCTAssertFalse(badEntry.isValid)
      XCTAssertNotNil(badEntry.error)
    }
  }

  // MARK: - lifecycle

  func test_double_start_throws() throws {
    try withTempProfilesDir { dir in
      let store = ProfileStore(directory: dir)
      try store.start()
      defer { store.stop() }

      XCTAssertThrowsError(try store.start()) { err in
        guard case ProfileStoreError.alreadyStarted = err else {
          return XCTFail("expected .alreadyStarted, got \(err)")
        }
      }
    }
  }

  func test_stop_is_idempotent() throws {
    try withTempProfilesDir { dir in
      let store = ProfileStore(directory: dir)
      try store.start()
      store.stop()
      store.stop()  // must not crash
    }
  }

  func test_addListener_replays_current_state() throws {
    try withTempProfilesDir { dir in
      try writeProfile(into: dir, name: "first.toml", id: "first", displayName: "First")
      let store = ProfileStore(directory: dir)
      try store.start()
      defer { store.stop() }

      let expect = expectation(description: "listener fires with replayed snapshot")
      store.addListener { snap in
        if snap.entries.contains(where: { $0.url.lastPathComponent == "first.toml" }) {
          expect.fulfill()
        }
      }
      wait(for: [expect], timeout: 2.0)
    }
  }

  // MARK: - directory-level error observability (review v1 F3 + F4)

  /// F3: when the seed write fails (read-only profiles dir), the
  /// snapshot must expose `directoryError == .seedFailed` so the UI
  /// can render the real cause instead of an empty-state placeholder.
  /// #702: a stale unparseable seeded built-in that the migration cannot back
  /// up (read-only dir blocks the move) must surface `.seedFailed` on the
  /// snapshot — while the base built-ins stay present (entries non-empty).
  func test_builtin_backup_failure_surfaces_to_listeners_via_snapshot() throws {
    try withTempProfilesDir { dir in
      // A present-but-unparseable built-in file (missing required fields).
      try "id = \"chat\"\n".write(
        to: dir.appendingPathComponent(ProfileStore.defaultChatFilename),
        atomically: true, encoding: .utf8)
      // Read-only dir: the file still loads (r-x is readable), but the
      // migration's move-to-.bak fails -> its error must reach the snapshot.
      try setPermissions(dir, mode: 0o500)
      defer { try? setPermissions(dir, mode: 0o755) }  // let cleanup proceed

      let store = ProfileStore(directory: dir)
      let expect = expectation(description: "snapshot carries seedFailed")
      let listenerLock = NSLock()
      var fired = false
      store.addListener { snap in
        listenerLock.lock()
        defer { listenerLock.unlock() }
        if !fired, case .seedFailed = snap.directoryError {
          XCTAssertFalse(snap.entries.isEmpty,
                         "#702: base built-ins remain present even when a backup fails")
          fired = true
          expect.fulfill()
        }
      }
      try store.start()
      defer { store.stop() }

      wait(for: [expect], timeout: 2.0)

      guard case .seedFailed = store.lastDirectoryError else {
        return XCTFail("expected .seedFailed in lastDirectoryError, got \(String(describing: store.lastDirectoryError))")
      }
    }
  }

  /// F4: when `contentsOfDirectory` throws (directory deleted under
  /// the watcher), the next snapshot must expose `directoryError ==
  /// .scanFailed`. Without this, listeners would see an empty
  /// snapshot indistinguishable from a normal empty dir while the
  /// FD-bound watcher silently goes stale.
  func test_scan_failure_surfaces_to_listeners_via_snapshot() throws {
    try withTempProfilesDir { dir in
      try writeProfile(into: dir, name: "before-delete.toml", id: "x", displayName: "X")

      let store = ProfileStore(directory: dir)
      try store.start()
      defer { store.stop() }

      let expect = expectation(description: "snapshot carries scanFailed after dir removed")
      let listenerLock = NSLock()
      var fired = false
      store.addListener { snap in
        listenerLock.lock()
        defer { listenerLock.unlock() }
        if !fired, case .scanFailed = snap.directoryError {
          fired = true
          expect.fulfill()
        }
      }

      // Yank the watched directory. The dispatch source fires
      // `.delete`; the debounced reload then runs `contentsOf
      // Directory` against a path that no longer exists, which
      // throws and must be surfaced via `directoryError`.
      try FileManager.default.removeItem(at: dir)

      wait(for: [expect], timeout: 5.0)
      guard case .scanFailed = store.lastDirectoryError else {
        return XCTFail("expected .scanFailed in lastDirectoryError, got \(String(describing: store.lastDirectoryError))")
      }
    }
  }

  // MARK: - active profile (Phase 2.4 )

  func test_active_profile_persists_across_store_restart() throws {
    try withTempProfilesDir { dir in
      try writeProfile(into: dir, name: "chat.toml", id: "chat", displayName: "Chat")
      try writeProfile(into: dir, name: "code.toml", id: "code", displayName: "Code")

      let active = dir.deletingLastPathComponent()
        .appendingPathComponent("active-profile", isDirectory: false)

      // Round-trip 1: activate, then drop the store. The persisted
      // marker must outlive the in-memory state.
      do {
        let store = ProfileStore(directory: dir, activeProfileURL: active)
        try store.start()
        XCTAssertNil(store.activeProfileID, "fresh store with no marker file should have nil active id")
        XCTAssertNil(store.activeProfile)
        try store.setActiveProfileID("code")
        XCTAssertEqual(store.activeProfileID, "code")
        XCTAssertEqual(store.activeProfile?.id, "code")
        store.stop()
      }

      // Round-trip 2: a fresh store on the same directory hydrates
      // the persisted selection.
      let store2 = ProfileStore(directory: dir, activeProfileURL: active)
      try store2.start()
      defer { store2.stop() }
      XCTAssertEqual(store2.activeProfileID, "code",
                     "active id must persist across ProfileStore lifecycles")
      XCTAssertEqual(store2.activeProfile?.id, "code")
    }
  }

  func test_active_profile_id_pointing_at_missing_profile_returns_nil_active_profile() throws {
    try withTempProfilesDir { dir in
      try writeProfile(into: dir, name: "chat.toml", id: "chat", displayName: "Chat")
      let active = dir.deletingLastPathComponent()
        .appendingPathComponent("active-profile", isDirectory: false)
      let store = ProfileStore(directory: dir, activeProfileURL: active)
      try store.start()
      defer { store.stop() }
      try store.setActiveProfileID("ghost")
      XCTAssertEqual(store.activeProfileID, "ghost")
      XCTAssertNil(store.activeProfile,
                   "activeProfile must be nil when the id has no matching parsed entry")
    }
  }

  func test_clear_active_profile_id_removes_persistence_file() throws {
    try withTempProfilesDir { dir in
      try writeProfile(into: dir, name: "chat.toml", id: "chat", displayName: "Chat")
      let active = dir.deletingLastPathComponent()
        .appendingPathComponent("active-profile", isDirectory: false)
      let store = ProfileStore(directory: dir, activeProfileURL: active)
      try store.start()
      defer { store.stop() }
      try store.setActiveProfileID("chat")
      XCTAssertTrue(FileManager.default.fileExists(atPath: active.path))
      try store.clearActiveProfileID()
      XCTAssertNil(store.activeProfileID)
      XCTAssertFalse(FileManager.default.fileExists(atPath: active.path),
                     "clear must remove the on-disk marker so subsequent boots start clean")
    }
  }

  func test_active_profile_directory_at_marker_path_surfaces_read_error() throws {
    try withTempProfilesDir { dir in
      try writeProfile(into: dir, name: "chat.toml", id: "chat", displayName: "Chat")
      // Plant a *directory* at the active-profile marker path. The
      // store must NOT silently treat this as "no selection" — that
      // collapse was review cycle 149/150 F1. It must surface
      // `.activeProfileReadFailed` on the snapshot so the GUI can
      // render a recoverable error banner.
      let activePath = dir.deletingLastPathComponent()
        .appendingPathComponent("active-profile", isDirectory: false)
      try FileManager.default.createDirectory(at: activePath,
                                              withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: activePath) }

      let store = ProfileStore(directory: dir, activeProfileURL: activePath)
      try store.start()
      defer { store.stop() }

      XCTAssertNil(store.activeProfileID,
                   "unreadable marker must NOT pretend a selection exists")
      guard case .activeProfileReadFailed(let path, _) = store.lastActiveProfileError else {
        return XCTFail("expected .activeProfileReadFailed, got \(String(describing: store.lastActiveProfileError))")
      }
      XCTAssertEqual(path, activePath.path)
      XCTAssertNotNil(store.snapshot.activeProfileError,
                      "snapshot.activeProfileError must mirror lastActiveProfileError so listeners see the cause")
    }
  }

  func test_active_profile_unreadable_file_surfaces_read_error() throws {
    try withTempProfilesDir { dir in
      try writeProfile(into: dir, name: "chat.toml", id: "chat", displayName: "Chat")
      let activePath = dir.deletingLastPathComponent()
        .appendingPathComponent("active-profile", isDirectory: false)
      // 0o000: even the owner cannot open(2) it. `Data(contentsOf:)`
      // throws — the store must promote that into
      // `.activeProfileReadFailed` rather than swallowing via
      // `try?` (review cycle 149/150 F1).
      try "chat".write(to: activePath, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o000)],
        ofItemAtPath: activePath.path
      )
      defer {
        try? FileManager.default.setAttributes(
          [.posixPermissions: NSNumber(value: 0o644)],
          ofItemAtPath: activePath.path
        )
      }

      let store = ProfileStore(directory: dir, activeProfileURL: activePath)
      try store.start()
      defer { store.stop() }

      XCTAssertNil(store.activeProfileID)
      guard case .activeProfileReadFailed = store.lastActiveProfileError else {
        return XCTFail("expected .activeProfileReadFailed, got \(String(describing: store.lastActiveProfileError))")
      }
    }
  }

  func test_active_profile_marker_absent_is_clean_not_an_error() throws {
    try withTempProfilesDir { dir in
      try writeProfile(into: dir, name: "chat.toml", id: "chat", displayName: "Chat")
      let activePath = dir.deletingLastPathComponent()
        .appendingPathComponent("active-profile", isDirectory: false)
      // Marker file deliberately absent — the canonical "no selection
      // yet" state. Must NOT surface an error.
      let store = ProfileStore(directory: dir, activeProfileURL: activePath)
      try store.start()
      defer { store.stop() }
      XCTAssertNil(store.activeProfileID)
      XCTAssertNil(store.lastActiveProfileError,
                   "absent marker is the clean 'no selection' state, not an error")
    }
  }

  func test_setActiveProfileID_clears_stale_read_error() throws {
    try withTempProfilesDir { dir in
      try writeProfile(into: dir, name: "chat.toml", id: "chat", displayName: "Chat")
      let activePath = dir.deletingLastPathComponent()
        .appendingPathComponent("active-profile", isDirectory: false)
      try FileManager.default.createDirectory(at: activePath,
                                              withIntermediateDirectories: true)

      let store = ProfileStore(directory: dir, activeProfileURL: activePath)
      try store.start()
      defer { store.stop() }
      XCTAssertNotNil(store.lastActiveProfileError)

      // Operator repairs the marker manually (delete dir, then set).
      try FileManager.default.removeItem(at: activePath)
      try store.setActiveProfileID("chat")

      XCTAssertEqual(store.activeProfileID, "chat")
      XCTAssertNil(store.lastActiveProfileError,
                   "a successful write replaces the broken marker — error must clear")
    }
  }

  func test_reloadActiveProfile_picks_up_externally_broken_marker_after_start() throws {
    // Review v3 F2: prior code read the marker only once in
    // `start()`. An operator who repaired or broke the marker at
    // runtime saw stale state forever. `reloadActiveProfile()` and
    // the FS-watcher reload path both re-read it.
    try withTempProfilesDir { dir in
      try writeProfile(into: dir, name: "chat.toml", id: "chat", displayName: "Chat")
      let active = dir.deletingLastPathComponent()
        .appendingPathComponent("active-profile", isDirectory: false)
      // Start with a clean (absent) marker — no error.
      let store = ProfileStore(directory: dir, activeProfileURL: active)
      try store.start()
      defer { store.stop() }
      XCTAssertNil(store.lastActiveProfileError, "sanity: absent marker starts clean")

      // Operator (or rsync, or container restore) plants a directory
      // at the marker path AFTER start(). Reload must detect it.
      try FileManager.default.createDirectory(at: active,
                                              withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: active) }
      store.reloadActiveProfile()
      guard case .activeProfileReadFailed = store.lastActiveProfileError else {
        return XCTFail("expected .activeProfileReadFailed after runtime planting, got \(String(describing: store.lastActiveProfileError))")
      }
    }
  }

  func test_reloadActiveProfile_clears_error_after_external_repair() throws {
    // Symmetric to the previous test: a marker that was broken at
    // start() must be reload-recoverable without round-tripping
    // through setActiveProfileID (which would force a specific id
    // and is not the right API for the GUI retry button).
    try withTempProfilesDir { dir in
      try writeProfile(into: dir, name: "chat.toml", id: "chat", displayName: "Chat")
      let active = dir.deletingLastPathComponent()
        .appendingPathComponent("active-profile", isDirectory: false)
      try FileManager.default.createDirectory(at: active,
                                              withIntermediateDirectories: true)
      let store = ProfileStore(directory: dir, activeProfileURL: active)
      try store.start()
      defer { store.stop() }
      XCTAssertNotNil(store.lastActiveProfileError, "sanity: broken marker at start")

      // Operator repairs externally (rm -rf the planted dir, then
      // echo the id). GUI hits "Retry" -> reloadActiveProfile.
      try FileManager.default.removeItem(at: active)
      try "chat".write(to: active, atomically: true, encoding: .utf8)
      store.reloadActiveProfile()
      XCTAssertNil(store.lastActiveProfileError,
                   "reloadActiveProfile must clear the stale error after external repair")
      XCTAssertEqual(store.activeProfileID, "chat",
                     "reload must surface the repaired marker's id")
    }
  }

  func test_authoritative_reload_commits_marker_error_even_when_inmemory_was_healthy() throws {
    // Review v4 F2 explicit contract: `reloadActiveProfile()` is the
    // operator-initiated path; a failing read here commits to
    // `_activeProfileError` so a GUI Retry shows the cause.
    try withTempProfilesDir { dir in
      try writeProfile(into: dir, name: "chat.toml", id: "chat", displayName: "Chat")
      let active = dir.deletingLastPathComponent()
        .appendingPathComponent("active-profile", isDirectory: false)
      let store = ProfileStore(directory: dir, activeProfileURL: active)
      try store.start()
      defer { store.stop() }
      try store.setActiveProfileID("chat")
      try FileManager.default.removeItem(at: active)
      try FileManager.default.createDirectory(at: active,
                                              withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: active) }

      store.reloadActiveProfile()
      guard case .activeProfileReadFailed = store.lastActiveProfileError else {
        return XCTFail("authoritative reload must surface read failure even when in-memory was healthy")
      }
      // Review v7 F1: `_activeProfileID` is PRESERVED across a
      // read-failure on the retry path. The disk read failed, not
      // the in-memory truth — wiping the id while the engine
      // subprocess (started against it) is still running would
      // silently mask a known-good selection. The error is surfaced
      // on `lastActiveProfileError` so the GUI banner can render
      // the cause without losing the selection.
      XCTAssertEqual(store.activeProfileID, "chat",
                     "v7 F1: read failure on retry must NOT wipe known-good _activeProfileID")
    }
  }

  func test_reloadActiveProfile_does_not_deadlock_when_called_from_listener_callback() throws {
    // Review v4 F5: listener callbacks run on the store's serial
    // queue. A naive `queue.sync` inside reloadActiveProfile would
    // deadlock when the listener (e.g. a GUI binding firing a
    // one-shot retry on snapshot.activeProfileError) calls back in.
    // Reentrancy is detected via the per-instance `queueKey`; the
    // body runs inline.
    //
    // Guard `fired` with an atomic-store bool (no NSLock) — the
    // listener fan-out re-enters this closure synchronously from
    // the inline reloadLocked, and a non-reentrant lock would
    // deadlock the test itself before the dispatch-queue claim
    // could be exercised.
    try withTempProfilesDir { dir in
      try writeProfile(into: dir, name: "chat.toml", id: "chat", displayName: "Chat")
      let active = dir.deletingLastPathComponent()
        .appendingPathComponent("active-profile", isDirectory: false)
      let store = ProfileStore(directory: dir, activeProfileURL: active)
      try store.start()
      defer { store.stop() }

      let exp = expectation(description: "listener-driven reloadActiveProfile completes")
      let firedFlag = OSAllocatedUnfairLock<Bool>(initialState: false)
      store.addListener { _ in
        let shouldFire = firedFlag.withLock { (f: inout Bool) -> Bool in
          if f { return false }
          f = true
          return true
        }
        guard shouldFire else { return }
        // This call would deadlock the dispatch queue under the
        // prior `queue.sync`-only implementation. Test fails via
        // the wait timeout if reentrancy regresses.
        store.reloadActiveProfile()
        exp.fulfill()
      }
      try store.setActiveProfileID("chat")
      wait(for: [exp], timeout: 5.0)
    }
  }

  func test_setActiveProfileID_cancels_pending_debounced_reload_to_prevent_race() throws {
    // Review v4 F4: setActiveProfileID writes the marker then
    // updates in-memory state. The post-write update now runs inside
    // performOnQueue + cancels any pending debounced reload so a
    // racing background reload cannot clobber the freshly-set id by
    // reading pre-rename disk state.
    try withTempProfilesDir { dir in
      try writeProfile(into: dir, name: "chat.toml", id: "chat", displayName: "Chat")
      let active = dir.deletingLastPathComponent()
        .appendingPathComponent("active-profile", isDirectory: false)
      let store = ProfileStore(directory: dir, activeProfileURL: active)
      try store.start()
      defer { store.stop() }

      // Concurrently drop a profile (triggers debounce) then set the
      // active id. The set must win because it cancels the pending
      // debounce + writes both disk and memory atomically on `queue`.
      try writeProfile(into: dir, name: "race.toml", id: "race", displayName: "Race")
      try store.setActiveProfileID("chat")

      // Even if a debounced reload arrives later, the marker on disk
      // is `chat`, so the eventual reload commits `chat` (idempotent).
      XCTAssertEqual(store.activeProfileID, "chat",
                     "setActiveProfileID must win against a pending debounced reload (review v4 F4)")
      XCTAssertNil(store.lastActiveProfileError)
    }
  }

  func test_createProfile_propagates_dump_failure() throws {
    // Review v4 F1: dump → `.dumpFailed` wrap was claimed by the
    // commit message but had no test. Injection seam on the
    // internal `createProfile(_:filename:dumpProvider:)` overload
    // covers the throwing branch deterministically (the production
    // dump path is defense-in-depth — TOMLKit's convert/parse
    // round-trip is not known to fail on its own output, so a
    // real-world fault is unreachable, but the wrap shape MUST be
    // pinned so a future contributor cannot regress to a silent
    // truncation).
    try withTempProfilesDir { dir in
      let store = ProfileStore(directory: dir,
                               activeProfileURL: dir.deletingLastPathComponent()
                                 .appendingPathComponent("active-profile"))
      try store.start()
      defer { store.stop() }
      let profile = Profile(id: "x", name: "X", model: "m", inferlet: "i")

      struct InjectedDumpFailure: Error, CustomStringConvertible {
        var description: String { "injected dump failure for v4 F1 coverage" }
      }
      XCTAssertThrowsError(
        try store.createProfile(profile, filename: nil) { _ in
          throw InjectedDumpFailure()
        }
      ) { err in
        guard case ProfileStoreError.dumpFailed(let path, let underlying) = err else {
          return XCTFail("expected ProfileStoreError.dumpFailed, got \(err)")
        }
        XCTAssertTrue(path.hasSuffix("x.toml"),
                      "dumpFailed must carry the destination path: \(path)")
        XCTAssertTrue(underlying.contains("injected dump failure"),
                      "dumpFailed must preserve the underlying error description: \(underlying)")
      }
      // The truncated file must NOT have been written.
      XCTAssertFalse(FileManager.default.fileExists(
        atPath: dir.appendingPathComponent("x.toml").path
      ), "createProfile must abort the write when dump throws — no truncated TOML on disk")
    }
  }

  // MARK: - review v5 / cycle-188 architectural decoupling

  func test_non_utf8_marker_surfaces_activeProfileReadFailed_on_authoritative_read() throws {
    // Review v6 F8 (rephrased post-cycle-188): pin the non-UTF-8
    // failure mode on the AUTHORITATIVE read path. Post-cycle-188
    // there is no background marker re-read — the FS-watcher rescan
    // only updates `_entries`, not `_activeProfileError`. The
    // explicit read paths are `start()` (boot) and
    // `reloadActiveProfile()` (operator retry). This test plants
    // non-UTF-8 bytes before start and asserts the boot path
    // surfaces the structured error.
    try withTempProfilesDir { dir in
      try writeProfile(into: dir, name: "chat.toml", id: "chat", displayName: "Chat")
      let active = dir.deletingLastPathComponent()
        .appendingPathComponent("active-profile", isDirectory: false)
      // 0xFF 0xFE 0xFD — invalid UTF-8 by construction.
      try Data([0xFF, 0xFE, 0xFD]).write(to: active)
      defer { try? FileManager.default.removeItem(at: active) }

      let store = ProfileStore(directory: dir, activeProfileURL: active)
      try store.start()
      defer { store.stop() }

      XCTAssertNil(store.activeProfileID,
                   "non-UTF-8 marker must NOT pretend a selection exists")
      guard case .activeProfileReadFailed = store.lastActiveProfileError else {
        return XCTFail("non-UTF-8 marker must commit .activeProfileReadFailed on the authoritative read path, got \(String(describing: store.lastActiveProfileError)) (review v6 F8 / cycle-188)")
      }
    }
  }

  func test_fs_watcher_rescan_does_not_touch_active_profile_state() throws {
    // Post-cycle-188 contract: the FS-watcher rescan path only
    // updates `_entries`. A planted directory at the marker after a
    // successful setActiveProfileID stays invisible to the rescan
    // (no marker re-read), so in-memory state survives unchanged.
    // The error WILL surface on the next authoritative read
    // (reloadActiveProfile / start), not on the background scan.
    try withTempProfilesDir { dir in
      try writeProfile(into: dir, name: "chat.toml", id: "chat", displayName: "Chat")
      let active = dir.deletingLastPathComponent()
        .appendingPathComponent("active-profile", isDirectory: false)
      let store = ProfileStore(directory: dir, activeProfileURL: active)
      try store.start()
      defer { store.stop() }

      try store.setActiveProfileID("chat")
      XCTAssertEqual(store.activeProfileID, "chat")
      XCTAssertNil(store.lastActiveProfileError, "sanity: clean post-set")

      // Plant a directory at the marker — the FS-watcher should NOT
      // see this on its rescan because the marker lives outside the
      // watched directory AND reloadLocked no longer reads it.
      try FileManager.default.removeItem(at: active)
      try FileManager.default.createDirectory(at: active,
                                              withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: active) }

      let exp = expectation(description: "background rescan completes")
      let firedFlag = OSAllocatedUnfairLock<Bool>(initialState: false)
      store.addListener { snap in
        let shouldFire = firedFlag.withLock { (f: inout Bool) -> Bool in
          if f { return false }
          if snap.entries.contains(where: { $0.url.lastPathComponent == "extra.toml" }) {
            f = true
            return true
          }
          return false
        }
        if shouldFire { exp.fulfill() }
      }
      try writeProfile(into: dir, name: "extra.toml", id: "extra", displayName: "Extra")
      wait(for: [exp], timeout: 5.0)

      // FS rescan only touches _entries. Marker state is unchanged.
      XCTAssertEqual(store.activeProfileID, "chat",
                     "FS-watcher rescan must not touch _activeProfileID (cycle-188 architectural decoupling)")
      XCTAssertNil(store.lastActiveProfileError,
                   "FS-watcher rescan must not touch _activeProfileError (cycle-188)")

      // An explicit reloadActiveProfile DOES see the planted directory.
      let snap = store.reloadActiveProfile()
      guard case .activeProfileReadFailed = snap.activeProfileError else {
        return XCTFail("authoritative reloadActiveProfile must surface .activeProfileReadFailed for planted directory, got \(String(describing: snap.activeProfileError))")
      }
    }
  }

  func test_concurrent_setActiveProfileID_keeps_disk_and_memory_consistent() throws {
    // Review v5 F3: pre-v5 the disk write happened off-queue and only
    // the post-write state mutation was queue-serialized. Two
    // concurrent setters could interleave write-then-queue-arrive in
    // opposite orders, leaving disk and memory disagreeing. Post-v5
    // the disk write is inside performOnQueue, so the two operations
    // are one queue-serial unit and disk content always matches the
    // in-memory id at quiescence.
    try withTempProfilesDir { dir in
      try writeProfile(into: dir, name: "alpha.toml", id: "alpha", displayName: "Alpha")
      try writeProfile(into: dir, name: "bravo.toml",  id: "bravo",  displayName: "Bravo")
      let active = dir.deletingLastPathComponent()
        .appendingPathComponent("active-profile", isDirectory: false)
      let store = ProfileStore(directory: dir, activeProfileURL: active)
      try store.start()
      defer { store.stop() }

      let iterations = 50
      for _ in 0..<iterations {
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
          try? store.setActiveProfileID("alpha")
          group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
          try? store.setActiveProfileID("bravo")
          group.leave()
        }
        group.wait()

        // At quiescence, disk content must match in-memory id.
        let onDisk: String?
        if let data = try? Data(contentsOf: active),
           let raw = String(data: data, encoding: .utf8) {
          let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
          onDisk = trimmed.isEmpty ? nil : trimmed
        } else {
          onDisk = nil
        }
        XCTAssertEqual(onDisk, store.activeProfileID,
                       "disk and memory must agree at quiescence (review v5 F3); disk=\(String(describing: onDisk)) memory=\(String(describing: store.activeProfileID))")
      }
    }
  }

  func test_recursion_canary_short_circuits_at_threshold() throws {
    // Review v8 F1: a listener that unconditionally calls
    // `createProfile()` (which synchronously re-enters reloadLocked
    // via performOnQueue) would stack-overflow in release without a
    // canary. Pre-v8 the canary was DEBUG-only — production builds
    // crashed under the same listener pattern. Post-v8 the canary
    // runs unconditionally, short-circuits the fan-out at threshold,
    // and increments `reloadShortCircuitCount` so this test can pin
    // the release behavior.
    try withTempProfilesDir { dir in
      let store = ProfileStore(directory: dir)
      try store.start()
      defer { store.stop() }

      let depthCounter = OSAllocatedUnfairLock<Int>(initialState: 0)
      let cap = ProfileStore.reloadDepthThreshold + 2
      store.addListener { _ in
        let d = depthCounter.withLock { (n: inout Int) -> Int in
          n += 1
          return n
        }
        // Bound the chain so we exit cleanly once the short-circuit
        // has had a chance to fire AND any subsequent listener fires
        // do not keep allocating profiles forever.
        if d >= cap { return }
        let p = Profile(id: "c\(d)", name: "C\(d)",
                        model: "m", inferlet: "chat-apc")
        _ = try? store.createProfile(p)
      }

      // Trigger the chain from the test thread. createProfile uses
      // performOnQueue → queue.sync → reloadLocked sync fan-out →
      // listener-driven recursion. The test thread blocks until the
      // entire reentrant chain terminates (short-circuit at
      // threshold), so no Thread.sleep / runloop spin is needed.
      let root = Profile(id: "root", name: "Root",
                         model: "m", inferlet: "chat-apc")
      _ = try? store.createProfile(root)

      XCTAssertGreaterThan(store.reloadShortCircuitCount, 0,
                           "v8 F1: recursion canary must short-circuit at threshold under listener-from-listener createProfile loops (got reloadShortCircuitCount=\(store.reloadShortCircuitCount))")
    }
  }

  func test_stop_then_start_with_broken_marker_clears_stale_active_id() throws {
    // Review v8 F2: pre-v8 `commitActiveReadResultLocked(.failed)`
    // unconditionally preserved `_activeProfileID`. A store that was
    // `stop()`-ped and then re-`start()`-ed against an externally
    // corrupted marker would resurrect the prior-lifecycle id while
    // surfacing an error for a *different* selection — silent
    // disk-vs-memory divergence at boot. Post-v8 the `.start`
    // CommitSource wipes id on `.failed` so the snapshot reflects
    // disk truth at boot. `.reload` still preserves (v7 F1).
    try withTempProfilesDir { dir in
      try writeProfile(into: dir, name: "chat.toml", id: "chat", displayName: "Chat")
      let active = dir.deletingLastPathComponent()
        .appendingPathComponent("active-profile", isDirectory: false)
      let store = ProfileStore(directory: dir, activeProfileURL: active)
      try store.start()
      try store.setActiveProfileID("chat")
      XCTAssertEqual(store.activeProfileID, "chat", "sanity: clean post-set")
      store.stop()

      // Externally replace marker file with a directory between
      // stop() and the next start().
      try FileManager.default.removeItem(at: active)
      try FileManager.default.createDirectory(at: active,
                                              withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: active) }

      try store.start()
      defer { store.stop() }

      // Boot must commit disk truth, NOT preserve the prior-lifecycle id.
      XCTAssertNil(store.activeProfileID,
                   "v8 F2: stop/start with broken marker must NOT resurface stale prior-lifecycle id; got \(String(describing: store.activeProfileID))")
      guard case .activeProfileReadFailed = store.lastActiveProfileError else {
        return XCTFail("v8 F2: boot must surface .activeProfileReadFailed for broken marker, got \(String(describing: store.lastActiveProfileError))")
      }
    }
  }

  func test_activeProfile_accessor_returns_nil_when_error_is_set() throws {
    // Review v8 F3: the public `activeProfile` accessor must not
    // silently return a clean Profile when the on-disk marker is in
    // an error state. The v7 F1 contract preserves `_activeProfileID`
    // across read failure for engine-continuity reasons, but
    // exposing the cached id through `activeProfile` would let any
    // caller (status-bar UI, debug overlay, XPC bridge) observe a
    // valid Profile while disk is broken. Hiding the cached id
    // behind `_activeProfileError != nil` collapses the broken case
    // to an explicit nil at the accessor boundary.
    try withTempProfilesDir { dir in
      try writeProfile(into: dir, name: "chat.toml", id: "chat", displayName: "Chat")
      let active = dir.deletingLastPathComponent()
        .appendingPathComponent("active-profile", isDirectory: false)
      let store = ProfileStore(directory: dir, activeProfileURL: active)
      try store.start()
      defer { store.stop() }
      try store.setActiveProfileID("chat")
      XCTAssertNotNil(store.activeProfile, "sanity: clean post-set")

      // Provoke a read failure on the retry path. v7 F1 preserves
      // `_activeProfileID`; v8 F3 hides the cached Profile while
      // the error is live.
      try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o000)],
        ofItemAtPath: active.path
      )
      defer {
        try? FileManager.default.setAttributes(
          [.posixPermissions: NSNumber(value: 0o644)],
          ofItemAtPath: active.path
        )
      }
      _ = store.reloadActiveProfile()

      XCTAssertEqual(store.activeProfileID, "chat",
                     "v7 F1 contract: id is preserved under the hood")
      XCTAssertNotNil(store.lastActiveProfileError,
                      "sanity: error is surfaced")
      XCTAssertNil(store.activeProfile,
                   "v8 F3: public activeProfile accessor must return nil when error is set, regardless of preserved id")
    }
  }

  func test_createProfile_from_listener_commits_rescan_synchronously() throws {
    // Review v6 F1 / cycle-188: createProfile-from-listener must see
    // the new entry in `_entries` synchronously. Post-cycle-188 the
    // reentrancy guard is gone entirely — reloadLocked just rescans
    // the directory and fires listeners, with no marker re-read, so
    // there is no recursive marker-read path to protect against.
    // The listener uses a one-shot `createdFromListener` guard to
    // avoid re-creating on the re-fire that its own createProfile
    // triggers (standard observer-pattern contract).
    try withTempProfilesDir { dir in
      try writeProfile(into: dir, name: "chat.toml", id: "chat", displayName: "Chat")
      let active = dir.deletingLastPathComponent()
        .appendingPathComponent("active-profile", isDirectory: false)
      let store = ProfileStore(directory: dir, activeProfileURL: active)
      try store.start()
      defer { store.stop() }

      let createdFromListener = OSAllocatedUnfairLock<Bool>(initialState: false)
      let observed = OSAllocatedUnfairLock<Bool>(initialState: false)
      let listenerDone = expectation(description: "listener completes createProfile + visibility check")

      store.addListener { _ in
        let shouldCreate = createdFromListener.withLock { (f: inout Bool) -> Bool in
          if f { return false }
          f = true
          return true
        }
        if !shouldCreate {
          // Subsequent fires (FS-event-driven) — ignored.
          return
        }
        // Drive createProfile from inside the listener. The reload
        // it triggers re-enters reloadLocked; the guard suppresses
        // listener fan-out but the rescan must still commit.
        let p = Profile(id: "fromListener", name: "From Listener",
                        model: "m", inferlet: "chat-apc")
        _ = try? store.createProfile(p)
        // Immediate-visibility contract: entries MUST contain the
        // new profile synchronously inside this listener.
        observed.withLock { (o: inout Bool) in
          o = store.entries.contains { $0.profile?.id == "fromListener" }
        }
        listenerDone.fulfill()
      }
      wait(for: [listenerDone], timeout: 5.0)

      XCTAssertTrue(observed.withLock { (o: inout Bool) -> Bool in o },
                    "createProfile invoked from a listener must commit rescan synchronously; new entry MUST appear in store.entries immediately (review v6 F1)")
      // Also assert from the test thread (after listener returned)
      // that the store-state contract holds outside the recursive
      // context.
      XCTAssertTrue(store.entries.contains { $0.profile?.id == "fromListener" },
                    "post-listener: entries must still reflect the listener-driven createProfile")
    }
  }

  func test_reloadActiveProfile_preserves_known_good_id_when_read_fails_with_chmod_000() throws {
    // Review v7 F1: a Resume retry that reads the marker MUST NOT
    // wipe a known-good in-memory selection. The engine subprocess
    // may already be running against that id; a transient read
    // failure (NFS hiccup, EIO, Spotlight-touched-marker) on the
    // retry path used to clear `_activeProfileID` and return
    // `.noActiveProfile(afterRetry: true)`, silently masking the
    // truth. Post-v7 the id is preserved across read failures; the
    // error is surfaced on `_activeProfileError` separately.
    //
    // chmod 000 is the closest reproducible analogue of a transient
    // read failure in CI (provokes NSFileReadNoPermissionError from
    // `Data(contentsOf:)`). The repair path — operator chmods back
    // — is not exercised; this test only pins the preservation
    // contract.
    try withTempProfilesDir { dir in
      try writeProfile(into: dir, name: "chat.toml", id: "chat", displayName: "Chat")
      let active = dir.deletingLastPathComponent()
        .appendingPathComponent("active-profile", isDirectory: false)
      let store = ProfileStore(directory: dir, activeProfileURL: active)
      try store.start()
      defer { store.stop() }

      try store.setActiveProfileID("chat")
      XCTAssertEqual(store.activeProfileID, "chat", "sanity: clean post-set")
      XCTAssertNil(store.lastActiveProfileError)

      // Make marker unreadable. Owner cannot open(2) it.
      try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o000)],
        ofItemAtPath: active.path
      )
      defer {
        try? FileManager.default.setAttributes(
          [.posixPermissions: NSNumber(value: 0o644)],
          ofItemAtPath: active.path
        )
      }

      let snap = store.reloadActiveProfile()
      // v9 F1: snapshot masks `activeProfileID` to nil when error is
      // live so consumers following the snapshot pattern cannot
      // reconstruct a clean Profile from a broken state.
      XCTAssertNil(snap.activeProfileID,
                   "v9 F1: snapshot.activeProfileID must be masked to nil when error is live")
      guard case .activeProfileReadFailed = snap.activeProfileError else {
        return XCTFail("returned snapshot must surface .activeProfileReadFailed, got \(String(describing: snap.activeProfileError))")
      }
      // v7 F1: the raw `store.activeProfileID` accessor preserves
      // the in-memory id for engine-continuity; that is the internal
      // state the snapshot mask hides from consumers.
      XCTAssertEqual(store.activeProfileID, "chat",
                     "v7 F1: store.activeProfileID (raw accessor) must reflect preserved id")
      XCTAssertNotNil(store.lastActiveProfileError,
                      "v7 F1: store.lastActiveProfileError must reflect the read failure")
    }
  }

  func test_reloadActiveProfile_returns_snapshot_matching_state() throws {
    // Review v5 F5: the signature was `Void`, forcing callers to
    // poll `lastActiveProfileError` after the call (racy). Post-v5
    // it returns the post-reload snapshot directly.
    try withTempProfilesDir { dir in
      try writeProfile(into: dir, name: "chat.toml", id: "chat", displayName: "Chat")
      let active = dir.deletingLastPathComponent()
        .appendingPathComponent("active-profile", isDirectory: false)
      let store = ProfileStore(directory: dir, activeProfileURL: active)
      try store.start()
      defer { store.stop() }

      // Healthy state.
      try store.setActiveProfileID("chat")
      let healthy = store.reloadActiveProfile()
      XCTAssertEqual(healthy.activeProfileID, "chat",
                     "returned snapshot must carry the current activeProfileID")
      XCTAssertNil(healthy.activeProfileError,
                   "returned snapshot must reflect a clean error state when disk is healthy")

      // Broken state.
      try FileManager.default.removeItem(at: active)
      try FileManager.default.createDirectory(at: active,
                                              withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: active) }
      let broken = store.reloadActiveProfile()
      guard case .activeProfileReadFailed = broken.activeProfileError else {
        return XCTFail("returned snapshot must surface .activeProfileReadFailed, got \(String(describing: broken.activeProfileError))")
      }
      // Review v9 F1: snapshot masks id when error is live.
      XCTAssertNil(broken.activeProfileID,
                   "v9 F1: snapshot.activeProfileID must be masked to nil under live error")
      // Internal v7 F1 contract: raw id is preserved.
      XCTAssertEqual(store.activeProfileID, "chat",
                     "v7 F1: store.activeProfileID (raw) preserves id under error for engine-continuity")
    }
  }

  func test_snapshot_masks_activeProfileID_to_nil_when_error_is_live() throws {
    // Review v9 F1: the snapshot factory (`makeSnapshotLocked`) must
    // mirror the v8 F3 accessor mask. Pre-v9, masking applied only
    // to `store.activeProfile`; a consumer following the documented
    // snapshot pattern
    //   `snap.entries.first { $0.profile?.id == snap.activeProfileID }`
    // could still reconstruct a clean Profile while disk was broken.
    // Post-v9 the snapshot's `activeProfileID` is nil whenever
    // `activeProfileError` is non-nil so both surfaces are
    // consistent.
    try withTempProfilesDir { dir in
      try writeProfile(into: dir, name: "chat.toml", id: "chat", displayName: "Chat")
      let active = dir.deletingLastPathComponent()
        .appendingPathComponent("active-profile", isDirectory: false)
      let store = ProfileStore(directory: dir, activeProfileURL: active)
      try store.start()
      defer { store.stop() }
      try store.setActiveProfileID("chat")

      let listenerSnap = OSAllocatedUnfairLock<ProfileStoreSnapshot?>(initialState: nil)
      let captured = expectation(description: "listener captures broken-state snapshot")
      store.addListener { snap in
        if snap.activeProfileError != nil {
          listenerSnap.withLock { (s: inout ProfileStoreSnapshot?) in s = snap }
          captured.fulfill()
        }
      }
      // Break the marker and trigger an authoritative reload.
      try FileManager.default.removeItem(at: active)
      try FileManager.default.createDirectory(at: active,
                                              withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: active) }
      _ = store.reloadActiveProfile()
      wait(for: [captured], timeout: 5.0)

      let snap = listenerSnap.withLock { (s: inout ProfileStoreSnapshot?) -> ProfileStoreSnapshot? in s }
      guard let snap else {
        return XCTFail("expected to capture a broken-state snapshot")
      }
      XCTAssertNotNil(snap.activeProfileError,
                      "sanity: error is live on captured snapshot")
      XCTAssertNil(snap.activeProfileID,
                   "v9 F1: snapshot.activeProfileID must be masked to nil — the documented listener-surface pattern must not reconstruct a clean Profile while disk is broken")
    }
  }

  func test_stop_resets_cached_directory_state_so_snapshot_does_not_leak_prior_lifecycle() throws {
    // Review v9 F2: stop() must zero out the cached lifecycle state
    // (`_entries`, `_lastSeedError`, `_lastScanError`, etc.) so a
    // post-stop `snapshot` / `entries` / `lastDirectoryError` does
    // not leak the prior session's observations. Pre-v9 only the
    // dispatch source was torn down; cached state from before stop
    // remained visible until the next start completed.
    try withTempProfilesDir { dir in
      try writeProfile(into: dir, name: "a.toml", id: "a", displayName: "A")
      try writeProfile(into: dir, name: "b.toml", id: "b", displayName: "B")
      // Opt out of the #413 example-profile backfill so the entry count is
      // exactly the two fixtures.
      let store = ProfileStore(directory: dir, seedsExampleProfiles: false)
      try store.start()
      // Seed-count-agnostic: the built-in Repeat Boost profile is auto-seeded
      // (#426) on top of the authored set, so assert "populated", not a count.
      XCTAssertFalse(store.entries.isEmpty, "sanity: populated post-start")

      store.stop()

      XCTAssertEqual(store.entries.count, 0,
                     "v9 F2: stop() must clear cached _entries; got \(store.entries.count)")
      XCTAssertNil(store.lastDirectoryError,
                   "v9 F2: stop() must clear cached directory error")
      XCTAssertNil(store.lastActiveProfileError,
                   "v9 F2: stop() must clear cached active-profile error")
      XCTAssertEqual(store.reloadShortCircuitCount, 0,
                     "v9 F2: stop() must zero the canary counter (defense-in-depth)")
    }
  }

  func test_recursion_short_circuit_commits_rescan_so_recursive_writes_are_visible() throws {
    // Review v9 F3: when the canary fires, the recursive
    // `createProfile` calls have already written their TOML files
    // to disk. Pre-v9 the short-circuit returned the cached
    // snapshot without rescanning, leaving those writes silently
    // orphaned from `_entries` until the next external FS event.
    // Post-v9 the short-circuit rescans + commits `_entries` (but
    // still suppresses listener fan-out so the recursion terminates)
    // so `store.entries` reflects every file on disk after the
    // chain settles.
    try withTempProfilesDir { dir in
      let store = ProfileStore(directory: dir)
      try store.start()
      defer { store.stop() }

      // Listener with bounded recursion. Each fire creates a new
      // child profile so the chain progresses until short-circuit.
      let depthCounter = OSAllocatedUnfairLock<Int>(initialState: 0)
      let cap = ProfileStore.reloadDepthThreshold + 2
      store.addListener { _ in
        let d = depthCounter.withLock { (n: inout Int) -> Int in
          n += 1
          return n
        }
        if d >= cap { return }
        let p = Profile(id: "child\(d)", name: "C\(d)",
                        model: "m", inferlet: "chat-apc")
        _ = try? store.createProfile(p)
      }

      let root = Profile(id: "root", name: "Root",
                         model: "m", inferlet: "chat-apc")
      _ = try? store.createProfile(root)

      XCTAssertGreaterThan(store.reloadShortCircuitCount, 0,
                           "sanity: short-circuit must fire")

      // Enumerate disk: every TOML file on disk MUST be visible in
      // `store.entries`. Pre-v9 the short-circuit dropped them
      // silently; post-v9 the rescan commits them even though
      // listener fan-out is suppressed.
      let onDisk = try FileManager.default.contentsOfDirectory(at: dir,
                                                               includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "toml" }
        .map { $0.lastPathComponent }
        .sorted()
      let inEntries = store.entries
        .map { $0.url.lastPathComponent }
        .sorted()
      // #702: entries also carry the always-present base layer, so on-disk
      // files must be a SUBSET of entries (not equal). The point of the
      // assertion is that no recursive write is orphaned.
      XCTAssertTrue(Set(onDisk).isSubset(of: Set(inEntries)),
                    "v9 F3: short-circuit must rescan + commit _entries so recursive createProfile writes are not silently orphaned. onDisk=\(onDisk) entries=\(inEntries)")
    }
  }

  func test_stop_clears_both_activeProfileID_and_activeProfileError_coherently() throws {
    // Review v10 F1: pre-v10 stopInternal cleared `_activeProfileError`
    // but preserved `_activeProfileID`. Post-stop the snapshot mask
    // no longer triggered (error was nil), so a stale prior-lifecycle
    // id re-exposed itself on the snapshot with NO error signal. A
    // consumer (HelperResumeAction) couldn't distinguish "stopped
    // after marker error" from "stopped from clean state". Post-v10
    // the pair is wiped together so the snapshot stays coherent
    // across stop().
    try withTempProfilesDir { dir in
      try writeProfile(into: dir, name: "chat.toml", id: "chat", displayName: "Chat")
      let active = dir.deletingLastPathComponent()
        .appendingPathComponent("active-profile", isDirectory: false)
      let store = ProfileStore(directory: dir, activeProfileURL: active)
      try store.start()
      try store.setActiveProfileID("chat")

      // Provoke v7 F1 preserved-id-with-error pair.
      try FileManager.default.removeItem(at: active)
      try FileManager.default.createDirectory(at: active,
                                              withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: active) }
      _ = store.reloadActiveProfile()
      XCTAssertEqual(store.activeProfileID, "chat",
                     "sanity: v7 F1 preserves id across read failure")
      XCTAssertNotNil(store.lastActiveProfileError,
                      "sanity: error is live pre-stop")

      store.stop()

      // Post-stop: BOTH wiped. No incoherent "id without error" or
      // "error without id" shape.
      XCTAssertNil(store.activeProfileID,
                   "v10 F1: stop() must wipe _activeProfileID alongside _activeProfileError to keep the snapshot mask invariant coherent")
      XCTAssertNil(store.lastActiveProfileError,
                   "v10 F1: stop() must clear _activeProfileError")
    }
  }

  func test_stop_drains_in_flight_reloadLocked_so_reset_is_not_overwritten() throws {
    // Review v10 F2: an in-flight reloadLocked may already have called
    // scanDirectory() unlocked and be about to re-acquire stateLock
    // to commit. Pre-v10 stop() acquired stateLock from an arbitrary
    // thread and reset _entries; the in-flight reload's commit then
    // silently overwrote that reset. Post-v10 stop() wraps its reset
    // in `queue.sync`, forcing the serial queue to drain (any
    // in-flight reloadLocked work item completes first) before the
    // reset commits.
    //
    // Reproducing the race deterministically is awkward, so the test
    // instead exercises the deterministic-by-construction guarantee:
    // schedule an FS event to land a debounced reload on the queue,
    // then call stop() immediately; afterwards assert post-stop state
    // matches the reset invariant (empty entries). Pre-v10 this
    // could fail with a non-empty `entries`; post-v10 the queue.sync
    // pins it.
    try withTempProfilesDir { dir in
      try writeProfile(into: dir, name: "a.toml", id: "a", displayName: "A")
      // Opt out of the #413 example-profile backfill so the count is exactly
      // the one fixture (the test then drops a 2nd to schedule a reload).
      let store = ProfileStore(directory: dir, seedsExampleProfiles: false)
      try store.start()
      // Seed-count-agnostic (#426 auto-seeds Repeat Boost on top of the
      // authored set); this test only needs the store populated post-start.
      XCTAssertFalse(store.entries.isEmpty, "sanity: populated post-start")

      // Drop a new profile to schedule a debounced reload (queue
      // tick due after debounceInterval).
      try writeProfile(into: dir, name: "b.toml", id: "b", displayName: "B")

      // Call stop() immediately. If queue.sync doesn't drain the
      // in-flight reload, the post-stop state could leak.
      store.stop()

      XCTAssertEqual(store.entries.count, 0,
                     "v10 F2: stop() must drain in-flight reloadLocked so its commit cannot overwrite the reset; got entries.count=\(store.entries.count)")
      XCTAssertNil(store.lastDirectoryError,
                   "v10 F2: stop()'s reset must not be overwritten by a racing reload")
    }
  }

  func test_recursion_short_circuit_schedules_one_deferred_fan_out_at_depth_zero() throws {
    // Review v10 F3: when reloadLocked short-circuits, set a pending
    // flag. The outermost reloadLocked's defer fires exactly one
    // listener fan-out (queue.async) when _reloadDepth returns to 0.
    // Non-recursive listeners attached for unrelated reasons (status
    // bar, telemetry) regain their immediate-visibility contract;
    // the recursive listener is one-shot-disciplined and stops on
    // its own.
    try withTempProfilesDir { dir in
      let store = ProfileStore(directory: dir)
      try store.start()
      defer { store.stop() }

      // Recursive listener: bounded so the chain terminates.
      let recursiveDepth = OSAllocatedUnfairLock<Int>(initialState: 0)
      let cap = ProfileStore.reloadDepthThreshold + 2
      store.addListener { _ in
        let d = recursiveDepth.withLock { (n: inout Int) -> Int in
          n += 1
          return n
        }
        if d >= cap { return }
        let p = Profile(id: "rec\(d)", name: "R\(d)",
                        model: "m", inferlet: "chat-apc")
        _ = try? store.createProfile(p)
      }

      // Non-recursive listener: counts its fires. The post-recursion
      // deferred fan-out must reach it AT LEAST once even when the
      // recursive chain hits short-circuit.
      let observerFires = OSAllocatedUnfairLock<Int>(initialState: 0)
      let observed = expectation(description: "non-recursive listener observes deferred fan-out")
      store.addListener { _ in
        let n = observerFires.withLock { (n: inout Int) -> Int in
          n += 1
          return n
        }
        if n == 1 { observed.fulfill() }
      }

      // Trigger the chain.
      let root = Profile(id: "root", name: "Root",
                         model: "m", inferlet: "chat-apc")
      _ = try? store.createProfile(root)

      wait(for: [observed], timeout: 5.0)

      XCTAssertGreaterThan(store.reloadShortCircuitCount, 0,
                           "sanity: short-circuit fired during the chain")
      XCTAssertGreaterThan(observerFires.withLock { (n: inout Int) -> Int in n }, 0,
                           "v10 F3: non-recursive listener must receive a deferred fan-out after short-circuit")
    }
  }

  func test_reloadShortCircuitCount_is_process_monotonic_across_stop_start() throws {
    // Review v11 F4: the canary is a lifetime signal, not a
    // per-lifecycle counter. A transient stop/start cycle (settings
    // panel reopen, helper resume) must not erase the cumulative
    // signal that the recursion canary tripped.
    try withTempProfilesDir { dir in
      let store = ProfileStore(directory: dir)
      try store.start()

      // Drive the canary at least once.
      let depthCounter = OSAllocatedUnfairLock<Int>(initialState: 0)
      let cap = ProfileStore.reloadDepthThreshold + 2
      store.addListener { _ in
        let d = depthCounter.withLock { (n: inout Int) -> Int in
          n += 1
          return n
        }
        if d >= cap { return }
        let p = Profile(id: "rec\(d)", name: "R\(d)",
                        model: "m", inferlet: "chat-apc")
        _ = try? store.createProfile(p)
      }
      let root = Profile(id: "root", name: "Root",
                         model: "m", inferlet: "chat-apc")
      _ = try? store.createProfile(root)

      let before = store.reloadShortCircuitCount
      XCTAssertGreaterThan(before, 0, "sanity: canary fired at least once")

      // Stop / restart.
      store.stop()
      try store.start()
      defer { store.stop() }

      let after = store.reloadShortCircuitCount
      XCTAssertEqual(after, before,
                     "v11 F4: stopInternal must NOT reset reloadShortCircuitCount — canary is process-monotonic across stop/start; before=\(before) after=\(after)")
    }
  }

  func test_post_stop_deferred_async_callback_is_gated_by_lifecycle_epoch() throws {
    // Review v11 F2 / v12 F2: realistic hazard — one deferred async
    // callback runs and inline-calls `store.stop()`. That bumps the
    // lifecycle epoch on the SAME queue tick path. Subsequent
    // deferred callbacks (enqueued by the same defer's fan-out loop
    // but not yet executed) must observe the epoch shift and no-op.
    // Without the gate, callback #2..N fire with a pre-stop snapshot
    // against a torn-down store.
    //
    // Test shape:
    //   · Listener A — first in registration order, fires
    //     synchronously on the deferred async tick, calls
    //     `store.stop()` inline (queueKey detection routes to the
    //     in-queue inline path, bumping the epoch immediately).
    //   · Listener B — second in registration order, would fire
    //     after A on the next queue tick. Its dispatched epoch was
    //     captured at depth-0 unwind; the gate must see A's bump
    //     and skip B.
    try withTempProfilesDir { dir in
      let store = ProfileStore(directory: dir)
      try store.start()

      // Recursive listener — drives the short-circuit + deferred
      // fan-out enqueue. Bounded so the chain terminates.
      let recursiveDepth = OSAllocatedUnfairLock<Int>(initialState: 0)
      let cap = ProfileStore.reloadDepthThreshold + 2
      store.addListener { _ in
        let d = recursiveDepth.withLock { (n: inout Int) -> Int in
          n += 1
          return n
        }
        if d >= cap { return }
        let p = Profile(id: "rec\(d)", name: "R\(d)",
                        model: "m", inferlet: "chat-apc")
        _ = try? store.createProfile(p)
      }

      // Listener A — armed AFTER the synchronous outer fan-out so it
      // fires only on the deferred async tick. Calls store.stop()
      // inline, which (via queueKey) bumps the epoch on the same
      // tick.
      let armed = OSAllocatedUnfairLock<Bool>(initialState: false)
      let aFired = OSAllocatedUnfairLock<Bool>(initialState: false)
      store.addListener { _ in
        guard armed.withLock({ (a: inout Bool) -> Bool in a }) else { return }
        aFired.withLock { (f: inout Bool) in f = true }
        // Inline stop. queueKey on-queue branch fires synchronously,
        // bumping `_lifecycleEpoch` before listener B's queue.async
        // tick runs.
        store.stop()
      }

      // Listener B — armed AFTER outer sync fan-out too. Without
      // the gate, would fire on its deferred async tick after A's
      // tick. With the gate, A's stop() shifted the epoch and B's
      // dispatch (captured the prior epoch) skips.
      let bFired = OSAllocatedUnfairLock<Bool>(initialState: false)
      store.addListener { _ in
        guard armed.withLock({ (a: inout Bool) -> Bool in a }) else { return }
        bFired.withLock { (f: inout Bool) in f = true }
      }

      // Trigger the chain. Sync queue.sync drives the outer
      // reloadLocked, which short-circuits + the depth-0 defer
      // enqueues the deferred fan-out via queue.async for ALL
      // listeners (recursive + A + B).
      let root = Profile(id: "root", name: "Root",
                         model: "m", inferlet: "chat-apc")
      _ = try? store.createProfile(root)

      // Arm. Deferred async ticks run on the queue; they will see
      // armed = true.
      armed.withLock { (a: inout Bool) in a = true }

      // Wait until A has fired (which calls stop()). After A
      // returns, B's tick is next on the queue; we want to observe
      // whether it fires.
      let aExpect = expectation(description: "listener A fires + calls stop")
      DispatchQueue.global().async {
        while !aFired.withLock({ (f: inout Bool) -> Bool in f }) {
          Thread.sleep(forTimeInterval: 0.01)
        }
        // Give B's tick a chance to run after A's tick has finished.
        Thread.sleep(forTimeInterval: 0.2)
        aExpect.fulfill()
      }
      wait(for: [aExpect], timeout: 5.0)

      XCTAssertTrue(aFired.withLock { (f: inout Bool) -> Bool in f },
                    "sanity: listener A's deferred tick ran")
      XCTAssertFalse(bFired.withLock { (f: inout Bool) -> Bool in f },
                     "v11 F2 (v12 fix): listener B's deferred tick MUST NOT fire after A's inline stop() shifted the lifecycle epoch — the gate must reject the now-stale dispatch")
    }
  }

  func test_short_circuit_deferred_fan_out_uses_stashed_snapshot_not_post_unwind_state() throws {
    // Review v11 F1: the snapshot delivered by the depth-0 deferred
    // fan-out must reflect state AT short-circuit time, not state
    // after intermediate unwind frames whose normal fan-out fired
    // listeners that may have mutated the store. Pre-v11 the defer
    // built a fresh snapshot via `makeSnapshotLocked()` — any
    // mutation between short-circuit and depth-0 leaked into the
    // delivered snapshot, breaking the documented "writes you
    // missed" contract.
    try withTempProfilesDir { dir in
      try writeProfile(into: dir, name: "chat.toml", id: "chat", displayName: "Chat")
      let active = dir.deletingLastPathComponent()
        .appendingPathComponent("active-profile", isDirectory: false)
      let store = ProfileStore(directory: dir, activeProfileURL: active)
      try store.start()
      defer { store.stop() }
      try store.setActiveProfileID("chat")

      // Listener A: recursive + on first fire ALSO clears the active
      // profile id between the short-circuit (deep in the chain) and
      // the outermost defer. Without v11 F1 stashing, the deferred
      // snapshot would reflect activeProfileID == nil (post-clear);
      // with v11 F1 stashing, the deferred snapshot reflects the
      // pre-clear state captured at short-circuit.
      let recursiveDepth = OSAllocatedUnfairLock<Int>(initialState: 0)
      let cap = ProfileStore.reloadDepthThreshold + 2
      let didClear = OSAllocatedUnfairLock<Bool>(initialState: false)
      store.addListener { snap in
        let d = recursiveDepth.withLock { (n: inout Int) -> Int in
          n += 1
          return n
        }
        if d == 1 {
          // First listener fire (outer reloadLocked normal path).
          // Trigger the recursive chain.
          let p = Profile(id: "rec1", name: "R1",
                          model: "m", inferlet: "chat-apc")
          _ = try? store.createProfile(p)
          // After the chain returns, clear active profile id
          // BEFORE the deferred fan-out runs (depth-0 defer fires
          // after this body returns). Pre-v11 the depth-0 defer
          // would observe activeProfileID == nil; post-v11 it
          // delivers the stashed snapshot from short-circuit
          // (which had activeProfileID == "chat").
          _ = try? store.clearActiveProfileID()
        } else if d <= cap {
          let p = Profile(id: "rec\(d)", name: "R\(d)",
                          model: "m", inferlet: "chat-apc")
          _ = try? store.createProfile(p)
        }
        // Mark the deferred fan-out's A-callback. ProfileStore
        // dispatches snap1 (the stash) and snap2 (clear's direct fan-
        // out) to every listener via per-listener `queue.async`, plus
        // d1's synchronous fan-out delivers its own snap. The
        // deferred fan-out's snap1 is uniquely identified by the
        // pair `activeProfileID == "chat"` (stashed pre-clear) AND
        // `entries.count >= 5` (chat+trigger+rec1+rec2+rec3, all
        // committed by d4 short-circuit). d1's sync snap has only 2
        // entries; clear's snap2 has `activeProfileID == nil`; any
        // fresh top-level reloadLocked re-entered from queue.async
        // also reports `activeProfileID == nil` (post-clear). Flipping
        // didClear here (rather than from the test thread post-
        // createProfile) puts the flip on the same serial queue as
        // listener B's iterations — A(snap1) and B(snap1) are
        // consecutive FIFO entries dispatched by the same depth-0
        // defer, so B(snap1) is guaranteed to see didClear == true
        // before any non-deferred B fire reaches the gate. This
        // closes the TOCTOU between main flipping the flag and the
        // queue worker draining the dispatch list (v13 fix).
        if snap.activeProfileID == "chat" && snap.entries.count >= 5 {
          didClear.withLock { (b: inout Bool) in b = true }
        }
      }
      // Listener B: captures the deferred-fan-out snapshot.
      let captured = OSAllocatedUnfairLock<ProfileStoreSnapshot?>(initialState: nil)
      let fanOutFired = expectation(description: "deferred fan-out delivers stashed snapshot")
      store.addListener { snap in
        // Listener A flips didClear inside its A(snap1) iteration —
        // see the v13 comment above. With dispatch FIFO on a serial
        // queue, the very next B iteration after that flip IS
        // B(snap1), so this gate latches exactly the deferred fan-
        // out's snapshot.
        if didClear.withLock({ (b: inout Bool) -> Bool in b }) {
          captured.withLock { (s: inout ProfileStoreSnapshot?) in
            if s == nil {
              s = snap
              fanOutFired.fulfill()
            }
          }
        }
      }

      // Trigger via createProfile on test thread.
      let trigger = Profile(id: "trigger", name: "Trigger",
                            model: "m", inferlet: "chat-apc")
      _ = try? store.createProfile(trigger)

      // The deferred async fan-out should have fired by now —
      // OR will fire on next tick. Wait.
      wait(for: [fanOutFired], timeout: 5.0)

      let snap = captured.withLock { (s: inout ProfileStoreSnapshot?) -> ProfileStoreSnapshot? in s }
      guard let snap else {
        return XCTFail("expected to capture deferred fan-out snapshot")
      }
      // Review v12 F1: the load-bearing assertion is the field that
      // DIFFERS between stashed and fresh. `_entries` is committed
      // by both code paths (short-circuit's commit + a hypothetical
      // fresh `makeSnapshotLocked` at depth-0 both observe the same
      // committed entries). `activeProfileID` is the discriminator:
      //   · stashed (correct) — "chat", captured BEFORE listener A
      //     cleared the active id.
      //   · fresh (regression) — nil, reflecting post-clear state.
      // Asserting the discriminator means a future refactor that
      // removes the stash plumbing turns this test red.
      XCTAssertEqual(snap.activeProfileID, "chat",
                     "v11 F1 (v12 fix): deferred fan-out must deliver the SNAPSHOT STASHED at short-circuit time, capturing pre-clear activeProfileID — fresh-at-depth-0 would observe nil")
      // Secondary sanity: entries reflect committed state regardless
      // of stashed-vs-fresh, kept as a non-load-bearing check.
      XCTAssertGreaterThan(snap.entries.count, 1,
                           "sanity: stashed snapshot also carries the committed recursive writes")
    }
  }

  func test_createProfile_writes_toml_and_makes_entry_visible_immediately() throws {
    try withTempProfilesDir { dir in
      let active = dir.deletingLastPathComponent()
        .appendingPathComponent("active-profile", isDirectory: false)
      let store = ProfileStore(directory: dir, activeProfileURL: active)
      try store.start()
      defer { store.stop() }

      let p = Profile(id: "code", name: "Code",
                      model: "llama-code-7b.gguf", inferlet: "code-apc")
      let url = try store.createProfile(p)
      XCTAssertEqual(url.lastPathComponent, "code.toml",
                     "default filename must be `<profile.id>.toml`")
      XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
      // createProfile force-reloads — the entry is visible without
      // waiting on the FS watcher debounce.
      XCTAssertTrue(store.entries.contains { $0.profile?.id == "code" })
      try store.setActiveProfileID("code")
      XCTAssertEqual(store.activeProfile?.id, "code")
      XCTAssertEqual(store.activeProfile?.model, "llama-code-7b.gguf")
    }
  }

  // MARK: -  rework: profile-model lookup + write-back

  /// `modelForProfile` wiring: the production swap coordinator
  /// must learn a profile's model from the store. A bare lookup that
  /// the closure can call.
  func test_model_forProfileID_returns_profile_model_and_nil_for_unknown() throws {
    try withTempProfilesDir { dir in
      try writeProfile(into: dir, name: "chat.toml", id: "chat", displayName: "Chat")
      let body = """
      id = "code"
      name = "Code"
      model = "qwen2.5-coder-7b.gguf"
      inferlet = "chat-apc"
      """
      try body.write(to: dir.appendingPathComponent("code.toml"),
                     atomically: true, encoding: .utf8)
      let store = ProfileStore(directory: dir)
      try store.start()
      defer { store.stop() }

      XCTAssertEqual(store.model(forProfileID: "code"), "qwen2.5-coder-7b.gguf")
      XCTAssertEqual(store.model(forProfileID: "chat"), "m")
      XCTAssertNil(store.model(forProfileID: "does-not-exist"),
                   "unknown profile id must resolve to nil, not a fabricated default")
    }
  }

  /// `setModel` write-back ( step 2/5): assigning a profile's
  /// default model persists to disk, preserves every other field, and
  /// is visible immediately (force-reload, no watcher wait).
  func test_setModel_persists_new_model_and_preserves_other_fields() throws {
    try withTempProfilesDir { dir in
      let body = """
      id = "chat"
      name = "Chat"
      icon = "bubble.left.and.bubble.right"
      model = "old-model.gguf"
      inferlet = "chat-apc"
      system_prompt = "You are helpful."

      [sampling]
      temperature = 0.5
      top_p = 0.8
      max_tokens = 1024
      """
      try body.write(to: dir.appendingPathComponent("chat.toml"),
                     atomically: true, encoding: .utf8)
      let store = ProfileStore(directory: dir)
      try store.start()
      defer { store.stop() }

      try store.setModel("new-model.gguf", forProfileID: "chat")

      XCTAssertEqual(store.model(forProfileID: "chat"), "new-model.gguf")
      let profile = try XCTUnwrap(store.entries.first { $0.profile?.id == "chat" }?.profile)
      XCTAssertEqual(profile.model, "new-model.gguf")
      XCTAssertEqual(profile.name, "Chat", "name must survive the model write")
      XCTAssertEqual(profile.icon, "bubble.left.and.bubble.right")
      XCTAssertEqual(profile.inferlet, "chat-apc", "inferlet must survive the model write")
      XCTAssertEqual(profile.systemPrompt, "You are helpful.")
      XCTAssertEqual(profile.sampling.temperature, 0.5, accuracy: 0.0001)
      XCTAssertEqual(profile.sampling.maxTokens, 1024)

      // On-disk round-trip: a fresh scan of the same dir sees the new model.
      let (reloaded, _) = ProfileStore.scan(directory: dir)
      XCTAssertEqual(reloaded.first { $0.profile?.id == "chat" }?.profile?.model,
                     "new-model.gguf",
                     "model write must land on disk, not just in-memory")
    }
  }


  func test_clearModel_removes_default_and_preserves_profile_as_valid_no_default_state() throws {
    try withTempProfilesDir { dir in
      let body = """
      id = "chat"
      name = "Chat"
      icon = "bubble.left.and.bubble.right"
      model = "deleted-model.gguf"
      inferlet = "chat-apc"
      system_prompt = "You are helpful."

      [sampling]
      temperature = 0.5
      top_p = 0.8
      max_tokens = 1024
      """
      try body.write(to: dir.appendingPathComponent("chat.toml"),
                     atomically: true, encoding: .utf8)
      let store = ProfileStore(directory: dir)
      try store.start()
      defer { store.stop() }

      try store.clearModel(forProfileID: "chat")

      XCTAssertNil(store.model(forProfileID: "chat"),
                   "cleared profile default must resolve as no default, not a fabricated fallback")
      let profile = try XCTUnwrap(store.entries.first { $0.profile?.id == "chat" }?.profile)
      XCTAssertNil(profile.model,
                   "profile remains valid while explicitly carrying no default model")
      XCTAssertEqual(profile.name, "Chat", "name must survive the model clear")
      XCTAssertEqual(profile.icon, "bubble.left.and.bubble.right")
      XCTAssertEqual(profile.inferlet, "chat-apc")
      XCTAssertEqual(profile.systemPrompt, "You are helpful.")
      XCTAssertEqual(profile.sampling.temperature, 0.5, accuracy: 0.0001)
      XCTAssertEqual(profile.sampling.maxTokens, 1024)

      let disk = try String(contentsOf: dir.appendingPathComponent("chat.toml"), encoding: .utf8)
      XCTAssertFalse(disk.contains("model ="),
                     "clearing the default should remove the TOML model key rather than write an empty or fallback value")
      let (reloaded, _) = ProfileStore.scan(directory: dir)
      let reparsed = try XCTUnwrap(reloaded.first { $0.profile?.id == "chat" }?.profile)
      XCTAssertNil(reparsed.model,
                   "a fresh scan must keep the cleared profile parseable as no-default")
    }
  }

  func test_profilesReferencingModel_returns_names_and_clearModels_updates_all_matches() throws {
    try withTempProfilesDir { dir in
      let shared = "deleted-model.gguf"
      let profiles = [
        ("chat.toml", "chat", "Chat", shared),
        ("fast.toml", "fast", "Repeat Boost", shared),
        ("code.toml", "code", "Code", "other-model.gguf"),
      ]
      for (filename, id, name, model) in profiles {
        let body = """
        id = "\(id)"
        name = "\(name)"
        model = "\(model)"
        inferlet = "chat-apc"
        """
        try body.write(to: dir.appendingPathComponent(filename),
                       atomically: true, encoding: .utf8)
      }
      let store = ProfileStore(directory: dir)
      try store.start()
      defer { store.stop() }

      let affected = store.profilesReferencingModel(shared)
      XCTAssertEqual(affected.map(\.name), ["Chat", "Repeat Boost"],
                     "delete confirmation must be able to show affected profile names in stable order")

      try store.clearModelDefaults(referencing: shared)

      XCTAssertNil(store.model(forProfileID: "chat"))
      XCTAssertNil(store.model(forProfileID: "fast"))
      XCTAssertEqual(store.model(forProfileID: "code"), "other-model.gguf",
                     "non-referencing profiles must not be changed")
    }
  }

  func test_withClearedModelDefaults_restores_defaults_when_operation_fails() throws {
    try withTempProfilesDir { dir in
      let shared = "deleted-model.gguf"
      try writeProfile(into: dir, name: "chat.toml", id: "chat", displayName: "Chat", model: shared)
      try writeProfile(into: dir, name: "fast.toml", id: "fast", displayName: "Repeat Boost", model: shared)
      let store = ProfileStore(directory: dir)
      try store.start()
      defer { store.stop() }

      XCTAssertThrowsError(try store.withClearedModelDefaults(referencing: shared) {
        throw ProfileStoreDefaultsTransactionProbeError.trashFailed
      }) { error in
        guard case let transaction as ProfileModelDefaultsTransactionError = error,
              case .operationFailed(_, _, _, let rollback) = transaction else {
          return XCTFail("expected operationFailed transaction error, got \(error)")
        }
        XCTAssertEqual(rollback, .succeeded,
                       "failed model trash must report that cleared defaults were restored")
        XCTAssertTrue(transaction.description.contains("restored"),
                      "user-visible delete error must distinguish recovered profile defaults; got: \(transaction)")
      }

      XCTAssertEqual(store.model(forProfileID: "chat"), shared)
      XCTAssertEqual(store.model(forProfileID: "fast"), shared)
    }
  }

  func test_withClearedModelDefaults_rolls_back_previously_cleared_profile_when_later_clear_fails() throws {
    try withTempProfilesDir { dir in
      let shared = "deleted-model.gguf"
      try writeProfile(into: dir, name: "chat.toml", id: "chat", displayName: "Chat", model: shared)
      try writeProfile(into: dir, name: "fast.toml", id: "fast", displayName: "Repeat Boost", model: shared)
      let store = ProfileStore(directory: dir)
      try store.start()
      defer { store.stop() }
      var operationRan = false

      XCTAssertThrowsError(try store.withClearedModelDefaults(
        referencing: shared,
        writeProfile: { profile, filename in
          if profile.id == "fast", profile.model == nil {
            throw ProfileStoreDefaultsTransactionProbeError.profileWriteFailed
          }
          try store.createProfile(profile, filename: filename)
        },
        operation: {
          operationRan = true
        }
      )) { error in
        guard case let transaction as ProfileModelDefaultsTransactionError = error,
              case .clearFailed(_, let cleared, _, let rollback) = transaction else {
          return XCTFail("expected clearFailed transaction error, got \(error)")
        }
        XCTAssertEqual(cleared.map(\.id), ["chat"],
                       "error must report the exact profile defaults that needed rollback")
        XCTAssertEqual(rollback, .succeeded,
                       "partial profile clear failure must roll back earlier clears before surfacing")
      }

      XCTAssertFalse(operationRan, "model trash operation must not run after a partial profile clear failure")
      XCTAssertEqual(store.model(forProfileID: "chat"), shared)
      XCTAssertEqual(store.model(forProfileID: "fast"), shared)
    }
  }

  func test_setModel_throws_for_unknown_profile() throws {
    try withTempProfilesDir { dir in
      try writeProfile(into: dir, name: "chat.toml", id: "chat", displayName: "Chat")
      let store = ProfileStore(directory: dir)
      try store.start()
      defer { store.stop() }

      XCTAssertThrowsError(try store.setModel("x.gguf", forProfileID: "ghost"),
                           "setting a model on a non-existent profile must throw, not silently no-op")
    }
  }

  // MARK: - built-in Repeat Boost seed (#426; slug #628)

  func test_base_repeat_boost_present_on_fresh_install() throws {
    try withTempProfilesDir { dir in
      let store = ProfileStore(directory: dir)
      try store.start()
      defer { store.stop() }

      let onDisk = dir.appendingPathComponent(ProfileStore.defaultRepeatBoostFilename)
      XCTAssertFalse(FileManager.default.fileExists(atPath: onDisk.path),
                     "#702: the Repeat Boost built-in is in-code; nothing is seeded to disk")
      let entry = try XCTUnwrap(store.entries.first {
        $0.profile?.id == ProfileStore.defaultRepeatBoostProfileID
      })
      XCTAssertNil(entry.error)
      XCTAssertEqual(entry.profile?.speculation, Profile.Speculation(enabled: true))
      XCTAssertEqual(entry.profile?.sampling.temperature, 0,
                     "Repeat Boost is greedy — temperature must be 0")
    }
  }

  func test_base_repeat_boost_present_in_existing_install_with_only_chat() throws {
    try withTempProfilesDir { dir in
      // Pre-existing byte-equal chat.toml (existing install). Repeat Boost is
      // a base built-in, present in `entries` regardless of on-disk files.
      try ProfileStore.defaultChatTOML.write(
        to: dir.appendingPathComponent("chat.toml"), atomically: true, encoding: .utf8)
      let store = ProfileStore(directory: dir)
      try store.start()
      defer { store.stop() }

      XCTAssertNotNil(store.entries.first {
        $0.profile?.id == ProfileStore.defaultRepeatBoostProfileID
      }?.profile, "existing install must surface the Repeat Boost base built-in")
    }
  }

  // MARK: - #702 base/user two-layer

  /// The base layer yields all four built-ins even when the directory scan
  /// fails (dir unreadable) — base entries are in-code, not scanned.
  func test_base_layer_present_when_directory_scan_fails() throws {
    let missing = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("pie-does-not-exist-\(UUID().uuidString)", isDirectory: true)
    let (entries, scanErr) = ProfileStore.effectiveScan(directory: missing)
    XCTAssertNotNil(scanErr, "scanning a missing dir must report a scan error")
    let ids = Set(entries.compactMap { $0.profile?.id })
    XCTAssertEqual(ids, ["chat", "repeat-boost", "tree-of-thought", "json-think", "best-of-n"],
                   "all base built-ins must be present even when the scan fails")
  }

  /// #690/#702: the Best-of-N example is a base built-in — present in entries
  /// on a fresh install without a seeded file, gated by seedsExampleProfiles
  /// alongside tree-of-thought (excluded from hermetic scans).
  func test_base_best_of_n_example_present_and_gated() throws {
    try withTempProfilesDir { dir in
      // Production default (includeExample=true): present, no file on disk.
      let store = ProfileStore(directory: dir)
      try store.start()
      defer { store.stop() }
      XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("best-of-n.toml").path),
                     "#702: the Best-of-N built-in is in-code; nothing is seeded to disk")
      let entry = try XCTUnwrap(store.entries.first { $0.profile?.id == "best-of-n" })
      XCTAssertEqual(entry.profile?.name, "Best of N")
      XCTAssertNil(entry.error)
    }
    // Hermetic scan (includeExample=false): excluded like tree-of-thought.
    try withTempProfilesDir { dir in
      let (entries, _) = ProfileStore.effectiveScan(directory: dir, includeExample: false)
      let ids = Set(entries.compactMap { $0.profile?.id })
      XCTAssertFalse(ids.contains("best-of-n"), "examples excluded when includeExample=false")
      XCTAssertFalse(ids.contains("tree-of-thought"))
      XCTAssertTrue(ids.isSuperset(of: ["chat", "repeat-boost", "json-think"]))
    }
  }

  /// A valid user file whose id == a base id OVERRIDES the base built-in;
  /// the override wins and no duplicate base entry remains.
  func test_user_file_overrides_base_built_in_by_id() throws {
    try withTempProfilesDir { dir in
      // Customize the chat built-in by pinning a model — a real override.
      let override = """
      id = "chat"
      name = "My Chat"
      model = "Org/Repo/pinned.gguf"
      inferlet = "chat-apc"
      """
      try override.write(to: dir.appendingPathComponent("chat.toml"),
                         atomically: true, encoding: .utf8)
      let store = ProfileStore(directory: dir)
      try store.start()
      defer { store.stop() }

      let chats = store.entries.filter { $0.profile?.id == "chat" }
      XCTAssertEqual(chats.count, 1, "override must replace the base, not duplicate it")
      XCTAssertEqual(chats.first?.profile?.name, "My Chat")
      XCTAssertEqual(chats.first?.profile?.model, "Org/Repo/pinned.gguf",
                     "the user override (pinned model) must win over the base default")
    }
  }

  /// A parse-failed user file (non-base id) is IGNORED + surfaced as a noise
  /// entry — it never removes or shadows a base built-in.
  func test_invalid_user_file_is_surfaced_without_shadowing_base() throws {
    try withTempProfilesDir { dir in
      try "this is not = valid = toml [[[".write(
        to: dir.appendingPathComponent("broken.toml"), atomically: true, encoding: .utf8)
      let store = ProfileStore(directory: dir)
      try store.start()
      defer { store.stop() }

      // Base built-ins intact.
      let ids = Set(store.entries.compactMap { $0.profile?.id })
      XCTAssertTrue(ids.isSuperset(of: ["chat", "repeat-boost", "json-think"]),
                    "a broken user file must not remove any base built-in")
      // The broken file is surfaced (present as an error entry), not dropped.
      let broken = try XCTUnwrap(store.entries.first { $0.url.lastPathComponent == "broken.toml" })
      XCTAssertNil(broken.profile)
      XCTAssertNotNil(broken.error, "the broken user file must be surfaced, not silently dropped")
    }
  }

  /// Migration: a stale UNPARSEABLE built-in file is moved aside to `.bak`
  /// (so it stops shadowing the base), and the base built-in still applies.
  func test_migration_backs_up_stale_unparseable_builtin() throws {
    try withTempProfilesDir { dir in
      // An old-version chat.toml missing required fields (id only).
      try "id = \"chat\"\n".write(
        to: dir.appendingPathComponent("chat.toml"), atomically: true, encoding: .utf8)
      let store = ProfileStore(directory: dir)
      try store.start()
      defer { store.stop() }

      let fm = FileManager.default
      XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("chat.toml").path),
                     "stale unparseable built-in must be moved aside")
      XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("chat.toml.bak").path),
                    "the stale file must be preserved as <name>.toml.bak")
      // Base chat still applies, cleanly.
      let chat = try XCTUnwrap(store.entries.first { $0.profile?.id == "chat" })
      XCTAssertNotNil(chat.profile)
      XCTAssertNil(chat.error)
    }
  }

  /// Migration: a byte-equal seeded built-in is deleted as redundant (the
  /// base provides it); a customized valid one is kept as an override.
  func test_migration_deletes_redundant_keeps_customized() throws {
    try withTempProfilesDir { dir in
      // Redundant: byte-equal to the base.
      try ProfileStore.defaultChatTOML.write(
        to: dir.appendingPathComponent("chat.toml"), atomically: true, encoding: .utf8)
      // Customized + valid: differs from base, parses.
      let customJSON = ProfileStore.defaultJSONThinkTOML
        .replacingOccurrences(of: "JSON Think", with: "My JSON")
      try customJSON.write(
        to: dir.appendingPathComponent("json-think.toml"), atomically: true, encoding: .utf8)

      let store = ProfileStore(directory: dir)
      try store.start()
      defer { store.stop() }

      let fm = FileManager.default
      XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("chat.toml").path),
                     "byte-equal seeded built-in must be deleted as redundant")
      XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("json-think.toml").path),
                    "a customized valid built-in must be kept as an override")
      XCTAssertEqual(store.entries.first { $0.profile?.id == "json-think" }?.profile?.name,
                     "My JSON", "the kept override must win over the base")
    }
  }

  /// #702: a broken customization of a built-in (override fails to parse) is
  /// moved to `.bak` and the app default re-applies — and that SUCCESSFUL
  /// revert must surface a non-fatal notice so the operator is not silently
  /// reverted. Verify the picker/base default holds after the revert.
  func test_broken_builtin_override_revert_surfaces_notice_and_applies_base() throws {
    try withTempProfilesDir { dir in
      // A user pinned a model onto Repeat Boost, then the file got corrupted
      // (missing required fields) — unparseable.
      try "id = \"repeat-boost\"\nname = \"My Repeat\"\n".write(
        to: dir.appendingPathComponent(ProfileStore.defaultRepeatBoostFilename),
        atomically: true, encoding: .utf8)
      let store = ProfileStore(directory: dir)
      try store.start()
      defer { store.stop() }

      // Revert notice surfaced (both the accessor and the snapshot channel).
      let notices = store.lastBuiltinRevertNotices
      XCTAssertEqual(notices, store.snapshot.builtinRevertNotices)
      let notice = try XCTUnwrap(notices.first { $0.profileID == "repeat-boost" })
      XCTAssertEqual(notice.profileName, "Repeat Boost")
      XCTAssertEqual(notice.bakFilename, "repeat-boost.toml.bak")

      // The broken file was moved aside; no move FAILURE, so directoryError is
      // clean (the revert is non-fatal, not a _builtinSeedError).
      let fm = FileManager.default
      XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("repeat-boost.toml.bak").path))
      XCTAssertNil(store.lastDirectoryError, "a successful revert must not surface as a directory error")

      // The base default applies for the built-in slot (picker shows the app
      // default, not the broken override).
      let entry = try XCTUnwrap(store.entries.first { $0.profile?.id == "repeat-boost" })
      XCTAssertNil(entry.error)
      XCTAssertEqual(entry.profile?.name, "Repeat Boost",
                     "after a revert the base default (not the broken override) must apply")
    }
  }

  /// #706 F1: a legacy/hand-edited user file whose FILENAME equals a base
  /// built-in's canonical filename but whose ID diverges (`chat.toml` with a
  /// non-`chat` id) must NOT collide with the base entry: no two entries may
  /// share a url (duplicate SwiftUI id / selection tag), and a base write
  /// (`setModel chat`) must NOT clobber the unrelated user file.
  func test_user_file_squatting_base_filename_with_other_id_does_not_collide_or_clobber() throws {
    try withTempProfilesDir { dir in
      // A valid profile living at chat.toml but identified as `other-id` — it
      // is NOT an override of the Chat built-in (different id).
      let squatter = """
      id = "other-id"
      name = "Unrelated"
      model = "user-model.gguf"
      inferlet = "chat-apc"
      """
      let squatURL = dir.appendingPathComponent("chat.toml")
      try squatter.write(to: squatURL, atomically: true, encoding: .utf8)
      let store = ProfileStore(directory: dir)
      try store.start()
      defer { store.stop() }

      // No duplicate urls in the effective set (would break ForEach(id:\.url)).
      let urls = store.entries.map { $0.url }
      XCTAssertEqual(Set(urls).count, urls.count, "no two effective entries may share a url")

      // The base Chat built-in is still present and relocated off chat.toml.
      let chat = try XCTUnwrap(store.entries.first { $0.profile?.id == "chat" })
      XCTAssertNotEqual(chat.url.lastPathComponent, "chat.toml",
                        "the base built-in must relocate off the squatted filename")
      // The unrelated user profile keeps its own entry at chat.toml.
      let other = try XCTUnwrap(store.entries.first { $0.profile?.id == "other-id" })
      XCTAssertEqual(other.url.lastPathComponent, "chat.toml")

      // A base write resolves the relocated path, leaving the user file intact.
      try store.setModel("base-model.gguf", forProfileID: "chat")
      XCTAssertEqual(try String(contentsOf: squatURL, encoding: .utf8), squatter,
                     "setModel on the base must not overwrite the unrelated user file")
      XCTAssertEqual(store.model(forProfileID: "other-id"), "user-model.gguf",
                     "the unrelated user profile must survive the base write")
    }
  }

  /// #706 F2: two valid user files sharing the same base id — only the
  /// filename-sorted first overrides the base; the loser must be surfaced as
  /// an additive noise entry, never silently dropped.
  func test_duplicate_base_id_loser_is_surfaced_not_dropped() throws {
    try withTempProfilesDir { dir in
      let winner = """
      id = "chat"
      name = "Winner Chat"
      model = "winner.gguf"
      inferlet = "chat-apc"
      """
      let loser = """
      id = "chat"
      name = "Loser Chat"
      model = "loser.gguf"
      inferlet = "chat-apc"
      """
      // "a-chat.toml" sorts before "z-chat.toml", so a-chat wins the override.
      try winner.write(to: dir.appendingPathComponent("a-chat.toml"),
                       atomically: true, encoding: .utf8)
      try loser.write(to: dir.appendingPathComponent("z-chat.toml"),
                      atomically: true, encoding: .utf8)
      let store = ProfileStore(directory: dir)
      try store.start()
      defer { store.stop() }

      // The override (winner) replaces the base Chat slot.
      let chatByFile = store.entries.filter { $0.url.lastPathComponent == "a-chat.toml" }
      XCTAssertEqual(chatByFile.first?.profile?.name, "Winner Chat",
                     "the filename-sorted first valid file must win the override")
      // The loser is still present (surfaced as noise), not dropped.
      let loserEntry = try XCTUnwrap(
        store.entries.first { $0.url.lastPathComponent == "z-chat.toml" },
        "the losing duplicate-base-id file must be surfaced, not silently dropped")
      XCTAssertEqual(loserEntry.profile?.name, "Loser Chat")
    }
  }

  /// #709: a valid user file carrying an EXAMPLE built-in id (e.g.
  /// `tree-of-thought`) must NOT be silently dropped when that example is
  /// excluded from the base set (`seedsExampleProfiles=false`). The override
  /// key was the full static base-id set, so the file was marked a winning
  /// override that no base entry consumed, and the append-the-losers pass
  /// skipped winners — so it vanished. Keying on the ids actually present in
  /// `base` surfaces it as a normal user entry instead.
  func test_example_id_user_file_surfaced_when_example_excluded_from_base() throws {
    try withTempProfilesDir { dir in
      let totFile = """
      id = "tree-of-thought"
      name = "My ToT"
      model = "user.gguf"
      inferlet = "chat-apc"
      """
      try totFile.write(to: dir.appendingPathComponent(ProfileStore.treeOfThoughtFilename),
                        atomically: true, encoding: .utf8)
      // seedsExampleProfiles=false excludes tree-of-thought from the base set.
      let store = ProfileStore(directory: dir, seedsExampleProfiles: false)
      try store.start()
      defer { store.stop() }

      let tot = try XCTUnwrap(
        store.entries.first { $0.profile?.id == "tree-of-thought" },
        "a user file with an example id must be surfaced even when the example base is excluded")
      XCTAssertEqual(tot.profile?.name, "My ToT")
      XCTAssertEqual(tot.url.lastPathComponent, ProfileStore.treeOfThoughtFilename,
                     "the surfaced user file keeps its own path")
    }
  }

  /// #706 F3: `BaseBuiltin.name` is hand-carried alongside the TOML so the
  /// revert notice can label a built-in without re-parsing. Guard the desync:
  /// a future TOML `name` edit that forgets the struct must fail here.
  func test_base_builtin_name_matches_parsed_toml_name() throws {
    for builtin in ProfileStore.baseBuiltins {
      let parsed = try Profile.parse(toml: builtin.toml)
      XCTAssertEqual(builtin.name, parsed.name,
                     "BaseBuiltin.name for \(builtin.id) must match its TOML name key")
    }
  }

  func test_repeat_boost_seed_does_not_overwrite_existing_edited_copy() throws {
    try withTempProfilesDir { dir in
      let edited = """
      id = "repeat-boost"
      name = "My Repeat Boost"
      model = "m"
      inferlet = "chat-apc"

      [speculation]
      enabled = true
      """
      let url = dir.appendingPathComponent(ProfileStore.defaultRepeatBoostFilename)
      try edited.write(to: url, atomically: true, encoding: .utf8)
      let store = ProfileStore(directory: dir)
      try store.start()
      defer { store.stop() }

      XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), edited,
                     "an existing repeat-boost.toml must not be clobbered by the seed")
    }
  }

  func test_repeat_boost_seed_does_not_change_active_profile_on_fresh_install() throws {
    try withTempProfilesDir { dir in
      let active = dir.deletingLastPathComponent()
        .appendingPathComponent("active-profile", isDirectory: false)
      let store = ProfileStore(directory: dir, activeProfileURL: active)
      try store.start()
      defer { store.stop() }

      XCTAssertEqual(store.activeProfileID, ProfileStore.defaultProfileID,
                     "seeding Repeat Boost must not steal the default active profile from chat")
    }
  }

  /// #702: a stale unparseable `repeat-boost.toml` that the migration cannot
  /// back up (read-only dir) must surface `.seedFailed` pointing at
  /// repeat-boost.toml — even though the base built-ins remain present.
  func test_repeat_boost_backup_failure_surfaces_via_snapshot_directoryError() throws {
    try withTempProfilesDir { dir in
      // A present-but-unparseable repeat-boost.toml (missing required fields).
      try "id = \"repeat-boost\"\n".write(
        to: dir.appendingPathComponent(ProfileStore.defaultRepeatBoostFilename),
        atomically: true, encoding: .utf8)
      // Read-only dir: the file still loads (r-x is readable), but the
      // migration's move-to-.bak fails → its error must reach the snapshot.
      try setPermissions(dir, mode: 0o500)
      defer { try? setPermissions(dir, mode: 0o755) }

      let store = ProfileStore(directory: dir)
      try store.start()
      defer { store.stop() }

      XCTAssertNotNil(store.entries.first { $0.profile?.id == "chat" }?.profile,
                      "base built-ins must remain present under a read-only dir")
      guard case .seedFailed(let path, _)? = store.snapshot.directoryError else {
        return XCTFail("Repeat Boost backup failure must surface on snapshot.directoryError; got \(String(describing: store.snapshot.directoryError))")
      }
      XCTAssertTrue(path.hasSuffix(ProfileStore.defaultRepeatBoostFilename),
                    "directoryError must point at repeat-boost.toml, got \(path)")
      // A move FAILURE is NOT a successful revert — no revert notice fires.
      XCTAssertTrue(store.lastBuiltinRevertNotices.isEmpty,
                    "a failed .bak move must ride _builtinSeedError, not the revert-notice channel")
    }
  }

  // MARK: - fast-think -> repeat-boost on-disk migration (#628)

  func test_migration_renames_legacy_fast_think_file_and_preserves_edits() throws {
    try withTempProfilesDir { dir in
      // A pre-rename install: the user edited the built-in (custom name +
      // sampling) but kept the `fast-think` id. The migration must rename
      // the file to `repeat-boost.toml`, rewrite ONLY the id line, and
      // preserve the body edits.
      let edited = """
      id = "fast-think"
      name = "My Fast Think"
      model = "m"
      inferlet = "chat-apc"

      [sampling]
      temperature = 0.0
      max_tokens = 4096

      [speculation]
      enabled = true
      """
      try edited.write(
        to: dir.appendingPathComponent(ProfileStore.legacyFastThinkFilename),
        atomically: true, encoding: .utf8)

      let store = ProfileStore(directory: dir)
      try store.start()
      defer { store.stop() }

      let legacyURL = dir.appendingPathComponent(ProfileStore.legacyFastThinkFilename)
      let targetURL = dir.appendingPathComponent(ProfileStore.defaultRepeatBoostFilename)
      XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path),
                     "legacy fast-think.toml must be removed after migration")
      XCTAssertTrue(FileManager.default.fileExists(atPath: targetURL.path),
                    "migration must produce repeat-boost.toml")

      let migrated = try String(contentsOf: targetURL, encoding: .utf8)
      XCTAssertEqual(migrated, edited.replacingOccurrences(
        of: "id = \"fast-think\"", with: "id = \"repeat-boost\""),
        "only the id line is rewritten; every user edit survives")

      // Exactly one built-in (no duplicate) and it resolves under the new id.
      let entry = try XCTUnwrap(store.entries.first {
        $0.profile?.id == ProfileStore.defaultRepeatBoostProfileID
      })
      XCTAssertEqual(entry.profile?.name, "My Fast Think")
      XCTAssertEqual(entry.profile?.sampling.maxTokens, 4096,
                     "preserved sampling edit")
      XCTAssertEqual(store.entries.filter {
        $0.url.lastPathComponent == ProfileStore.legacyFastThinkFilename
        || $0.url.lastPathComponent == ProfileStore.defaultRepeatBoostFilename
      }.count, 1, "no duplicate built-in after migration")
    }
  }

  func test_migration_repoints_active_marker_from_legacy_slug() throws {
    try withTempProfilesDir { dir in
      let active = dir.deletingLastPathComponent()
        .appendingPathComponent("active-profile", isDirectory: false)
      // Pre-rename: a user had picked the built-in, so the marker names
      // `fast-think`, and the legacy file is on disk.
      try ProfileStore.legacyFastThinkProfileID.write(
        to: active, atomically: true, encoding: .utf8)
      try ProfileStore.defaultRepeatBoostTOML
        .replacingOccurrences(of: "id = \"repeat-boost\"", with: "id = \"fast-think\"")
        .write(to: dir.appendingPathComponent(ProfileStore.legacyFastThinkFilename),
               atomically: true, encoding: .utf8)

      let store = ProfileStore(directory: dir, activeProfileURL: active)
      try store.start()
      defer { store.stop() }

      XCTAssertEqual(store.activeProfileID, ProfileStore.defaultRepeatBoostProfileID,
                     "marker must be repointed fast-think -> repeat-boost")
      XCTAssertEqual(try String(contentsOf: active, encoding: .utf8),
                     ProfileStore.defaultRepeatBoostProfileID,
                     "on-disk marker must also be rewritten")
    }
  }

  func test_migration_is_idempotent_when_already_migrated() throws {
    try withTempProfilesDir { dir in
      // Already-migrated install: only repeat-boost.toml exists (edited),
      // no legacy file. A relaunch must not touch it.
      let edited = """
      id = "repeat-boost"
      name = "Edited"
      model = "m"
      inferlet = "chat-apc"

      [speculation]
      enabled = true
      """
      let targetURL = dir.appendingPathComponent(ProfileStore.defaultRepeatBoostFilename)
      try edited.write(to: targetURL, atomically: true, encoding: .utf8)

      let store = ProfileStore(directory: dir)
      try store.start()
      defer { store.stop() }

      XCTAssertEqual(try String(contentsOf: targetURL, encoding: .utf8), edited,
                     "an already-migrated repeat-boost.toml must be left untouched")
      XCTAssertFalse(FileManager.default.fileExists(
        atPath: dir.appendingPathComponent(ProfileStore.legacyFastThinkFilename).path),
        "no legacy file should be created")
    }
  }

  func test_migration_dedupes_when_both_files_exist() throws {
    try withTempProfilesDir { dir in
      // Crash-between-write-and-delete (or hand-recreated legacy): both
      // files present. The new file is authoritative; the legacy leftover
      // must be removed so the built-in is not duplicated.
      let target = """
      id = "repeat-boost"
      name = "Authoritative"
      model = "m"
      inferlet = "chat-apc"

      [speculation]
      enabled = true
      """
      try target.write(
        to: dir.appendingPathComponent(ProfileStore.defaultRepeatBoostFilename),
        atomically: true, encoding: .utf8)
      try ProfileStore.defaultRepeatBoostTOML
        .replacingOccurrences(of: "id = \"repeat-boost\"", with: "id = \"fast-think\"")
        .write(to: dir.appendingPathComponent(ProfileStore.legacyFastThinkFilename),
               atomically: true, encoding: .utf8)

      let store = ProfileStore(directory: dir)
      try store.start()
      defer { store.stop() }

      XCTAssertFalse(FileManager.default.fileExists(
        atPath: dir.appendingPathComponent(ProfileStore.legacyFastThinkFilename).path),
        "legacy leftover must be deduped away")
      XCTAssertEqual(try String(contentsOf:
        dir.appendingPathComponent(ProfileStore.defaultRepeatBoostFilename), encoding: .utf8),
        target, "the pre-existing repeat-boost.toml must remain authoritative")
    }
  }

  // MARK: - speculation accessor (#426 Repeat Boost)

  func test_speculation_accessor_returns_profile_setting() throws {
    try withTempProfilesDir { dir in
      let toml = """
      id = "fast"
      name = "Fast"
      model = "m"
      inferlet = "chat-apc"

      [speculation]
      enabled = true
      leader_len = 2
      draft_len = 5
      """
      try toml.write(to: dir.appendingPathComponent("fast.toml"), atomically: true, encoding: .utf8)
      let store = ProfileStore(directory: dir)
      try store.start()
      defer { store.stop() }

      XCTAssertEqual(store.speculation(forProfileID: "fast"),
                     Profile.Speculation(enabled: true, leaderLen: 2, draftLen: 5))
    }
  }

  func test_speculation_accessor_nil_for_unknown_profile() throws {
    try withTempProfilesDir { dir in
      let store = ProfileStore(directory: dir)
      try store.start()
      defer { store.stop() }

      XCTAssertNil(store.speculation(forProfileID: "does-not-exist"))
    }
  }

  func test_speculation_accessor_nil_when_section_absent() throws {
    try withTempProfilesDir { dir in
      // The seeded chat.toml carries no [speculation] section.
      let store = ProfileStore(directory: dir)
      try store.start()
      defer { store.stop() }

      XCTAssertNil(store.speculation(forProfileID: "chat"))
    }
  }

  /// Settings → Profiles write-back: system_prompt plus user-facing sampling
  /// defaults (temperature/top_p) are editable, while max_tokens stays an
  /// engine-owned ceiling and is preserved from the existing profile TOML.
  func test_setEditableDefaults_persists_prompt_temperature_topP_and_preserves_maxTokens() throws {
    try withTempProfilesDir { dir in
      let body = """
      id = "chat"
      name = "Chat"
      icon = "bubble.left.and.bubble.right"
      model = "model.gguf"
      inferlet = "chat-apc"
      system_prompt = "Old prompt"

      [sampling]
      temperature = 0.4
      top_p = 0.75
      max_tokens = 1536

      [inferlet_args]
      mode = "kept"
      """
      try body.write(to: dir.appendingPathComponent("chat.toml"),
                     atomically: true, encoding: .utf8)
      let store = ProfileStore(directory: dir)
      try store.start()
      defer { store.stop() }

      try store.setEditableDefaults(
        systemPrompt: "New prompt",
        temperature: 0.2,
        topP: 0.95,
        forProfileID: "chat")

      let profile = try XCTUnwrap(store.entries.first { $0.profile?.id == "chat" }?.profile)
      XCTAssertEqual(profile.systemPrompt, "New prompt")
      XCTAssertEqual(profile.sampling.temperature, 0.2, accuracy: 0.0001)
      XCTAssertEqual(profile.sampling.topP, 0.95, accuracy: 0.0001)
      XCTAssertEqual(profile.sampling.maxTokens, 1536,
                     "Settings must not expose or overwrite max_tokens as a normal editable profile knob")
      XCTAssertEqual(profile.inferletArgs["mode"]?.string, "kept")

      let (reloaded, _) = ProfileStore.scan(directory: dir)
      let fromDisk = try XCTUnwrap(reloaded.first { $0.profile?.id == "chat" }?.profile)
      XCTAssertEqual(fromDisk.systemPrompt, "New prompt")
      XCTAssertEqual(fromDisk.sampling.temperature, 0.2, accuracy: 0.0001)
      XCTAssertEqual(fromDisk.sampling.topP, 0.95, accuracy: 0.0001)
      XCTAssertEqual(fromDisk.sampling.maxTokens, 1536)
    }
  }

  func test_profileDefaultAccessors_return_prompt_and_sampling_for_chat_initialization() throws {
    try withTempProfilesDir { dir in
      let body = """
      id = "creative"
      name = "Creative"
      model = "model.gguf"
      inferlet = "chat-apc"
      system_prompt = "Think creatively."

      [sampling]
      temperature = 1.1
      top_p = 0.65
      max_tokens = 777
      """
      try body.write(to: dir.appendingPathComponent("creative.toml"),
                     atomically: true, encoding: .utf8)
      let store = ProfileStore(directory: dir)
      try store.start()
      defer { store.stop() }

      XCTAssertEqual(store.systemPrompt(forProfileID: "creative"), "Think creatively.")
      XCTAssertEqual(store.sampling(forProfileID: "creative"),
                     Sampling(temperature: 1.1, topP: 0.65, maxTokens: 777))
      XCTAssertNil(store.systemPrompt(forProfileID: "missing"))
      XCTAssertNil(store.sampling(forProfileID: "missing"))
    }
  }

  // MARK: - helpers

  private func withTempProfilesDir(_ body: (URL) throws -> Void) throws {
    let temp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("pie-profile-store-test-\(UUID().uuidString)",
                              isDirectory: true)
    let profilesDir = temp.appendingPathComponent("profiles", isDirectory: true)
    try FileManager.default.createDirectory(at: profilesDir, withIntermediateDirectories: true)
    var bodyError: Error?
    do { try body(profilesDir) } catch { bodyError = error }
    // Permission-failure tests may have chmod'd profilesDir to 0o500
    // or removed it entirely; both branches are tolerated here so
    // cleanup never masks the real bodyError.
    try? setPermissions(profilesDir, mode: 0o755)
    try? FileManager.default.removeItem(at: temp)
    if let bodyError { throw bodyError }
  }

  private func setPermissions(_ url: URL, mode: Int) throws {
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: mode)],
      ofItemAtPath: url.path
    )
  }

  private func writeProfile(
    into dir: URL,
    name: String,
    id: String,
    displayName: String,
    model: String = "m"
  ) throws {
    let body = """
    id = "\(id)"
    name = "\(displayName)"
    model = "\(model)"
    inferlet = "i"
    """
    try body.write(to: dir.appendingPathComponent(name),
                   atomically: true,
                   encoding: .utf8)
  }
}

private enum ProfileStoreDefaultsTransactionProbeError: Error {
  case trashFailed
  case profileWriteFailed
}
