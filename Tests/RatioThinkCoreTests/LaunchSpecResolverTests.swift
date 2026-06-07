import XCTest
import Foundation
@testable import RatioThinkCore

/// Unit tests for `LaunchSpecResolver` (Phase 2.4 ). Each test
/// owns its temp profiles dir + injected path closures so the
/// resolver never reaches `PieDirs` / `Bundle.main`.
final class LaunchSpecResolverTests: XCTestCase {

  private var tempDir: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    let uuid = UUID().uuidString.prefix(8).lowercased()
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("pie-launchspec-\(uuid)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    tempDir = dir
  }

  override func tearDownWithError() throws {
    if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    tempDir = nil
    try super.tearDownWithError()
  }

  func test_resolve_known_profile_builds_launch_spec() throws {
    let store = try makeStoreWithChatProfile()
    defer { store.stop() }

    let binary = tempDir.appendingPathComponent("pie-fake", isDirectory: false)
    try touchExecutable(at: binary)
    let modelsRoot = tempDir.appendingPathComponent("models", isDirectory: true)
    let inferlets  = tempDir.appendingPathComponent("inferlets", isDirectory: true)

    let resolver = LaunchSpecResolver(
      profileStore: store,
      pieBinary: { binary },
      modelsRoot: { modelsRoot },
      inferletsDir: { inferlets }
    )

    let result = resolver.resolve(profileID: "chat")
    guard case .success(let spec) = result else {
      return XCTFail("expected .success, got \(result)")
    }
    XCTAssertEqual(spec.binaryURL, binary)
    XCTAssertEqual(spec.profileID, "chat")
    XCTAssertEqual(spec.inferletDir, inferlets)
    XCTAssertEqual(spec.inferletName, "chat-apc",
                   "profile.inferlet must propagate verbatim to LaunchSpec.inferletName — silent drop was the bug (review v2 F7)")
    XCTAssertEqual(spec.modelPath,
                   modelsRoot.appendingPathComponent("llama-3.1-8b-instruct").path,
                   "modelPath must join `modelsRoot` with `profile.model` for the downloader's on-disk layout")
  }

  func test_resolve_noDefaultProfile_returns_modelMissing_without_fallback() throws {
    let profiles = tempDir.appendingPathComponent("profiles-no-default", isDirectory: true)
    try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
    let toml = """
    id = "chat"
    name = "Chat"
    inferlet = "chat-apc"
    """
    try toml.write(to: profiles.appendingPathComponent("chat.toml"),
                   atomically: true, encoding: .utf8)
    let active = tempDir.appendingPathComponent("active-profile-no-default", isDirectory: false)
    let store = ProfileStore(directory: profiles, activeProfileURL: active)
    try store.start()
    defer { store.stop() }

    let binary = tempDir.appendingPathComponent("pie-fake", isDirectory: false)
    try touchExecutable(at: binary)
    let resolver = LaunchSpecResolver(
      profileStore: store,
      pieBinary: { binary },
      modelsRoot: { self.tempDir.appendingPathComponent("models") },
      inferletsDir: { self.tempDir.appendingPathComponent("inferlets") }
    )

    guard case .failure(let error) = resolver.resolve(profileID: "chat") else {
      return XCTFail("no-default profile must not resolve by choosing a hidden fallback")
    }
    XCTAssertEqual(error.code, .modelMissing)
    XCTAssertTrue(error.message.contains("has no default model"),
                  "error should route the UI to choose/download actions; got: \(error.message)")
  }

  /// Review v2 F7 + v3 F1 regression guard. The resolver mapped
  /// `profile.model` but silently dropped `profile.inferlet` — making
  /// every profile indistinguishable to the engine as soon as a second
  /// inferlet shipped. Argv must carry `--inferlet <name>` so the engine
  /// activates the profile-selected inferlet. The legacy adapter
  /// preserves the profile schema's bare inferlet names; only the
  /// PieControlLauncher path qualifies them against the installed
  /// manifest before calling `launch_daemon`.
  func test_resolve_propagates_inferlet_name_into_argv() throws {
    let profiles = tempDir.appendingPathComponent("profiles", isDirectory: true)
    try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
    let toml = """
    id = "alt"
    name = "Alt"
    model = "llama-3.1-8b-instruct"
    inferlet = "other-inferlet"
    """
    try toml.write(to: profiles.appendingPathComponent("alt.toml"),
                   atomically: true, encoding: .utf8)
    let activeURL = tempDir.appendingPathComponent("active-profile", isDirectory: false)
    let store = ProfileStore(directory: profiles, activeProfileURL: activeURL)
    try store.start()
    defer { store.stop() }

    let binary = tempDir.appendingPathComponent("pie-fake", isDirectory: false)
    try touchExecutable(at: binary)

    let resolver = LaunchSpecResolver(
      profileStore: store,
      pieBinary: { binary },
      modelsRoot: { self.tempDir.appendingPathComponent("models") },
      inferletsDir: { self.tempDir.appendingPathComponent("inferlets") }
    )
    guard case .success(let spec) = resolver.resolve(profileID: "alt") else {
      return XCTFail("expected .success for profile carrying a non-default inferlet")
    }
    XCTAssertEqual(spec.inferletName, "other-inferlet")
    let argv = spec.arguments()
    guard let idx = argv.firstIndex(of: "--inferlet") else {
      return XCTFail("argv missing --inferlet flag: \(argv)")
    }
    XCTAssertLessThan(idx + 1, argv.count,
                      "--inferlet flag has no value: \(argv)")
    XCTAssertEqual(argv[idx + 1], "other-inferlet",
                   "argv must surface profile.inferlet verbatim")
  }

  func test_resolve_unknown_profile_returns_profile_missing() throws {
    let store = try makeStoreWithChatProfile()
    defer { store.stop() }

    let resolver = LaunchSpecResolver(
      profileStore: store,
      pieBinary: { self.tempDir.appendingPathComponent("pie-fake") },
      modelsRoot: { self.tempDir.appendingPathComponent("models") },
      inferletsDir: { self.tempDir.appendingPathComponent("inferlets") }
    )

    let result = resolver.resolve(profileID: "ghost")
    guard case .failure(let err) = result else {
      return XCTFail("expected .failure, got \(result)")
    }
    XCTAssertEqual(err.code, .profileMissing,
                   "unknown profileID must map to .profileMissing (matches Phase 2.2 wire contract)")
  }

  func test_resolve_propagates_binary_lookup_failure_as_spawn_failed() throws {
    let store = try makeStoreWithChatProfile()
    defer { store.stop() }

    struct StubError: Error, CustomStringConvertible {
      var description: String { "pie binary deliberately absent" }
    }
    let resolver = LaunchSpecResolver(
      profileStore: store,
      pieBinary: { throw StubError() },
      modelsRoot: { self.tempDir.appendingPathComponent("models") },
      inferletsDir: { self.tempDir.appendingPathComponent("inferlets") }
    )
    let result = resolver.resolve(profileID: "chat")
    guard case .failure(let err) = result else {
      return XCTFail("expected .failure, got \(result)")
    }
    XCTAssertEqual(err.code, .spawnFailed,
                   "missing-binary must NOT collapse to .profileMissing (the profile is fine; the install is broken)")
  }

  /// Review v150 F8 regression guard. The downloader writes models
  /// as `<modelsRoot>/<repo>/<file>` so profile.model legitimately
  /// carries a multi-segment slug (e.g. HuggingFace path). A naive
  /// single `appendingPathComponent` call percent-escapes embedded
  /// `/` into `%2F` on recent Foundation, producing a path the
  /// engine cannot open. The resolver MUST chain per-segment so the
  /// final modelPath is a real filesystem path with literal slashes.
  func test_resolve_multisegment_model_slug_preserves_slashes() throws {
    let profiles = tempDir.appendingPathComponent("profiles", isDirectory: true)
    try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
    let slug = "TheBloke/Llama-2-7B-Chat-GGUF/llama-2-7b.gguf"
    let toml = """
    id = "llama2"
    name = "Llama 2"
    model = "\(slug)"
    inferlet = "chat-apc"
    """
    try toml.write(to: profiles.appendingPathComponent("llama2.toml"),
                   atomically: true, encoding: .utf8)
    let activeURL = tempDir.appendingPathComponent("active-profile", isDirectory: false)
    let store = ProfileStore(directory: profiles, activeProfileURL: activeURL)
    try store.start()
    defer { store.stop() }

    let binary = tempDir.appendingPathComponent("pie-fake", isDirectory: false)
    try touchExecutable(at: binary)
    let modelsRoot = tempDir.appendingPathComponent("models", isDirectory: true)

    let resolver = LaunchSpecResolver(
      profileStore: store,
      pieBinary: { binary },
      modelsRoot: { modelsRoot },
      inferletsDir: { self.tempDir.appendingPathComponent("inferlets") }
    )
    guard case .success(let spec) = resolver.resolve(profileID: "llama2") else {
      return XCTFail("expected .success for multi-segment slug")
    }
    XCTAssertEqual(spec.modelPath,
                   modelsRoot.path + "/" + slug,
                   "embedded '/' in profile.model MUST survive as literal path separators, not %2F")
    XCTAssertFalse(spec.modelPath.contains("%2F"),
                   "modelPath leaked %2F escape — downloader layout becomes unreachable: \(spec.modelPath)")
    XCTAssertFalse(spec.modelPath.contains("%2f"),
                   "modelPath leaked lowercase %2f escape: \(spec.modelPath)")
  }

