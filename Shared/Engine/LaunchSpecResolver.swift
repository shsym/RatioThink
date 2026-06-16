import Foundation
import os
import TOMLKit

/// Maps a `profileID` string into a `PieControlLauncher.LaunchSpec`
/// that the helper's `startEngine` selector can hand to the launcher.
///
/// Pipeline (`resolveLauncherSpec`):
///   1. Look up the matching parsed `Profile` in the injected
///      `ProfileStore`. A missing id (no such profile, or the entry
///      failed to parse) short-circuits to `.profileMissing` — the
///      same wire code Phase 2.2 stubbed in so the GUI's error path
///      does not change shape.
///   2. Resolve filesystem paths the launcher needs (`pie` binary,
///      models root, chat-apc wasm + manifest, PIE_HOME). Each path
///      source is injected as a throwing closure so tests can stub
///      deterministic temp paths and a real PieDirs trap surfaces as a
///      structured error rather than crashing the helper.
///   3. Compose the `LaunchSpec`. `modelPath` joins `modelsRoot` with
///      `profile.model` — the profile stores either a bare GGUF
///      filename or a `<repo>/<file>` slug matching the downloader's
///      on-disk layout (`<modelsRoot>/<repo>/<file>`). `inferletName`
///      is propagated verbatim from `profile.inferlet` so the engine
///      activates the right inferlet (review v2 F7 — silent drop bit
///      anything beyond the helper's auto-selected default).
///
/// The resolver itself does not read the active profile selection —
/// that is a caller concern (menu-bar Resume, GUI Start). Plumbing
/// the active-id read here would couple the wire boundary to UI
/// policy and complicate testing (the same resolver is exercised
/// with bench-driven ids in `LaunchSpecResolverTests`).
public struct LaunchSpecResolver {
  /// Source of parsed profiles. Looked up by `profile.id` (not
  /// filename) so multiple `*.toml` files can coexist as long as
  /// their ids are unique.
  public let profileStore: ProfileStore

  /// Returns the bundled `pie` engine executable. Throws when the
  /// binary is missing — surfaced over XPC as `.spawnFailed` rather
  /// than `.profileMissing` so the GUI distinguishes "user picked an
  /// invalid profile" from "Rational.app is broken".
  public let pieBinary: () throws -> URL

  /// Returns the models root (default `PieDirs.models()`).
  public let modelsRoot: () throws -> URL

  /// Returns the bundled `chat-apc` wasm + manifest used by
  /// `PieControlLauncher`'s `install_program` WS call. Default
  /// delegates to `InferletResources.pieControl(in: .main)` so the
  /// helper resolves them from `Rational.app/Contents/Resources/Inferlets`
  /// without having to know the bundle layout. Tests inject a stub
  /// returning temp-dir paths.
  public let pieControlResources: () throws -> (wasm: URL, manifest: URL)

  /// Returns `PieDirs.applicationSupport()`. Used as `PIE_HOME` for
  /// the spawned `pie serve`. Test-only injection seam — production
  /// always uses the real PieDirs root.
  public let pieHome: () throws -> URL

  /// Builds the sanitized subprocess env handed to
  /// `PieControlLauncher.launch`. Defaults to
  /// `SpawnEnvSanitizer.sanitize(ProcessInfo.processInfo.environment)`
  /// — the same policy `IsolatedTestCase.subprocessEnvironment`
  /// uses (review v6 F2). Tests override to pin a deterministic env.
  public let subprocessEnvironment: () -> [String: String]

  /// HuggingFace cache root (`HF_HOME`, not `HF_HOME/hub`) used as a
  /// read-only fallback after Rational's app-managed models directory.
  public let hfHome: () -> URL

  /// Resolved-model memory ceiling handed to `ModelMemoryGuardrail`.
  /// Production reads physical RAM (`ModelMemoryGuardrail.defaultPolicy`);
  /// tests inject a fixed `Policy` so their fixtures never depend on the
  /// host's real memory.
  public let memoryPolicy: () -> ModelMemoryGuardrail.Policy

  /// Desired OpenAI-compatible daemon bind mode for helper-owned starts.
  /// XPC-driven app starts can still override the resolved spec explicitly,
  /// but menu-bar Resume and auto-relaunch call `engineHost.start(spec)`
  /// directly, so the shared resolver must stamp the persisted preference
  /// before the spec reaches the host.
  public let daemonBindMode: () -> EngineHTTPBindMode

  private static let log = Logger(subsystem: "com.ratiothink.app.helper",
                                  category: "launchspec.resolver")