  func test_joinModelPath_unit_handles_single_segment_and_multi_segment() {
    let root = URL(fileURLWithPath: "/tmp/models", isDirectory: true)
    XCTAssertEqual(
      LaunchSpecResolver.joinModelPath(modelsRoot: root,
                                       slug: "llama-3.1-8b.gguf"),
      "/tmp/models/llama-3.1-8b.gguf"
    )
    XCTAssertEqual(
      LaunchSpecResolver.joinModelPath(modelsRoot: root,
                                       slug: "repo/sub/file.gguf"),
      "/tmp/models/repo/sub/file.gguf"
    )
    // Defensive: leading/trailing slashes do not duplicate separators.
    XCTAssertEqual(
      LaunchSpecResolver.joinModelPath(modelsRoot: root,
                                       slug: "/leading/file.gguf"),
      "/tmp/models/leading/file.gguf"
    )
  }

  func test_asClosure_matches_HelperExportedAPI_resolver_signature() throws {
    let store = try makeStoreWithChatProfile()
    defer { store.stop() }
    let binary = tempDir.appendingPathComponent("pie-fake", isDirectory: false)
    try touchExecutable(at: binary)
    // : asClosure now returns PieControlLauncher.LaunchSpec
    // and requires wasm/manifest + pieHome injection. Stub them with
    // tempDir-anchored paths so the test does not depend on a
    // bundled RatioThink.app sibling.
    let resources = try writeInferletResources(name: "chat-apc", version: "0.1.0")
    let modelsRoot = tempDir.appendingPathComponent("models-closure", isDirectory: true)
    try stageModel(named: "llama-3.1-8b-instruct", in: modelsRoot)
    let resolver = LaunchSpecResolver(
      profileStore: store,
      pieBinary: { binary },
      modelsRoot: { modelsRoot },
      inferletsDir: { self.tempDir.appendingPathComponent("inferlets") },
      pieControlResources: { resources },
      pieHome: { self.tempDir },
      subprocessEnvironment: { [:] }
    )

    let closure: HelperExportedAPI.LaunchSpecResolver = resolver.asClosure
    if case .success(let spec) = closure("chat") {
      XCTAssertEqual(spec.profileID, "chat")
    } else {
      XCTFail("closure adapter must round-trip the same result as resolve()")
    }
  }

  /// Review v1 F1: first-run seeded profiles still use the public
  /// profile schema's bare inferlet name (`chat-apc`). The launcher
  /// resolver must qualify that selector from the installed manifest
  /// instead of rejecting a fresh install before it can start.
  func test_resolveLauncherSpec_qualifies_seeded_default_bare_inferlet_from_manifest() throws {
    let profiles = tempDir.appendingPathComponent("profiles", isDirectory: true)
    let activeURL = tempDir.appendingPathComponent("active-profile", isDirectory: false)
    let store = ProfileStore(directory: profiles, activeProfileURL: activeURL)
    try store.start()
    defer { store.stop() }

    XCTAssertEqual(store.activeProfileID, ProfileStore.defaultProfileID)
    let seeded = try XCTUnwrap(store.entries.first { $0.profile?.id == ProfileStore.defaultProfileID }?.profile)
    XCTAssertEqual(seeded.inferlet, "chat-apc",
                   "test must exercise ProfileStore.defaultChatTOML's bare inferlet fixture")

    let binary = tempDir.appendingPathComponent("pie-fake", isDirectory: false)
    try touchExecutable(at: binary)
    let resources = try writeInferletResources(name: "chat-apc", version: "0.1.0")
    let modelsRoot = tempDir.appendingPathComponent("models-seeded", isDirectory: true)
    try stageModel(named: ProfileStore.defaultChatModelID, in: modelsRoot)
    let resolver = LaunchSpecResolver(
      profileStore: store,
      pieBinary: { binary },
      modelsRoot: { modelsRoot },
      inferletsDir: { self.tempDir.appendingPathComponent("inferlets") },
      pieControlResources: { resources },
      pieHome: { self.tempDir },
      subprocessEnvironment: { [:] }
    )

    let closure: HelperExportedAPI.LaunchSpecResolver = resolver.asClosure
    guard case .success(let spec) = closure(ProfileStore.defaultProfileID) else {
      return XCTFail("seeded default profile must resolve successfully through asClosure")
    }
    XCTAssertEqual(spec.inferletNameAtVersion, "chat-apc@0.1.0")
  }