  public init(profileStore: ProfileStore,
              pieBinary: @escaping () throws -> URL,
              modelsRoot: @escaping () throws -> URL = { try PieDirs.models() },
              pieControlResources: @escaping () throws -> (wasm: URL, manifest: URL)
                = { try InferletResources.pieControl(in: .main) },
              pieHome: @escaping () throws -> URL = { try PieDirs.applicationSupport() },
              subprocessEnvironment: @escaping () -> [String: String]
                = { SpawnEnvSanitizer.sanitize(ProcessInfo.processInfo.environment) },
              hfHome: @escaping () -> URL = { LaunchSpecResolver.defaultHFHome() },
              memoryPolicy: @escaping () -> ModelMemoryGuardrail.Policy
                = { ModelMemoryGuardrail.defaultPolicy },
              daemonBindMode: @escaping () -> EngineHTTPBindMode
                = { EngineHTTPBindMode.persistedLocalAPIBindMode() }) {
    self.profileStore = profileStore
    self.pieBinary = pieBinary
    self.modelsRoot = modelsRoot
    self.pieControlResources = pieControlResources
    self.pieHome = pieHome
    self.subprocessEnvironment = subprocessEnvironment
    self.hfHome = hfHome
    self.memoryPolicy = memoryPolicy
    self.daemonBindMode = daemonBindMode
  }

  /// Type-erased adapter matching `HelperExportedAPI.LaunchSpecResolver`.
  /// Captures `self` so the helper can hold the closure for the
  /// lifetime of the XPC listener.
  public var asClosure: HelperExportedAPI.LaunchSpecResolver {
    { id, explicitModel in self.resolveLauncherSpec(profileID: id, explicitModel: explicitModel) }
  }