  func test_resolveLauncherSpec_prefers_app_staged_default_model_file() throws {
    let store = try makeSeededDefaultStore()
    defer { store.stop() }

    let binary = tempDir.appendingPathComponent("pie-fake", isDirectory: false)
    try touchExecutable(at: binary)
    let modelsRoot = tempDir.appendingPathComponent("models", isDirectory: true)
    //  review v2 F1: the seeded default is a `<repo>/<file>` slug,
    // so stage it at the joined (nested) path the resolver resolves to,
    // not via appendingPathComponent (which would escape the slug's "/").
    let stagedDefault = URL(fileURLWithPath: LaunchSpecResolver.joinModelPath(
      modelsRoot: modelsRoot, slug: ProfileStore.defaultChatModelID))
    try FileManager.default.createDirectory(at: stagedDefault.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try Data("gguf".utf8).write(to: stagedDefault)
    let resources = try writeInferletResources(name: "chat-apc", version: "0.1.0")

    let resolver = LaunchSpecResolver(
      profileStore: store,
      pieBinary: { binary },
      modelsRoot: { modelsRoot },
      inferletsDir: { self.tempDir.appendingPathComponent("inferlets") },
      pieControlResources: { resources },
      pieHome: { self.tempDir },
      subprocessEnvironment: { [:] },
      hfHome: { self.tempDir.appendingPathComponent("hf-home", isDirectory: true) }
    )

    guard case .success(let spec) = resolver.resolveLauncherSpec(profileID: ProfileStore.defaultProfileID) else {
      return XCTFail("seeded default must resolve when the GGUF is staged in the app models directory")
    }
    let body = PieControlLauncher.renderConfigBody(modelConfig: spec.modelConfig)
    XCTAssertTrue(body.contains("hf_repo = \"\(stagedDefault.path)\""),
                  "app-staged default must win and be passed to pie as a local hf_repo path; got:\n\(body)")
    XCTAssertFalse(body.contains("hf_path"),
                   "pie server config accepts model.hf_repo; production config must not emit stale hf_path")
  }

  func test_resolveLauncherSpec_falls_back_to_hf_cache_for_seeded_default() throws {
    let store = try makeSeededDefaultStore()
    defer { store.stop() }

    let binary = tempDir.appendingPathComponent("pie-fake", isDirectory: false)
    try touchExecutable(at: binary)
    let resources = try writeInferletResources(name: "chat-apc", version: "0.1.0")
    let modelsRoot = tempDir.appendingPathComponent("models", isDirectory: true)
    let hfHome = tempDir.appendingPathComponent("hf-home", isDirectory: true)
    let snapshot = try writeHFCacheSnapshot(
      hfHome: hfHome,
      repo: ProfileStore.defaultChatHFRepoID,
      files: [
        "config.json": "{}",
        "tokenizer.json": "{}",
        "model.safetensors": "weights",
      ]
    )

    let resolver = LaunchSpecResolver(
      profileStore: store,
      pieBinary: { binary },
      modelsRoot: { modelsRoot },
      inferletsDir: { self.tempDir.appendingPathComponent("inferlets") },
      pieControlResources: { resources },
      pieHome: { self.tempDir },
      subprocessEnvironment: { [:] },
      hfHome: { hfHome }
    )

    guard case .success(let spec) = resolver.resolveLauncherSpec(profileID: ProfileStore.defaultProfileID) else {
      return XCTFail("seeded default must resolve from the HF/pie cache when app-staged GGUF is absent")
    }
    let body = PieControlLauncher.renderConfigBody(modelConfig: spec.modelConfig)
    XCTAssertTrue(body.contains("hf_repo = \"\(snapshot.path)\""),
                  "HF cache fallback must pass the resolved local snapshot dir to pie; got:\n\(body)")
  }

  func test_resolveLauncherSpec_hf_gguf_symlink_fallback_preserves_snapshot_path() throws {
    let store = try makeStoreWithModel("Qwen/Qwen3-0.6B-GGUF/model.gguf")
    defer { store.stop() }

    let binary = tempDir.appendingPathComponent("pie-fake", isDirectory: false)
    try touchExecutable(at: binary)
    let resources = try writeInferletResources(name: "chat-apc", version: "0.1.0")
    let modelsRoot = tempDir.appendingPathComponent("models", isDirectory: true)
    let hfHome = tempDir.appendingPathComponent("hf-home", isDirectory: true)
    let snapshot = try writeHFCacheSnapshot(
      hfHome: hfHome,
      repo: "Qwen/Qwen3-0.6B-GGUF",
      files: [:]
    )
    let repoDir = snapshot.deletingLastPathComponent().deletingLastPathComponent()
    let blobs = repoDir.appendingPathComponent("blobs", isDirectory: true)
    try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
    let blob = blobs.appendingPathComponent("abcdef", isDirectory: false)
    try Data("gguf".utf8).write(to: blob)
    let snapshotEntry = snapshot.appendingPathComponent("model.gguf", isDirectory: false)
    try FileManager.default.createSymbolicLink(
      atPath: snapshotEntry.path,
      withDestinationPath: "../../blobs/abcdef"
    )

    let resolver = LaunchSpecResolver(
      profileStore: store,
      pieBinary: { binary },
      modelsRoot: { modelsRoot },
      inferletsDir: { self.tempDir.appendingPathComponent("inferlets") },
      pieControlResources: { resources },
      pieHome: { self.tempDir },
      subprocessEnvironment: { [:] },
      hfHome: { hfHome }
    )

    guard case .success(let spec) = resolver.resolveLauncherSpec(profileID: "chat") else {
      return XCTFail("GGUF cache fallback must resolve via the snapshot entry symlink")
    }
    let body = PieControlLauncher.renderConfigBody(modelConfig: spec.modelConfig)
    XCTAssertTrue(body.contains("hf_repo = \"\(snapshotEntry.path)\""),
                  "pie requires the .gguf snapshot path, not the extensionless blob target; got:\n\(body)")
    XCTAssertFalse(body.contains("/blobs/abcdef"),
                   "HF fallback must not resolve symlinks into extensionless blobs; got:\n\(body)")
  }

  func test_resolveLauncherSpec_app_staged_symlink_to_regular_gguf_resolves() throws {
    // ITEM 1 / pre-#413: a staged model that is a SYMLINK to a regular GGUF
    // (e.g. `stage-test-model.sh` links the HF cache, or a user `ln -s`'d a
    // weight) must RESOLVE to the symlink path — not hard-fail with
    // `modelMissing`, which ALSO skipped the HF-cache fallback even when the
    // cache held the model (the operator's real blocker). pie follows the
    // symlink and the `.gguf` suffix is preserved.
    let slug = "Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf"
    let store = try makeStoreWithModel(slug)
    defer { store.stop() }

    let binary = tempDir.appendingPathComponent("pie-fake", isDirectory: false)
    try touchExecutable(at: binary)
    let resources = try writeInferletResources(name: "chat-apc", version: "0.1.0")
    let modelsRoot = tempDir.appendingPathComponent("models", isDirectory: true)

    // A real regular GGUF outside modelsRoot, linked into the staged path.
    let target = tempDir.appendingPathComponent("real-weights.gguf", isDirectory: false)
    try Data("gguf".utf8).write(to: target)
    let staged = slug.split(separator: "/").map(String.init)
      .reduce(modelsRoot) { $0.appendingPathComponent($1, isDirectory: false) }
    try FileManager.default.createDirectory(
      at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: staged.path, withDestinationPath: target.path)

    let resolver = LaunchSpecResolver(
      profileStore: store,
      pieBinary: { binary },
      modelsRoot: { modelsRoot },
      inferletsDir: { self.tempDir.appendingPathComponent("inferlets") },
      pieControlResources: { resources },
      pieHome: { self.tempDir },
      subprocessEnvironment: { [:] },
      // Empty HF home: proves the staged symlink resolves on its own, not
      // via the cache fallback.
      hfHome: { self.tempDir.appendingPathComponent("hf-home-empty") }
    )

    guard case .success(let spec) = resolver.resolveLauncherSpec(profileID: "chat") else {
      return XCTFail("a staged symlink-to-regular GGUF must resolve, not fail modelMissing")
    }
    let body = PieControlLauncher.renderConfigBody(modelConfig: spec.modelConfig)
    XCTAssertTrue(body.contains("hf_repo = \"\(staged.path)\""),
                  "must pass the staged SYMLINK path (pie follows it; .gguf suffix preserved), not the resolved target; got:\n\(body)")
    XCTAssertFalse(body.contains(target.path),
                   "must not pass the resolved target path; got:\n\(body)")
  }

  func test_resolveLauncherSpec_dangling_app_staged_symlink_falls_through_to_hf_cache() throws {
    // A DANGLING staged symlink (target gone) is treated as "not staged" and
    // falls through to the HF-cache GGUF (3-seg slug → first-class file hit),
    // rather than hard-failing.
    let slug = "Qwen/Qwen3-0.6B-GGUF/model.gguf"
    let store = try makeStoreWithModel(slug)
    defer { store.stop() }

    let binary = tempDir.appendingPathComponent("pie-fake", isDirectory: false)
    try touchExecutable(at: binary)
    let resources = try writeInferletResources(name: "chat-apc", version: "0.1.0")
    let modelsRoot = tempDir.appendingPathComponent("models", isDirectory: true)
    let hfHome = tempDir.appendingPathComponent("hf-home", isDirectory: true)

    // HF cache holds the GGUF (snapshot entry → blob).
    let snapshot = try writeHFCacheSnapshot(hfHome: hfHome, repo: "Qwen/Qwen3-0.6B-GGUF", files: [:])
    let repoDir = snapshot.deletingLastPathComponent().deletingLastPathComponent()
    let blobs = repoDir.appendingPathComponent("blobs", isDirectory: true)
    try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
    let blob = blobs.appendingPathComponent("abcdef", isDirectory: false)
    try Data("gguf".utf8).write(to: blob)
    let snapshotEntry = snapshot.appendingPathComponent("model.gguf", isDirectory: false)
    try FileManager.default.createSymbolicLink(atPath: snapshotEntry.path, withDestinationPath: "../../blobs/abcdef")

    // Staged path is a DANGLING symlink (target never created).
    let staged = slug.split(separator: "/").map(String.init)
      .reduce(modelsRoot) { $0.appendingPathComponent($1, isDirectory: false) }
    try FileManager.default.createDirectory(
      at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: staged.path, withDestinationPath: "/nonexistent/gone.gguf")

    let resolver = LaunchSpecResolver(
      profileStore: store,
      pieBinary: { binary },
      modelsRoot: { modelsRoot },
      inferletsDir: { self.tempDir.appendingPathComponent("inferlets") },
      pieControlResources: { resources },
      pieHome: { self.tempDir },
      subprocessEnvironment: { [:] },
      hfHome: { hfHome }
    )

    guard case .success(let spec) = resolver.resolveLauncherSpec(profileID: "chat") else {
      return XCTFail("a dangling staged symlink must fall through to the HF-cache GGUF, not fail")
    }
    let body = PieControlLauncher.renderConfigBody(modelConfig: spec.modelConfig)
    XCTAssertTrue(body.contains("hf_repo = \"\(snapshotEntry.path)\""),
                  "dangling staged symlink must fall through to the HF-cache .gguf snapshot path; got:\n\(body)")
  }

  func test_resolveLauncherSpec_rejects_incomplete_default_hf_cache() throws {
    let store = try makeSeededDefaultStore()
    defer { store.stop() }

    let binary = tempDir.appendingPathComponent("pie-fake", isDirectory: false)
    try touchExecutable(at: binary)
    let resources = try writeInferletResources(name: "chat-apc", version: "0.1.0")
    let modelsRoot = tempDir.appendingPathComponent("models", isDirectory: true)
    let hfHome = tempDir.appendingPathComponent("hf-home", isDirectory: true)
    try writeHFCacheSnapshot(
      hfHome: hfHome,
      repo: ProfileStore.defaultChatHFRepoID,
      files: ["config.json": "{}"]
    )

    let resolver = LaunchSpecResolver(
      profileStore: store,
      pieBinary: { binary },
      modelsRoot: { modelsRoot },
      inferletsDir: { self.tempDir.appendingPathComponent("inferlets") },
      pieControlResources: { resources },
      pieHome: { self.tempDir },
      subprocessEnvironment: { [:] },
      hfHome: { hfHome }
    )

    switch resolver.resolveLauncherSpec(profileID: ProfileStore.defaultProfileID) {
    case .success(let spec):
      XCTFail("incomplete HF snapshot must not be treated as launchable; got \(spec)")
    case .failure(let err):
      XCTAssertEqual(err.code, .modelMissing)
      XCTAssertTrue(err.message.contains("HF cache invalid"), "got: \(err.message)")
      XCTAssertTrue(err.message.contains("incomplete HF snapshot"), "got: \(err.message)")
      XCTAssertTrue(err.message.contains("tokenizer.json"), "got: \(err.message)")
      XCTAssertTrue(err.message.contains("pie model download \(ProfileStore.defaultChatHFRepoID)"),
                    "got: \(err.message)")
    }
  }

  func test_resolveLauncherSpec_rejects_default_hf_cache_with_dangling_config_symlink() throws {
    try assertDefaultHFCacheWithDanglingArtifactFails("config.json")
  }

  func test_resolveLauncherSpec_rejects_default_hf_cache_with_dangling_tokenizer_symlink() throws {
    try assertDefaultHFCacheWithDanglingArtifactFails("tokenizer.json")
  }

  func test_resolveLauncherSpec_rejects_default_hf_cache_with_dangling_weight_symlink() throws {
    try assertDefaultHFCacheWithDanglingArtifactFails("model.safetensors")
  }

  func test_resolveLauncherSpec_reports_corrupt_hf_ref_revision() throws {
    let store = try makeSeededDefaultStore()
    defer { store.stop() }

    let binary = tempDir.appendingPathComponent("pie-fake", isDirectory: false)
    try touchExecutable(at: binary)
    let resources = try writeInferletResources(name: "chat-apc", version: "0.1.0")
    let modelsRoot = tempDir.appendingPathComponent("models", isDirectory: true)
    let hfHome = tempDir.appendingPathComponent("hf-home", isDirectory: true)
    let ref = try writeHFCacheRef(
      hfHome: hfHome,
      repo: ProfileStore.defaultChatHFRepoID,
      contents: "bad/revision"
    )

    let resolver = LaunchSpecResolver(
      profileStore: store,
      pieBinary: { binary },
      modelsRoot: { modelsRoot },
      inferletsDir: { self.tempDir.appendingPathComponent("inferlets") },
      pieControlResources: { resources },
      pieHome: { self.tempDir },
      subprocessEnvironment: { [:] },
      hfHome: { hfHome }
    )

    switch resolver.resolveLauncherSpec(profileID: ProfileStore.defaultProfileID) {
    case .success(let spec):
      XCTFail("corrupt refs/main must not collapse to a generic cache miss; got \(spec)")
    case .failure(let err):
      XCTAssertEqual(err.code, .modelMissing)
      XCTAssertTrue(err.message.contains(ref.path), "got: \(err.message)")
      XCTAssertTrue(err.message.contains("invalid revision"), "got: \(err.message)")
    }
  }

  func test_resolveLauncherSpec_reports_nonfile_hf_ref() throws {
    let store = try makeSeededDefaultStore()
    defer { store.stop() }

    let binary = tempDir.appendingPathComponent("pie-fake", isDirectory: false)
    try touchExecutable(at: binary)
    let resources = try writeInferletResources(name: "chat-apc", version: "0.1.0")
    let modelsRoot = tempDir.appendingPathComponent("models", isDirectory: true)
    let hfHome = tempDir.appendingPathComponent("hf-home", isDirectory: true)
    let ref = try writeHFCacheRefDirectory(
      hfHome: hfHome,
      repo: ProfileStore.defaultChatHFRepoID
    )

    let resolver = LaunchSpecResolver(
      profileStore: store,
      pieBinary: { binary },
      modelsRoot: { modelsRoot },
      inferletsDir: { self.tempDir.appendingPathComponent("inferlets") },
      pieControlResources: { resources },
      pieHome: { self.tempDir },
      subprocessEnvironment: { [:] },
      hfHome: { hfHome }
    )

    switch resolver.resolveLauncherSpec(profileID: ProfileStore.defaultProfileID) {
    case .success(let spec):
      XCTFail("directory refs/main must not collapse to a generic cache miss; got \(spec)")
    case .failure(let err):
      XCTAssertEqual(err.code, .modelMissing)
      XCTAssertTrue(err.message.contains(ref.path), "got: \(err.message)")
      XCTAssertTrue(err.message.contains("refs/main is a directory"), "got: \(err.message)")
    }
  }

  func test_resolveLauncherSpec_rejects_app_staged_directory_at_default_model_path() throws {
    let store = try makeSeededDefaultStore()
    defer { store.stop() }

    let binary = tempDir.appendingPathComponent("pie-fake", isDirectory: false)
    try touchExecutable(at: binary)
    let resources = try writeInferletResources(name: "chat-apc", version: "0.1.0")
    let modelsRoot = tempDir.appendingPathComponent("models", isDirectory: true)
    // Stage the resolved (joined) path as a directory so the resolver
    // hits the "is a directory, expected a file" invalid case.
    let invalidDefault = URL(fileURLWithPath: LaunchSpecResolver.joinModelPath(
      modelsRoot: modelsRoot, slug: ProfileStore.defaultChatModelID), isDirectory: true)
    try FileManager.default.createDirectory(at: invalidDefault, withIntermediateDirectories: true)

    let resolver = LaunchSpecResolver(
      profileStore: store,
      pieBinary: { binary },
      modelsRoot: { modelsRoot },
      inferletsDir: { self.tempDir.appendingPathComponent("inferlets") },
      pieControlResources: { resources },
      pieHome: { self.tempDir },
      subprocessEnvironment: { [:] },
      hfHome: { self.tempDir.appendingPathComponent("hf-home", isDirectory: true) }
    )

    switch resolver.resolveLauncherSpec(profileID: ProfileStore.defaultProfileID) {
    case .success(let spec):
      XCTFail("directory at app-staged default path must not resolve as a model file; got \(spec)")
    case .failure(let err):
      XCTAssertEqual(err.code, .modelMissing)
      XCTAssertTrue(err.message.contains(invalidDefault.path), "got: \(err.message)")
      XCTAssertTrue(err.message.contains("app-staged model invalid"), "got: \(err.message)")
      XCTAssertTrue(err.message.contains("is a directory"), "got: \(err.message)")
    }
  }

  func test_resolveLauncherSpec_reports_actionable_model_missing_when_default_unstaged() throws {
    let store = try makeSeededDefaultStore()
    defer { store.stop() }

    let binary = tempDir.appendingPathComponent("pie-fake", isDirectory: false)
    try touchExecutable(at: binary)
    let resources = try writeInferletResources(name: "chat-apc", version: "0.1.0")
    let modelsRoot = tempDir.appendingPathComponent("models", isDirectory: true)
    let hfHome = tempDir.appendingPathComponent("hf-home", isDirectory: true)
    let expectedLocalPath = LaunchSpecResolver.joinModelPath(
      modelsRoot: modelsRoot, slug: ProfileStore.defaultChatModelID)

    let resolver = LaunchSpecResolver(
      profileStore: store,
      pieBinary: { binary },
      modelsRoot: { modelsRoot },
      inferletsDir: { self.tempDir.appendingPathComponent("inferlets") },
      pieControlResources: { resources },
      pieHome: { self.tempDir },
      subprocessEnvironment: { [:] },
      hfHome: { hfHome }
    )

    switch resolver.resolveLauncherSpec(profileID: ProfileStore.defaultProfileID) {
    case .success(let spec):
      XCTFail("unstaged default must fail before launch with an actionable modelMissing error; got \(spec)")
    case .failure(let err):
      XCTAssertEqual(err.code, .modelMissing)
      XCTAssertTrue(err.message.contains(ProfileStore.defaultChatModelID),
                    "message must name the GUI/default model; got: \(err.message)")
      XCTAssertTrue(err.message.contains(expectedLocalPath),
                    "message must name the app-staged path checked first; got: \(err.message)")
      XCTAssertTrue(err.message.contains(ProfileStore.defaultChatHFRepoID),
                    "message must name the HF/pie fallback repo; got: \(err.message)")
      XCTAssertTrue(err.message.contains("pie model download \(ProfileStore.defaultChatHFRepoID)"),
                    "message must include an operator recovery command; got: \(err.message)")
    }
  }

  func test_resolveLauncherSpec_allows_default_small_app_staged_model() throws {
    let store = try makeSeededDefaultStore()
    defer { store.stop() }

    let binary = tempDir.appendingPathComponent("pie-fake-small", isDirectory: false)
    try touchExecutable(at: binary)
    let resources = try writeInferletResources(name: "chat-apc", version: "0.1.0")
    let modelsRoot = tempDir.appendingPathComponent("models-small", isDirectory: true)
    try stageModel(named: ProfileStore.defaultChatModelID, in: modelsRoot)

    let resolver = LaunchSpecResolver(
      profileStore: store,
      pieBinary: { binary },
      modelsRoot: { modelsRoot },
      inferletsDir: { self.tempDir.appendingPathComponent("inferlets-small") },
      pieControlResources: { resources },
      pieHome: { self.tempDir },
      subprocessEnvironment: { [:] },
      hfHome: { self.tempDir.appendingPathComponent("hf-home-small", isDirectory: true) }
    )

    guard case .success(let spec) = resolver.resolveLauncherSpec(profileID: ProfileStore.defaultProfileID) else {
      return XCTFail("seeded default small model must remain launchable without a memory warning/block")
    }
    let body = PieControlLauncher.renderConfigBody(modelConfig: spec.modelConfig)
    XCTAssertTrue(body.contains(ProfileStore.defaultChatModelID), "got:\n\(body)")
  }

  func test_resolveLauncherSpec_rejects_oversized_app_staged_model_before_launch() throws {
    let store = try makeStoreWithModel("huge-local.gguf")
    defer { store.stop() }

    let binary = tempDir.appendingPathComponent("pie-fake-huge-local", isDirectory: false)
    try touchExecutable(at: binary)
    let resources = try writeInferletResources(name: "chat-apc", version: "0.1.0")
    let modelsRoot = tempDir.appendingPathComponent("models-huge-local", isDirectory: true)
    let hugeModel = try stageSparseModel(
      named: "huge-local.gguf",
      in: modelsRoot,
      sizeBytes: ModelMemoryGuardrail.defaultPolicy.maxResolvedModelBytes + 1
    )

    let resolver = LaunchSpecResolver(
      profileStore: store,
      pieBinary: { binary },
      modelsRoot: { modelsRoot },
      inferletsDir: { self.tempDir.appendingPathComponent("inferlets-huge-local") },
      pieControlResources: { resources },
      pieHome: { self.tempDir },
      subprocessEnvironment: { [:] },
      hfHome: { self.tempDir.appendingPathComponent("hf-home-huge-local", isDirectory: true) }
    )

    switch resolver.resolveLauncherSpec(profileID: "chat") {
    case .success(let spec):
      XCTFail("oversized local model must be rejected before PieControlLauncher can launch; got \(spec)")
    case .failure(let err):
      XCTAssertEqual(err.code, .memoryRisk)
      XCTAssertTrue(err.message.hasPrefix("memory risk: choose a smaller model"),
                    "recovery guidance must survive GUI menu truncation; got: \(err.message)")
      XCTAssertTrue(err.message.contains("choose a smaller model"), "got: \(err.message)")
      XCTAssertTrue(err.message.contains(hugeModel.path), "got: \(err.message)")
    }
  }

  func test_resolveLauncherSpec_rejects_oversized_hf_cache_snapshot_before_launch() throws {
    let store = try makeSeededDefaultStore()
    defer { store.stop() }

    let binary = tempDir.appendingPathComponent("pie-fake-huge-hf", isDirectory: false)
    try touchExecutable(at: binary)
    let resources = try writeInferletResources(name: "chat-apc", version: "0.1.0")
    let modelsRoot = tempDir.appendingPathComponent("models-huge-hf", isDirectory: true)
    let hfHome = tempDir.appendingPathComponent("hf-home-huge-hf", isDirectory: true)
    let snapshot = try writeHFCacheSnapshot(
      hfHome: hfHome,
      repo: ProfileStore.defaultChatHFRepoID,
      files: [
        "config.json": "{}",
        "tokenizer.json": "{}",
        "model.safetensors": "",
      ]
    )
    let weights = snapshot.appendingPathComponent("model.safetensors", isDirectory: false)
    try makeSparseFile(at: weights,
                       sizeBytes: ModelMemoryGuardrail.defaultPolicy.maxResolvedModelBytes + 1)

    let resolver = LaunchSpecResolver(
      profileStore: store,
      pieBinary: { binary },
      modelsRoot: { modelsRoot },
      inferletsDir: { self.tempDir.appendingPathComponent("inferlets-huge-hf") },
      pieControlResources: { resources },
      pieHome: { self.tempDir },
      subprocessEnvironment: { [:] },
      hfHome: { hfHome }
    )

    switch resolver.resolveLauncherSpec(profileID: ProfileStore.defaultProfileID) {
    case .success(let spec):
      XCTFail("oversized HF/pie-cache model must be rejected before launch; got \(spec)")
    case .failure(let err):
      XCTAssertEqual(err.code, .memoryRisk)
      XCTAssertTrue(err.message.hasPrefix("memory risk: choose a smaller model"),
                    "recovery guidance must survive GUI menu truncation; got: \(err.message)")
      XCTAssertTrue(err.message.contains("choose a smaller model"), "got: \(err.message)")
      XCTAssertTrue(err.message.contains("model.safetensors"), "got: \(err.message)")
    }
  }

  func test_resolveLauncherSpec_rejects_hf_cache_snapshot_with_hidden_oversized_artifact() throws {
    let store = try makeSeededDefaultStore()
    defer { store.stop() }

    let binary = tempDir.appendingPathComponent("pie-fake-hidden-huge-hf", isDirectory: false)
    try touchExecutable(at: binary)
    let resources = try writeInferletResources(name: "chat-apc", version: "0.1.0")
    let modelsRoot = tempDir.appendingPathComponent("models-hidden-huge-hf", isDirectory: true)
    let hfHome = tempDir.appendingPathComponent("hf-home-hidden-huge-hf", isDirectory: true)
    let snapshot = try writeHFCacheSnapshot(
      hfHome: hfHome,
      repo: ProfileStore.defaultChatHFRepoID,
      files: [
        "config.json": "{}",
        "tokenizer.json": "{}",
        "model.safetensors": "weights",
      ]
    )
    let hiddenWeights = snapshot.appendingPathComponent(".hidden-weights.safetensors", isDirectory: false)
    try makeSparseFile(at: hiddenWeights,
                       sizeBytes: ModelMemoryGuardrail.defaultPolicy.maxResolvedModelBytes + 1)

    let resolver = LaunchSpecResolver(
      profileStore: store,
      pieBinary: { binary },
      modelsRoot: { modelsRoot },
      inferletsDir: { self.tempDir.appendingPathComponent("inferlets-hidden-huge-hf") },
      pieControlResources: { resources },
      pieHome: { self.tempDir },
      subprocessEnvironment: { [:] },
      hfHome: { hfHome }
    )

    switch resolver.resolveLauncherSpec(profileID: ProfileStore.defaultProfileID) {
    case .success(let spec):
      XCTFail("hidden oversized HF artifact must be counted by the memory guardrail; got \(spec)")
    case .failure(let err):
      XCTAssertEqual(err.code, .memoryRisk)
      XCTAssertTrue(err.message.contains("memory risk"), "got: \(err.message)")
      XCTAssertTrue(err.message.contains(".hidden-weights.safetensors"), "got: \(err.message)")
    }
  }

  func test_resolveLauncherSpec_rejects_hf_cache_snapshot_with_hidden_dangling_artifact() throws {
    let store = try makeSeededDefaultStore()
    defer { store.stop() }

    let binary = tempDir.appendingPathComponent("pie-fake-hidden-dangling-hf", isDirectory: false)
    try touchExecutable(at: binary)
    let resources = try writeInferletResources(name: "chat-apc", version: "0.1.0")
    let modelsRoot = tempDir.appendingPathComponent("models-hidden-dangling-hf", isDirectory: true)
    let hfHome = tempDir.appendingPathComponent("hf-home-hidden-dangling-hf", isDirectory: true)
    let snapshot = try writeHFCacheSnapshot(
      hfHome: hfHome,
      repo: ProfileStore.defaultChatHFRepoID,
      files: [
        "config.json": "{}",
        "tokenizer.json": "{}",
        "model.safetensors": "weights",
      ]
    )
    let hiddenDangling = snapshot.appendingPathComponent(".hidden-dangling.bin", isDirectory: false)
    try FileManager.default.createSymbolicLink(
      atPath: hiddenDangling.path,
      withDestinationPath: "../../blobs/missing-hidden-dangling"
    )

    let resolver = LaunchSpecResolver(
      profileStore: store,
      pieBinary: { binary },
      modelsRoot: { modelsRoot },
      inferletsDir: { self.tempDir.appendingPathComponent("inferlets-hidden-dangling-hf") },
      pieControlResources: { resources },
      pieHome: { self.tempDir },
      subprocessEnvironment: { [:] },
      hfHome: { hfHome }
    )

    switch resolver.resolveLauncherSpec(profileID: ProfileStore.defaultProfileID) {
    case .success(let spec):
      XCTFail("hidden unknown-size HF artifact must fail closed as memoryRisk; got \(spec)")
    case .failure(let err):
      XCTAssertEqual(err.code, .memoryRisk)
      XCTAssertTrue(err.message.contains("cannot determine model size safely"), "got: \(err.message)")
      XCTAssertTrue(err.message.contains(".hidden-dangling.bin"), "got: \(err.message)")
    }
  }

  func test_resolveLauncherSpec_rejects_hf_cache_snapshot_with_unreadable_subtree() throws {
    let store = try makeSeededDefaultStore()
    defer { store.stop() }

    let binary = tempDir.appendingPathComponent("pie-fake-unreadable-hf", isDirectory: false)
    try touchExecutable(at: binary)
    let resources = try writeInferletResources(name: "chat-apc", version: "0.1.0")
    let modelsRoot = tempDir.appendingPathComponent("models-unreadable-hf", isDirectory: true)
    let hfHome = tempDir.appendingPathComponent("hf-home-unreadable-hf", isDirectory: true)
    let snapshot = try writeHFCacheSnapshot(
      hfHome: hfHome,
      repo: ProfileStore.defaultChatHFRepoID,
      files: [
        "config.json": "{}",
        "tokenizer.json": "{}",
        "model.safetensors": "weights",
      ]
    )
    let unreadable = snapshot.appendingPathComponent("unreadable-artifacts", isDirectory: true)
    try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)
    try "uninspectable".write(
      to: unreadable.appendingPathComponent("artifact.bin", isDirectory: false),
      atomically: true,
      encoding: .utf8
    )
    try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o000)],
                                          ofItemAtPath: unreadable.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)],
                                             ofItemAtPath: unreadable.path)
    }

    let resolver = LaunchSpecResolver(
      profileStore: store,
      pieBinary: { binary },
      modelsRoot: { modelsRoot },
      inferletsDir: { self.tempDir.appendingPathComponent("inferlets-unreadable-hf") },
      pieControlResources: { resources },
      pieHome: { self.tempDir },
      subprocessEnvironment: { [:] },
      hfHome: { hfHome }
    )

    switch resolver.resolveLauncherSpec(profileID: ProfileStore.defaultProfileID) {
    case .success(let spec):
      XCTFail("unreadable HF subtree must fail closed as memoryRisk; got \(spec)")
    case .failure(let err):
      XCTAssertEqual(err.code, .memoryRisk)
      XCTAssertTrue(err.message.contains("cannot determine model size safely"), "got: \(err.message)")
      XCTAssertTrue(err.message.contains("unreadable-artifacts"), "got: \(err.message)")
    }
  }

  /// Review v2 F7 regression guard, second path. The post-
  /// `resolveLauncherSpec` returns a `PieControlLauncher.LaunchSpec`
  /// whose `inferletNameAtVersion` flows into the `launch_daemon` WS
  /// call. Profile-driven inferlet selection MUST reach that field —
  /// not get overwritten by the launcher's bundled default —
  /// otherwise the silent-drop the legacy fix closed re-opens on the
  /// production Resume path.
  func test_resolveLauncherSpec_propagates_inferlet_name() throws {
    let profiles = tempDir.appendingPathComponent("profiles", isDirectory: true)
    try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
    let toml = """
    id = "alt"
    name = "Alt"
    model = "llama-3.1-8b-instruct"
    inferlet = "other-inferlet@2.0.0"
    """
    try toml.write(to: profiles.appendingPathComponent("alt.toml"),
                   atomically: true, encoding: .utf8)
    let activeURL = tempDir.appendingPathComponent("active-profile", isDirectory: false)
    let store = ProfileStore(directory: profiles, activeProfileURL: activeURL)
    try store.start()
    defer { store.stop() }

    let binary = tempDir.appendingPathComponent("pie-fake", isDirectory: false)
    try touchExecutable(at: binary)

    let resources = try writeInferletResources(name: "other-inferlet", version: "2.0.0")
    let modelsRoot = tempDir.appendingPathComponent("models-alt", isDirectory: true)
    try stageModel(named: "llama-3.1-8b-instruct", in: modelsRoot)
    let resolver = LaunchSpecResolver(
      profileStore: store,
      pieBinary: { binary },
      modelsRoot: { modelsRoot },
      inferletsDir: { self.tempDir.appendingPathComponent("inferlets") },
      pieControlResources: { resources },
      pieHome: { self.tempDir },
      subprocessEnvironment: { [:] }
    )
    guard case .success(let spec) = resolver.resolveLauncherSpec(profileID: "alt") else {
      return XCTFail("expected .success for profile carrying a non-default inferlet")
    }
    XCTAssertEqual(spec.inferletNameAtVersion, "other-inferlet@2.0.0",
                   "profile.inferlet must reach PieControlLauncher.LaunchSpec.inferletNameAtVersion verbatim — silent drop on the launcher path is the same v2 F7 class of bug closed for the legacy supervisor path")
  }

  /// Review v1 F2: until multi-inferlet resource selection exists,
  /// the resolver uploads the one bundled manifest returned by
  /// `pieControlResources`; it must not then ask `launch_daemon` for
  /// a different inferlet id that was never installed.
  func test_resolveLauncherSpec_rejects_profile_inferlet_that_does_not_match_manifest() throws {
    let profiles = tempDir.appendingPathComponent("profiles", isDirectory: true)
    try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
    let toml = """
    id = "alt"
    name = "Alt"
    model = "llama-3.1-8b-instruct"
    inferlet = "other-inferlet@2.0.0"
    """
    try toml.write(to: profiles.appendingPathComponent("alt.toml"),
                   atomically: true, encoding: .utf8)
    let activeURL = tempDir.appendingPathComponent("active-profile", isDirectory: false)
    let store = ProfileStore(directory: profiles, activeProfileURL: activeURL)
    try store.start()
    defer { store.stop() }

    let binary = tempDir.appendingPathComponent("pie-fake", isDirectory: false)
    try touchExecutable(at: binary)

    let resources = try writeInferletResources(name: "chat-apc", version: "0.1.0")
    let resolver = LaunchSpecResolver(
      profileStore: store,
      pieBinary: { binary },
      modelsRoot: { self.tempDir.appendingPathComponent("models") },
      inferletsDir: { self.tempDir.appendingPathComponent("inferlets") },
      pieControlResources: { resources },
      pieHome: { self.tempDir },
      subprocessEnvironment: { [:] }
    )
    switch resolver.resolveLauncherSpec(profileID: "alt") {
    case .success(let spec):
      XCTFail("expected .failure for profile inferlet not installed by bundled manifest; got \(spec)")
    case .failure(let err):
      XCTAssertEqual(err.code, .invalidInput,
                     "profile/manifest mismatch must fail before launchDaemon asks for an inferlet that installProgram never uploaded")
    }
  }

  // MARK: - split-GGUF refusal

  // The catalog marks a split-GGUF row unlaunchable so the picker can't
  // select one, but a stale or hand-authored profile could still name a
  // shard. The launch path must refuse it FAST with a clear reason (no
  // engine work, no hang on the missing-tensor fatal).
  func test_resolveLauncherSpec_rejects_split_gguf_shard_as_invalid_input() throws {
    let profiles = tempDir.appendingPathComponent("profiles", isDirectory: true)
    try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
    try """
    id = "chat"
    name = "Chat"
    model = "unsloth/Big-GGUF/Big-Q4_K_M-00001-of-00003.gguf"
    inferlet = "chat-apc"
    """.write(to: profiles.appendingPathComponent("chat.toml"), atomically: true, encoding: .utf8)
    let store = ProfileStore(directory: profiles,
                             activeProfileURL: tempDir.appendingPathComponent("active-profile"))
    try store.start()
    defer { store.stop() }

    // Fake closures suffice — the guard returns before any of them run.
    let resolver = LaunchSpecResolver(
      profileStore: store,
      pieBinary: { self.tempDir.appendingPathComponent("pie-fake") },
      modelsRoot: { self.tempDir.appendingPathComponent("models") },
      inferletsDir: { self.tempDir.appendingPathComponent("inferlets") }
    )
    guard case .failure(let err) = resolver.resolveLauncherSpec(profileID: "chat") else {
      return XCTFail("a split-GGUF shard model must be refused before launch")
    }
    XCTAssertEqual(err.code, .invalidInput,
                   "a split shard is invalid input the engine can't load — not missing/oversized")
    XCTAssertTrue(err.message.contains("Split GGUF"),
                  "the failure must explain why it was refused: \(err.message)")
  }

  // MARK: - catalog slug → launch round-trip

  /// A slug produced by `HFCacheCatalog.scan` must resolve to the right
  /// `hf_repo` SHAPE — the `.gguf` FILE for a GGUF repo, the snapshot
  /// DIRECTORY for a safetensors repo — and the catalog's reported size
  /// must agree with what the memory guardrail measures for that target.
  /// This is the gap that let a dir-written-as-hf_repo-for-GGUF bug land.
  // NB: deliberately NOT the seeded default repo. `defaultChatModelID`
  // hits LaunchSpecResolver.hfIdentity's default special-case (file:nil →
  // repo-level snapshot dir). A non-default GGUF repo exercises the
  // GENERAL discovered-cache path this catalog feeds — and still catches
  // the regression: a 2-segment catalog slug would resolve to the
  // snapshot dir, failing the `.gguf`-suffix check below.
  func test_catalog_gguf_slug_resolves_to_gguf_file_hf_repo() throws {
    try assertCatalogRoundTrip(
      repo: "TheBloke/Llama-2-7B-Chat-GGUF",
      files: ["config.json": "{}", "tokenizer.json": "{}",
              "llama-2-7b-chat.Q4_K_M.gguf": String(repeating: "g", count: 4096)],
      expectedSlug: "TheBloke/Llama-2-7B-Chat-GGUF/llama-2-7b-chat.Q4_K_M.gguf",
      hfRepoMustContain: "llama-2-7b-chat.Q4_K_M.gguf",
      hfRepoMustBeGGUFFile: true)
  }

  func test_catalog_safetensors_slug_resolves_to_snapshot_dir_hf_repo() throws {
    try assertCatalogRoundTrip(
      repo: "Qwen/Qwen3-0.6B",
      files: ["config.json": "{}", "tokenizer.json": "{}",
              "model.safetensors": String(repeating: "s", count: 4096)],
      expectedSlug: "Qwen/Qwen3-0.6B",
      hfRepoMustContain: "snapshots",
      hfRepoMustBeGGUFFile: false)
  }

  private func assertCatalogRoundTrip(repo: String,
                                      files: [String: String],
                                      expectedSlug: String,
                                      hfRepoMustContain: String,
                                      hfRepoMustBeGGUFFile: Bool,
                                      line: UInt = #line) throws {
    let suffix = repo.replacingOccurrences(of: "/", with: "-")
    let hfHome = tempDir.appendingPathComponent("hf-rt-\(suffix)", isDirectory: true)
    try writeHFCacheSnapshot(hfHome: hfHome, repo: repo, files: files)

    let rows = HFCacheCatalog.scan(hfHome: hfHome)
    guard let row = rows.first(where: { $0.filename == expectedSlug }) else {
      return XCTFail("catalog must list \(expectedSlug); got \(rows.map(\.filename))", line: line)
    }

    // Size agreement: the guardrail measures exactly what the catalog
    // reported for the same resolved target (boundary on row.sizeBytes).
    let atLimit = ModelMemoryGuardrail.validate(
      resolvedModelURL: row.url, modelID: row.filename,
      policy: .init(maxResolvedModelBytes: row.sizeBytes))
    if case .failure(let err) = atLimit {
      XCTFail("catalog size must pass its own ceiling; \(err.message)", line: line)
    }
    let belowLimit = ModelMemoryGuardrail.validate(
      resolvedModelURL: row.url, modelID: row.filename,
      policy: .init(maxResolvedModelBytes: row.sizeBytes - 1))
    if case .success = belowLimit {
      XCTFail("guardrail must measure the same size the catalog reported", line: line)
    }

    // Round-trip through the production resolver → hf_repo shape.
    let store = try makeStoreWithModel(row.filename)
    defer { store.stop() }
    let binary = tempDir.appendingPathComponent("pie-fake-rt-\(suffix)", isDirectory: false)
    try touchExecutable(at: binary)
    let resources = try writeInferletResources(name: "chat-apc", version: "0.1.0")
    let resolver = LaunchSpecResolver(
      profileStore: store,
      pieBinary: { binary },
      modelsRoot: { self.tempDir.appendingPathComponent("models-rt-\(suffix)", isDirectory: true) },
      inferletsDir: { self.tempDir.appendingPathComponent("inferlets-rt-\(suffix)") },
      pieControlResources: { resources },
      pieHome: { self.tempDir },
      subprocessEnvironment: { [:] },
      hfHome: { hfHome })

    guard case .success(let spec) = resolver.resolveLauncherSpec(profileID: "chat") else {
      return XCTFail("catalog slug \(row.filename) must resolve to a launchable spec", line: line)
    }
    let body = PieControlLauncher.renderConfigBody(modelConfig: spec.modelConfig)
    // Assert on the hf_repo VALUE alone, not the whole body: `name`
    // carries the full slug (which for GGUF already contains the quant
    // filename + ".gguf"), so a body-wide contains() would pass even if
    // hf_repo regressed to the snapshot dir.
    guard let hfRepo = Self.hfRepoValue(in: body) else {
      return XCTFail("rendered config must have an hf_repo line; body:\n\(body)", line: line)
    }
    XCTAssertTrue(hfRepo.contains(hfRepoMustContain),
                  "hf_repo must contain \(hfRepoMustContain.debugDescription); hf_repo=\(hfRepo)", line: line)
    if hfRepoMustBeGGUFFile {
      XCTAssertTrue(hfRepo.hasSuffix(".gguf"),
                    "GGUF hf_repo must END with the .gguf file, not the snapshot dir; hf_repo=\(hfRepo)", line: line)
    } else {
      XCTAssertFalse(hfRepo.contains(".gguf"),
                     "safetensors hf_repo must be the snapshot dir, never a .gguf; hf_repo=\(hfRepo)", line: line)
    }
  }

  /// Extract the value of the `hf_repo = "<value>"` line from a rendered
  /// pie config body (TOML basic string). Returns nil when absent.
  static func hfRepoValue(in body: String) -> String? {
    for rawLine in body.split(separator: "\n") {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      guard line.hasPrefix("hf_repo"), let eq = line.firstIndex(of: "=") else { continue }
      let rhs = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
      return rhs.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }
    return nil
  }

  /// Negative guard: prove the round-trip assertion actually catches a
  /// dir-shaped hf_repo for a GGUF slug. The `name` line carries the full
  /// `.gguf` slug, but `hfRepoValue` must read the hf_repo line (the
  /// snapshot dir) — so the GGUF `.gguf`-suffix check would FAIL here,
  /// exactly as it should when the dir-as-hf_repo bug regresses.
  func test_round_trip_guard_catches_dir_shaped_gguf_hf_repo() {
    let ggufSlug = "Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf"
    let snapshotDir = "/cache/hub/models--Qwen--Qwen3-0.6B-GGUF/snapshots/abc123"
    let body = PieControlLauncher.renderConfigBody(
      modelConfig: .portableResolved(servedModelID: ggufSlug, modelRef: snapshotDir))
    // The whole body DOES contain ".gguf" (via `name`), which is exactly
    // why asserting on the body would be a false pass.
    XCTAssertTrue(body.contains(".gguf"))
    let hfRepo = Self.hfRepoValue(in: body)
    XCTAssertEqual(hfRepo, snapshotDir, "parser must read hf_repo, not the name slug")
    XCTAssertFalse(hfRepo?.hasSuffix(".gguf") ?? true,
                   "a dir-shaped GGUF hf_repo must be detectable as NOT a .gguf file")
  }

  // MARK: - helpers

  private func makeStoreWithChatProfile() throws -> ProfileStore {
    try makeStoreWithModel("llama-3.1-8b-instruct")
  }

  private func makeStoreWithModel(_ model: String) throws -> ProfileStore {
    let profiles = tempDir.appendingPathComponent("profiles", isDirectory: true)
    try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
    let toml = """
    id = "chat"
    name = "Chat"
    model = "\(model)"
    inferlet = "chat-apc"
    """
    try toml.write(to: profiles.appendingPathComponent("chat.toml"),
                   atomically: true, encoding: .utf8)
    let active = tempDir.appendingPathComponent("active-profile", isDirectory: false)
    let store = ProfileStore(directory: profiles, activeProfileURL: active)
    try store.start()
    return store
  }

  private func makeSeededDefaultStore() throws -> ProfileStore {
    let profiles = tempDir.appendingPathComponent("profiles-default", isDirectory: true)
    let active = tempDir.appendingPathComponent("active-profile-default", isDirectory: false)
    let store = ProfileStore(directory: profiles, activeProfileURL: active)
    try store.start()
    XCTAssertEqual(store.activeProfileID, ProfileStore.defaultProfileID)
    return store
  }

  private func assertDefaultHFCacheWithDanglingArtifactFails(_ artifact: String) throws {
    let store = try makeSeededDefaultStore()
    defer { store.stop() }

    let binary = tempDir.appendingPathComponent("pie-fake-\(artifact)", isDirectory: false)
    try touchExecutable(at: binary)
    let resources = try writeInferletResources(name: "chat-apc", version: "0.1.0")
    let modelsRoot = tempDir.appendingPathComponent("models-\(artifact)", isDirectory: true)
    let hfHome = tempDir.appendingPathComponent("hf-home-\(artifact)", isDirectory: true)
    let snapshot = try writeHFCacheSnapshot(
      hfHome: hfHome,
      repo: ProfileStore.defaultChatHFRepoID,
      files: [
        "config.json": "{}",
        "tokenizer.json": "{}",
        "model.safetensors": "weights",
      ]
    )
    let dangling = snapshot.appendingPathComponent(artifact, isDirectory: false)
    try FileManager.default.removeItem(at: dangling)
    try FileManager.default.createSymbolicLink(
      atPath: dangling.path,
      withDestinationPath: "../../blobs/missing-\(artifact)"
    )

    let resolver = LaunchSpecResolver(
      profileStore: store,
      pieBinary: { binary },
      modelsRoot: { modelsRoot },
      inferletsDir: { self.tempDir.appendingPathComponent("inferlets-\(artifact)") },
      pieControlResources: { resources },
      pieHome: { self.tempDir },
      subprocessEnvironment: { [:] },
      hfHome: { hfHome }
    )

    switch resolver.resolveLauncherSpec(profileID: ProfileStore.defaultProfileID) {
    case .success(let spec):
      XCTFail("dangling HF snapshot artifact \(artifact) must not be treated as launchable; got \(spec)")
    case .failure(let err):
      XCTAssertEqual(err.code, .modelMissing)
      XCTAssertTrue(err.message.contains("HF cache invalid"), "got: \(err.message)")
      XCTAssertTrue(err.message.contains(dangling.path), "got: \(err.message)")
      XCTAssertTrue(err.message.contains("dangling symlink"), "got: \(err.message)")
    }
  }

  private func stageModel(named name: String, in modelsRoot: URL) throws {
    let url = name
      .split(separator: "/", omittingEmptySubsequences: true)
      .map(String.init)
      .reduce(modelsRoot) { partial, component in
        partial.appendingPathComponent(component, isDirectory: false)
      }
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("model".utf8).write(to: url)
  }

  @discardableResult
  private func stageSparseModel(named name: String,
                                in modelsRoot: URL,
                                sizeBytes: Int64) throws -> URL {
    let url = name
      .split(separator: "/", omittingEmptySubsequences: true)
      .map(String.init)
      .reduce(modelsRoot) { partial, component in
        partial.appendingPathComponent(component, isDirectory: false)
      }
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try makeSparseFile(at: url, sizeBytes: sizeBytes)
    return url
  }

  private func makeSparseFile(at url: URL, sizeBytes: Int64) throws {
    _ = FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: UInt64(sizeBytes))
    try handle.close()
  }

  @discardableResult
  private func writeHFCacheSnapshot(hfHome: URL,
                                    repo: String,
                                    revision: String = "0123456789abcdef0123456789abcdef01234567",
                                    files: [String: String]) throws -> URL {
    let repoDir = hfHome
      .appendingPathComponent("hub", isDirectory: true)
      .appendingPathComponent("models--\(repo.replacingOccurrences(of: "/", with: "--"))",
                              isDirectory: true)
    let refsDir = repoDir.appendingPathComponent("refs", isDirectory: true)
    let snapshot = repoDir
      .appendingPathComponent("snapshots", isDirectory: true)
      .appendingPathComponent(revision, isDirectory: true)
    try FileManager.default.createDirectory(at: refsDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
    try revision.write(to: refsDir.appendingPathComponent("main"),
                       atomically: true, encoding: .utf8)
    for (relativePath, contents) in files {
      let url = snapshot.appendingPathComponent(relativePath, isDirectory: false)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try contents.write(to: url, atomically: true, encoding: .utf8)
    }
    return snapshot
  }

  @discardableResult
  private func writeHFCacheRef(hfHome: URL,
                               repo: String,
                               contents: String) throws -> URL {
    let refsDir = hfHome
      .appendingPathComponent("hub", isDirectory: true)
      .appendingPathComponent("models--\(repo.replacingOccurrences(of: "/", with: "--"))",
                              isDirectory: true)
      .appendingPathComponent("refs", isDirectory: true)
    try FileManager.default.createDirectory(at: refsDir, withIntermediateDirectories: true)
    let ref = refsDir.appendingPathComponent("main", isDirectory: false)
    try contents.write(to: ref, atomically: true, encoding: .utf8)
    return ref
  }

  @discardableResult
  private func writeHFCacheRefDirectory(hfHome: URL,
                                        repo: String) throws -> URL {
    let ref = hfHome
      .appendingPathComponent("hub", isDirectory: true)
      .appendingPathComponent("models--\(repo.replacingOccurrences(of: "/", with: "--"))",
                              isDirectory: true)
      .appendingPathComponent("refs", isDirectory: true)
      .appendingPathComponent("main", isDirectory: true)
    try FileManager.default.createDirectory(at: ref, withIntermediateDirectories: true)
    return ref
  }

  private func writeInferletResources(name: String,
                                      version: String) throws -> (wasm: URL, manifest: URL) {
    let dir = tempDir.appendingPathComponent("inferlet-\(name)-\(version)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let wasm = dir.appendingPathComponent("\(name).wasm", isDirectory: false)
    try Data().write(to: wasm)
    let manifest = dir.appendingPathComponent("Pie.toml", isDirectory: false)
    try """
    [package]
    name = "\(name)"
    version = "\(version)"
    """.write(to: manifest, atomically: true, encoding: .utf8)
    return (wasm: wasm, manifest: manifest)
  }

  private func touchExecutable(at url: URL) throws {
    let script = """
    #!/bin/sh
    if [ "$1" = "driver" ] && [ "$2" = "list" ]; then
      printf 'Embedded drivers (compiled into this binary by feature):\\n  portable     (compiled in)\\n'
      exit 0
    fi
    exit 0
    """
    try script.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o755)],
      ofItemAtPath: url.path
    )
  }
}