  /// `PieControlLauncher`-shaped resolver. Composes the
  /// `Profile`-bound model path with the launcher's extra inputs:
  /// bundled chat-apc wasm +
  /// manifest, sanitized subprocess env, PIE_HOME, and a unique
  /// shmem name. The launcher's `writeConfig` then emits a
  /// production TOML with `[model.driver] type = "portable"` and
  /// `hf_path` pointed at the on-disk model the operator selected.
  ///
  /// `explicitModel` is the user's per-start model selection (the chat
  /// toolbar / model-list pick, `viewModel.modelOverride`). When present it
  /// is the boot model, overriding `profile.model` — #459 repro 1: a
  /// no-default profile is started by an explicit pick the helper must honor
  /// even though the profile carries no default. v1 pie loads the model at
  /// `pie serve` boot from this spec, so the engine has to be told which
  /// model to serve here; an override that only lived in App state would
  /// never reach the boot config. Threading it in the same XPC call as the
  /// profile id keeps it race-free against the helper's own FS-watched
  /// `ProfileStore` (which may not yet have observed an App-side default
  /// write). `nil`/blank falls back to the profile's persisted default.
  public func resolveLauncherSpec(profileID: String,
                                  explicitModel: String? = nil) -> Result<PieControlLauncher.LaunchSpec, EngineError> {
    guard let profile = lookup(profileID: profileID) else {
      return .failure(EngineError(
        code: .profileMissing,
        message: "no profile with id=\(profileID) in \(profileStore.directory.path)"
      ))
    }
    // Refuse a split-GGUF shard (`…-NNNNN-of-MMMMM.gguf`) before any
    // engine work. The catalog marks such rows unlaunchable so the picker
    // can't select them, but a stale or hand-authored profile could still
    // name one — fail fast with a clear reason instead of handing the
    // engine a shard it cannot load.
    guard let model = Self.effectiveModel(explicitModel: explicitModel,
                                          profileModel: profile.model) else {
      return .failure(Self.noDefaultModelError(profile: profile))
    }
    let modelLeaf = model.split(separator: "/").last.map(String.init) ?? model
    if HFCacheCatalog.isSplitShardFilename(modelLeaf) {
      return .failure(EngineError(
        code: .invalidInput,
        message: "\(HFCacheCatalog.shardedUnsupportedReason) (model=\(model))"
      ))
    }
    let binary: URL
    let models: URL
    let resources: (wasm: URL, manifest: URL)
    let home: URL
    do {
      binary    = try pieBinary()
      models    = try modelsRoot()
      resources = try pieControlResources()
      home      = try pieHome()
    } catch {
      Self.log.error("launcher path resolution failed for profile=\(profile.id, privacy: .public): \(String(describing: error), privacy: .public)")
      return .failure(EngineError(
        code: .spawnFailed,
        message: "launcher path resolution failed: \(String(describing: error))"
      ))
    }
    let inferletNameAtVersion: String
    switch Self.inferletNameAtVersion(profileInferlet: profile.inferlet,
                                      manifestURL: resources.manifest) {
    case .success(let name): inferletNameAtVersion = name
    case .failure(let err):  return .failure(err)
    }
    let modelRef: String
    switch resolveModelRef(model: model, profile: profile, modelsRoot: models) {
    case .success(let resolved): modelRef = resolved
    case .failure(let err):      return .failure(err)
    }
    let shmem = Self.uniqueShmemName()
    let env = subprocessEnvironment()
    do {
      // Memory-aware per-request output ceiling (#438): from the resolved
      // model's arch dims + weight size, compute how many F16 KV tokens
      // fit in the RAM budget after weights + a conservative overhead,
      // clamped to the context window and the engine default pool. Written
      // as `default_token_limit`, which chat-apc reads back via
      // `runtime::max-output-tokens`. Down-only: `nil` (omit) when the
      // metadata can't be read or the host sustains the full default.
      let modelURL = URL(fileURLWithPath: modelRef, isDirectory: false)
      let weightBytes = ModelMemoryGuardrail.resolvedBytes(resolvedModelURL: modelURL)
      let defaultTokenLimit: Int? = ModelArchMetadata.read(resolvedModelURL: modelURL)
        .flatMap { metadata in
          weightBytes.flatMap { bytes in
            KVCacheBudget.outputTokenCeiling(
              policy: memoryPolicy(), weightBytes: bytes, metadata: metadata)
          }
        }
      // Size-aware engine timeout (#687): larger GGUFs need a longer cold
      // Metal prefill budget than the 120s floor. An explicit
      // PIE_SHMEM_TIMEOUT_S in the helper environment (read pre-sanitize)
      // overrides the computed default — see `resolvedRequestTimeoutSeconds`.
      let hostEnv = ProcessInfo.processInfo.environment
      let requestTimeoutSeconds = PieControlLauncher.resolvedRequestTimeoutSeconds(
        modelWeightBytes: weightBytes,
        environment: hostEnv)
      // (#698 F3) A present-but-invalid PIE_SHMEM_TIMEOUT_S is silently dropped
      // by the resolver, which falls back to the size-aware default. A typo'd
      // override would otherwise leave no trace — name the rejected raw value
      // and the budget actually applied so the operator can spot the mistake.
      if let rejected = PieControlLauncher.rejectedTimeoutOverride(environment: hostEnv) {
        DiagnosticLog.helper.event("engine.timeout.override-rejected", [
          ("raw", rejected),
          ("applied_request_timeout_secs", String(requestTimeoutSeconds)),
        ])
      }
      // (#698 F5) The model resolved AND passed ModelMemoryGuardrail.validate
      // above — validate fails CLOSED on an unmeasurable artifact — so reaching
      // here with nil weight bytes means the file became unreadable AFTER
      // validation (a TOCTOU race: deleted/relocated mid-launch), not a normal
      // small model. Both nil and measured-small otherwise collapse to the 120s
      // floor; distinguish them so an operator sees the budget was sized blind
      // and can extend it via PIE_SHMEM_TIMEOUT_S if the model is in fact large.
      if weightBytes == nil {
        DiagnosticLog.helper.event("engine.timeout.weight-bytes-unmeasurable", [
          ("model", model),
          ("path", DiagnosticLog.redactHome(modelRef)),
          ("applied_request_timeout_secs", String(requestTimeoutSeconds)),
        ])
      }
      let spec = try PieControlLauncher.LaunchSpec(
        pieBinary: binary,
        wasmURL: resources.wasm,
        manifestURL: resources.manifest,
        subprocessEnvironment: env,
        pieHome: home,
        shmemName: shmem,
        inferletNameAtVersion: inferletNameAtVersion,
        // Real `pie serve` cold boot loads the model weights before the READY
        // handshake; align the boot budget with the size-aware request/shmem
        // timeout so a slow large-model start is not killed by the 30s default
        // handshake ceiling (#459 evidence, #687 size scaling). The BOOT lease
        // is clamped to the ceiling (`bootHandshakeTimeoutSeconds`) so it stays
        // strictly below the static XPC reply deadline even when an operator
        // override pushes the request/shmem value above the ceiling.
        handshakeTimeout: TimeInterval(
          PieControlLauncher.bootHandshakeTimeoutSeconds(
            requestTimeoutSeconds: requestTimeoutSeconds)),
        requestTimeoutSeconds: requestTimeoutSeconds,
        profileID: profile.id,
        daemonBindHost: daemonBindMode(),
        modelConfig: .portableResolved(servedModelID: model, modelRef: modelRef),
        defaultTokenLimit: defaultTokenLimit
      )
      // #469: record the resolved boot model in the durable active-model
      // marker. This is the single launch-resolution choke point every path
      // funnels through (App `startEngine`/`restartEngine` XPC + menu-bar
      // Resume + crash auto-relaunch), so the marker always reflects the
      // model the engine was last asked to serve — letting a later Resume on
      // a stopped engine honor the user's last pick instead of reverting to
      // the profile default. Best-effort (`try?`): a marker write failure
      // logs inside `setActiveModelID` but must never fail the launch.
      try? profileStore.setActiveModelID(model)
      return .success(spec)
    } catch {
      Self.log.error("launcher spec construction failed for profile=\(profile.id, privacy: .public): \(String(describing: error), privacy: .public)")
      return .failure(EngineError(
        code: .spawnFailed,
        message: "launcher spec construction failed: \(String(describing: error))"
      ))
    }
  }

  /// `model` is the already-resolved boot slug (`explicitModel ?? profile
  /// .model`) — see `resolveLauncherSpec`. `profile` is kept only for the
  /// error/diagnostic context.
  private func resolveModelRef(model: String,
                               profile: Profile,
                               modelsRoot: URL,
                               fileManager: FileManager = .default) -> Result<String, EngineError> {
    // Shared two-stage resolution; this method adds ONLY the memory guardrail
    // and the `modelMissing` diagnostic on top. `localPath` / `hfIdentity` /
    // `hfCacheRoot` are recomputed here purely to carry into the error builder
    // (the resolution itself lives in `resolveModelArtifact`).
    let localPath = Self.joinModelPath(modelsRoot: modelsRoot, slug: model)
    let hfIdentity = Self.hfIdentity(forModelSlug: model)
    let hfCacheRoot = hfHome()
    switch Self.resolveModelArtifact(slug: model, modelsRoot: modelsRoot,
                                     hfHome: hfCacheRoot, fileManager: fileManager) {
    case .appStaged(let path):
      if case .failure(let err) = ModelMemoryGuardrail.validate(
        resolvedModelURL: URL(fileURLWithPath: path, isDirectory: false),
        modelID: model,
        policy: memoryPolicy(),
        fileManager: fileManager
      ) {
        return .failure(err)
      }
      return .success(path)
    case .hfCache(let cached):
      if case .failure(let err) = ModelMemoryGuardrail.validate(
        resolvedModelURL: cached,
        modelID: model,
        policy: memoryPolicy(),
        fileManager: fileManager
      ) {
        return .failure(err)
      }
      return .success(cached.path)
    case .notResolvable(.appStagedInvalid(let reason)):
      return .failure(Self.modelMissingError(
        profile: profile,
        model: model,
        appPath: localPath,
        appPathProblem: reason,
        hfIdentity: hfIdentity,
        hfHome: hfCacheRoot
      ))
    case .notResolvable(.hfInvalid(let problem)):
      return .failure(Self.modelMissingError(
        profile: profile,
        model: model,
        appPath: localPath,
        hfIdentity: hfIdentity,
        hfHome: hfCacheRoot,
        hfProblem: problem
      ))
    case .notResolvable(.absent):
      return .failure(Self.modelMissingError(
        profile: profile,
        model: model,
        appPath: localPath,
        hfIdentity: hfIdentity,
        hfHome: hfCacheRoot
      ))
    }
  }

  private struct AppStagedModelProblem: Error {
    let reason: String
  }

  private static func validateAppStagedModel(at path: String,
                                             fileManager: FileManager) -> Result<Bool, AppStagedModelProblem> {
    var isDir: ObjCBool = false
    guard fileManager.fileExists(atPath: path, isDirectory: &isDir) else {
      return .success(false)
    }
    if isDir.boolValue {
      return .failure(AppStagedModelProblem(reason: "is a directory, expected a model file"))
    }
    do {
      // `attributesOfItem` has lstat semantics (no symlink follow), so a
      // staged symlink reports `.typeSymbolicLink`. The outer
      // `fileExists(isDirectory:)` above DID follow the link and already
      // confirmed the target exists and is not a directory — so a symlink
      // reaching here points at a regular model file.
      let attrs = try fileManager.attributesOfItem(atPath: path)
      if let type = attrs[.type] as? FileAttributeType {
        switch type {
        case .typeRegular:
          break  // a plainly-staged GGUF
        case .typeSymbolicLink:
          // Accept a staged symlink-to-regular (e.g. `stage-test-model.sh`
          // links the HF cache, or a user `ln -s`'d a GGUF). Return the
          // SYMLINK path (the caller's `localPath`) unchanged: pie follows
          // it and the `.gguf` suffix is preserved, whereas the resolved
          // blob would be an extension-less path pie rejects. Previously
          // this hard-failed → `modelMissing`, which ALSO skipped the
          // HF-cache fallback even when the cache held the model (the
          // operator's real blocker). Pre-existing, not #413.
          break
        default:
          return .failure(AppStagedModelProblem(
            reason: "is \(type.rawValue), expected a regular model file"
          ))
        }
      }
    } catch {
      return .failure(AppStagedModelProblem(
        reason: "cannot inspect app-staged model: \(error.localizedDescription)"
      ))
    }
    //  F10: surface an unverified model at LOAD time, not just at
    // download. A durable `<file>.unverified` sidecar means the GGUF
    // was placed without a sha256 integrity check (e.g. a resumed
    // download). Log at `.notice` (default-persisted, greppable) so an
    // operator sees the file is being loaded unverified — the resolve
    // still succeeds (surface-not-block, per the operator decision).
    if fileManager.fileExists(atPath: path + InstalledModels.unverifiedSuffix) {
      log.notice("load: app-staged model is UNVERIFIED (sha256 not checked, .unverified sidecar present) — \(path, privacy: .public)")
    }
    return .success(true)
  }

  /// The outcome of locating a model slug's on-disk artifact, WITHOUT the
  /// memory-guardrail check — the single source of truth for the launcher's
  /// two-stage resolution. `resolveModelRef` layers the guardrail + `ModelRef`
  /// on top of it; `isModelResolvable` reduces it to a Bool. Sharing this
  /// result is what stops the launcher and the send-gate from drifting apart.
  private enum ModelArtifactResolution {
    /// Found in Rational's app-staged models dir at `path` (a regular file or
    /// a symlink to one).
    case appStaged(path: String)
    /// Found in the HuggingFace cache at `url` (a file or a snapshot dir).
    case hfCache(url: URL)
    /// Not loadable from either source; carries why so the launcher can build
    /// the matching `modelMissing` diagnostic.
    case notResolvable(NotResolvable)

    enum NotResolvable {
      /// An artifact EXISTS at the expected app-staged path but is invalid
      /// (a directory, a broken/wrong-type file). The launch stops here and
      /// does NOT fall through to the HF cache.
      case appStagedInvalid(reason: String)
      /// The HF cache holds the repo but the snapshot is incomplete/corrupt.
      case hfInvalid(HFCacheResolver.CacheProblem)
      /// Present in neither source — an app-staged miss plus an HF miss (or no
      /// HF identity could be derived from the slug).
      case absent
    }
  }

  /// The launcher's two-stage existence resolution, shared verbatim by
  /// `resolveModelRef` and `isModelResolvable`. App-staged path first; a
  /// present-but-INVALID staged artifact stops here with no HF fallthrough
  /// (exactly as a real launch fails), while an app-staged MISS falls through
  /// to the HF cache. Existence only — no `ModelMemoryGuardrail`, no directory
  /// creation, no xattr writes — so it is safe on the SwiftUI render path.
  /// `hfHome == nil` skips the HF stage.
  private static func resolveModelArtifact(slug: String,
                                           modelsRoot: URL,
                                           hfHome: URL?,
                                           fileManager: FileManager) -> ModelArtifactResolution {
    let localPath = joinModelPath(modelsRoot: modelsRoot, slug: slug)
    switch validateAppStagedModel(at: localPath, fileManager: fileManager) {
    case .success(true):
      return .appStaged(path: localPath)
    case .failure(let problem):
      return .notResolvable(.appStagedInvalid(reason: problem.reason))
    case .success(false):
      break  // not app-staged → try the HF cache
    }
    guard let hfHome, let identity = hfIdentity(forModelSlug: slug) else {
      return .notResolvable(.absent)
    }
    switch HFCacheResolver(hfHome: hfHome, fileManager: fileManager)
      .resolve(repo: identity.repo, file: identity.file) {
    case .hit(let cached):
      return .hfCache(url: cached)
    case .miss:
      return .notResolvable(.absent)
    case .invalid(let problem):
      return .notResolvable(.hfInvalid(problem))
    }
  }

  /// Read-only check of whether `slug` resolves to an on-disk model artifact
  /// through the launcher's own two-stage resolution (`resolveModelArtifact`):
  /// the app-staged models dir, else the HuggingFace cache. Consumes the SAME
  /// resolution core as `resolveModelRef`, MINUS the `ModelMemoryGuardrail`
  /// step — a present-but-too-large model is a load-time `.memoryRisk`, not a
  /// missing one, so existence is the right question for an availability gate.
  /// Performs no directory creation and no xattr writes, so it is safe to call
  /// on the SwiftUI render path.
  ///
  /// The send-gate (`ChatScaffoldView.isModelInstalled`) consults this so a
  /// genuinely-loadable HF-cached model (e.g. a safetensors snapshot) is
  /// offered Load instead of being misreported "isn't available".
  public static func isModelResolvable(slug: String,
                                       modelsRoot: URL,
                                       hfHome: URL?,
                                       fileManager: FileManager = .default) -> Bool {
    switch resolveModelArtifact(slug: slug, modelsRoot: modelsRoot,
                                hfHome: hfHome, fileManager: fileManager) {
    case .appStaged, .hfCache:
      return true
    case .notResolvable:
      return false
    }
  }

  /// Effective boot model: the user's explicit per-start selection when
  /// present (blank/whitespace ignored), otherwise the profile's persisted
  /// default. `nil` means neither is set → `noDefaultModelError`. Returns the
  /// chosen value verbatim (not trimmed) so the on-disk slug path is
  /// preserved exactly as the picker/profile recorded it.
  static func effectiveModel(explicitModel: String?, profileModel: String?) -> String? {
    if let e = explicitModel,
       !e.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return e
    }
    if let p = profileModel,
       !p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return p
    }
    return nil
  }

  private static func modelMissingError(profile: Profile,
                                        model: String,
                                        appPath: String,
                                        appPathProblem: String? = nil,
                                        hfIdentity: (repo: String, file: String?)?,
                                        hfHome: URL,
                                        hfProblem: HFCacheResolver.CacheProblem? = nil) -> EngineError {
    var parts = [
      "model missing for profile \(profile.id.debugDescription): \(model.debugDescription)",
      "checked app-staged path \(appPath)",
    ]
    if let appPathProblem {
      parts.append("app-staged model invalid: \(appPathProblem)")
    }
    if let hfIdentity {
      parts.append("checked HF cache \(hfHome.appendingPathComponent("hub").path) for \(hfIdentity.repo)")
      if let hfProblem {
        parts.append("HF cache invalid at \(hfProblem.path): \(hfProblem.reason)")
      }
      parts.append("recovery: run `\(downloadCommand(for: hfIdentity))` or import/stage the model at \(appPath)")
    } else {
      parts.append("no HF fallback is known for this model slug")
      parts.append("recovery: import/stage a GGUF at \(appPath)")
    }
    return EngineError(code: .modelMissing, message: parts.joined(separator: "; "))
  }

  private static func noDefaultModelError(profile: Profile) -> EngineError {
    EngineError(
      code: .modelMissing,
      message: "profile \(profile.id.debugDescription) has no default model; choose or download a model before starting"
    )
  }

  private static func downloadCommand(for identity: (repo: String, file: String?)) -> String {
    if let file = identity.file, file.lowercased().hasSuffix(".gguf") {
      return "huggingface-cli download \(identity.repo) --include \"\(file)\""
    }
    return "pie model download \(identity.repo)"
  }

  static func hfIdentity(forModelSlug slug: String) -> (repo: String, file: String?)? {
    if slug == ProfileStore.defaultChatModelID {
      return (repo: ProfileStore.defaultChatHFRepoID, file: nil)
    }
    let segments = slug
      .split(separator: "/", omittingEmptySubsequences: true)
      .map(String.init)
    guard segments.count >= 2 else { return nil }
    let repo = "\(segments[0])/\(segments[1])"
    let file = segments.count > 2
      ? segments.dropFirst(2).joined(separator: "/")
      : nil
    return (repo: repo, file: file)
  }

  /// Resolve `profile.inferlet` into the `name@version` wire selector
  /// that `PieControlClient.launchDaemon` expects, using the manifest
  /// that `PieControlLauncher` will upload immediately before daemon
  /// launch. Bare profile names stay backward-compatible by deriving
  /// the version from the installed manifest; already-qualified names
  /// pass through only when they exactly identify that same manifest.
  /// Mismatches fail before launch so the helper never installs
  /// `chat-apc` and then asks pie to start an uninstalled program.
  static func inferletNameAtVersion(profileInferlet raw: String,
                                    manifestURL: URL) -> Result<String, EngineError> {
    let package: (name: String, version: String)
    switch inferletManifestPackage(at: manifestURL) {
    case .success(let parsed): package = parsed
    case .failure(let err):    return .failure(err)
    }

    let qualifiedManifestName = "\(package.name)@\(package.version)"
    if raw.contains("@") {
      guard Self.matches(raw, pattern: inferletNameAtVersionPattern) else {
        return .failure(invalidInferletError(raw))
      }
      guard raw == qualifiedManifestName else {
        return .failure(mismatchedInferletError(
          profileInferlet: raw,
          installedInferlet: qualifiedManifestName,
          manifestURL: manifestURL
        ))
      }
      return .success(raw)
    }

    guard Self.matches(raw, pattern: inferletNamePattern) else {
      return .failure(invalidInferletError(raw))
    }
    guard raw == package.name else {
      return .failure(mismatchedInferletError(
        profileInferlet: raw,
        installedInferlet: qualifiedManifestName,
        manifestURL: manifestURL
      ))
    }
    return .success(qualifiedManifestName)
  }

  private static func inferletManifestPackage(at manifestURL: URL) -> Result<(name: String, version: String), EngineError> {
    let table: TOMLTable
    do {
      table = try TOMLTable(string: String(contentsOf: manifestURL, encoding: .utf8))
    } catch {
      return .failure(EngineError(
        code: .spawnFailed,
        message: "inferlet manifest resolution failed at \(manifestURL.path): \(String(describing: error))"
      ))
    }
    guard let package = table["package"]?.table else {
      return .failure(EngineError(
        code: .spawnFailed,
        message: "inferlet manifest missing [package] table at \(manifestURL.path)"
      ))
    }
    guard let name = package["name"]?.string else {
      return .failure(EngineError(
        code: .spawnFailed,
        message: "inferlet manifest missing [package].name at \(manifestURL.path)"
      ))
    }
    guard let version = package["version"]?.string else {
      return .failure(EngineError(
        code: .spawnFailed,
        message: "inferlet manifest missing [package].version at \(manifestURL.path)"
      ))
    }
    return .success((name: name, version: version))
  }

  private static func invalidInferletError(_ raw: String) -> EngineError {
    EngineError(
      code: .invalidInput,
      message: "profile.inferlet must be `<name>` or `<name>@<major>.<minor>.<patch>` (e.g. `chat-apc` or `chat-apc@0.1.0`); got \(raw.debugDescription)"
    )
  }

  private static func mismatchedInferletError(profileInferlet: String,
                                             installedInferlet: String,
                                             manifestURL: URL) -> EngineError {
    EngineError(
      code: .invalidInput,
      message: "profile.inferlet \(profileInferlet.debugDescription) does not match installed inferlet \(installedInferlet.debugDescription) from \(manifestURL.path)"
    )
  }

  private static func matches(_ raw: String, pattern: NSRegularExpression) -> Bool {
    let range = NSRange(raw.startIndex..., in: raw)
    return pattern.numberOfMatches(in: raw, range: range) == 1
  }

  private static let inferletNamePattern: NSRegularExpression = {
    // swiftlint:disable:next force_try
    try! NSRegularExpression(pattern: #"^[A-Za-z0-9_-]+$"#)
  }()

  /// `^[A-Za-z0-9_-]+@\d+\.\d+\.\d+$` — wire format for
  /// `launch_daemon`'s `inferlet` arg. NSRegularExpression with
  /// explicit anchors, not a regex literal, so the pattern lives in
  /// a `static let` without triggering the `/.../` comment-start
  /// parsing ambiguity at type scope.
  private static let inferletNameAtVersionPattern: NSRegularExpression = {
    // swiftlint:disable:next force_try
    try! NSRegularExpression(pattern: #"^[A-Za-z0-9_-]+@[0-9]+\.[0-9]+\.[0-9]+$"#)
  }()

  /// `/pie_helper_<pid>_<8 hex>` — POSIX shmem names are bounded
  /// (PSHMNAMLEN ≈ 31 on Darwin including the leading slash), so we
  /// keep the prefix short and the random suffix to 8 hex digits.
  /// `pie-driver-portable` (and any single-shard driver) appends
  /// `_g0` before `shm_open`; `LaunchedSession.shmUnlinkQuiet`
  /// unlinks both base + `_g0` shards.
  static func uniqueShmemName() -> String {
    let pid = ProcessInfo.processInfo.processIdentifier
    let suffix = UUID().uuidString
      .replacingOccurrences(of: "-", with: "")
      .lowercased()
      .prefix(8)
    return "/pie_helper_\(pid)_\(suffix)"
  }

  // MARK: - path composition

  /// Join `modelsRoot` with a model slug that may be either a bare
  /// filename (`llama-3.1-8b.gguf`) or a multi-segment downloader
  /// layout (`<repo>/<file>`, e.g. `TheBloke/Llama-2-7B-Chat-GGUF/
  /// llama-2-7b.gguf`). The single-call form
  /// `modelsRoot.appendingPathComponent(slug)` percent-escapes
  /// embedded `/` as `%2F` on recent Foundation versions, producing
  /// `modelsRoot/repo%2Ffile` (review v150 F8). Split + chain so each
  /// segment is appended as a discrete path component.
  ///
  /// Internal-visibility so `LaunchSpecResolverTests` can pin the
  /// join shape without poking at `resolve()`'s private intermediate
  /// values.
  static func joinModelPath(modelsRoot: URL, slug: String) -> String {
    let segments = slug
      .split(separator: "/", omittingEmptySubsequences: true)
      .map(String.init)
    var url = modelsRoot
    for segment in segments {
      url = url.appendingPathComponent(segment, isDirectory: false)
    }
    return url.path
  }

  public static func defaultHFHome(environment: [String: String] = ProcessInfo.processInfo.environment,
                                   homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
    if let raw = environment["HF_HOME"], !raw.isEmpty {
      return URL(fileURLWithPath: raw, isDirectory: true)
    }
    return homeDirectory
      .appendingPathComponent(".cache", isDirectory: true)
      .appendingPathComponent("huggingface", isDirectory: true)
  }

  // MARK: - private

  private func lookup(profileID: String) -> Profile? {
    profileStore.entries
      .compactMap(\.profile)
      .first { $0.id == profileID }
  }
}

extension LaunchSpecResolver {
  /// Production binary lookup: `<Rational.app>/Contents/Resources/pie-engine/pie`.
  /// Walks parent `.app` bundles so the embedded `RationalHelper.app` finds
  /// the engine shipped with its containing `Rational.app`. Mirrors
  /// `InferletResources.candidateBundles` (Phase 5.5 ).
  ///
  /// Throws `LaunchSpecResolver.BinaryMissing` when no candidate
  /// resolves — the launcher would otherwise surface `Process.run()
  /// failed` with a confusing path; surfacing the structured error here
  /// lets the GUI render "Pie engine binary is missing — reinstall".
  public struct BinaryMissing: Error, CustomStringConvertible {
    public let searched: [String]
    public var description: String {
      "LaunchSpecResolver: pie engine binary not found (searched: \(searched.joined(separator: ", ")))"
    }
  }

  public static func bundledPieBinary(in bundle: Bundle = .main) throws -> URL {
    let candidates = candidateBundles(starting: bundle)
    var searched: [String] = []
    for b in candidates {
      let url = b.bundleURL
        .appendingPathComponent("Contents/Resources/pie-engine/pie",
                                isDirectory: false)
      searched.append(url.path)
      if FileManager.default.isExecutableFile(atPath: url.path) {
        return url
      }
    }
    throw BinaryMissing(searched: searched)
  }

  /// Maximum ancestor levels the bundle walk inspects looking for a
  /// parent `.app`. Canonical embed layout is
  /// `Rational.app/Contents/Library/LoginItems/RationalHelper.app` — four
  /// `deletingLastPathComponent()` hops from the helper bundle to
  /// reach `Rational.app`. The prior `0..<3` bound stopped at
  /// `Rational.app/Contents` and silently fell through to the
  /// helper-bundle-only candidate, so the engine binary lookup never
  /// considered the containing `Rational.app` (review v150 F6).
  ///
  /// Matches `HelperAppDelegate.pieAppAncestorMaxDepth = 6` (two
  /// extra levels of headroom for a future versioned LoginItems
  /// subdir).
  static let bundleWalkMaxDepth = 6
  private static let xcodeSiblingAppName = "Rational.app"

  /// Same walk as `InferletResources.candidateBundles` — kept private
  /// here so the binary lookup does not depend on the inferlet bundling
  /// API surface evolving.
  private static func candidateBundles(starting bundle: Bundle) -> [Bundle] {
    var out: [Bundle] = []
    var seen = Set<String>()

    func appendBundle(at url: URL) {
      let key = url.standardizedFileURL.path
      guard !seen.contains(key),
            url.pathExtension == "app",
            let candidate = Bundle(url: url) else { return }
      seen.insert(key)
      out.append(candidate)
    }

    appendBundle(at: bundle.bundleURL)
    var url = bundle.bundleURL
    for _ in 0..<bundleWalkMaxDepth {
      // Xcode UI tests launch the RatioThinkHelper target as a standalone
      // sibling of Rational.app, while production launches the helper from
      // Rational.app/Contents/Library/LoginItems. Check the sibling app as
      // well as ancestor apps so both layouts resolve the single
      // app-bundled pie engine.
      appendBundle(at: url.deletingLastPathComponent()
        .appendingPathComponent(xcodeSiblingAppName, isDirectory: true))
      url = url.deletingLastPathComponent()
      if url.pathExtension == "app" {
        appendBundle(at: url)
        break
      }
      if url.path == "/" { break }
    }
    return out
  }
}
