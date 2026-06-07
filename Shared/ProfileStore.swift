import Foundation
import Combine
import Darwin
import os

/// Snapshot of one `*.toml` file in the profiles directory.
///
///   · `profile != nil` AND `error == nil` — parsed cleanly.
///   · `profile == nil` AND `error != nil` — top-level parse or
///     required-field failure; the file is unusable.
///   · `warnings` lists per-section shape mismatches found via
///     `Profile.sectionWarnings()`. Present even when `profile != nil`
///     (per plan §2.4: forward-compat v2 sections load as warnings
///     rather than rejecting the whole profile).
public struct ProfileLoadResult {
  public let url: URL
  public let profile: Profile?
  public let error: ProfileError?
  public let warnings: [ProfileSectionWarning]

  public init(
    url: URL,
    profile: Profile?,
    error: ProfileError?,
    warnings: [ProfileSectionWarning]
  ) {
    self.url      = url
    self.profile  = profile
    self.error    = error
    self.warnings = warnings
  }

  public var isValid: Bool { profile != nil && error == nil }
}

/// Errors raised by `ProfileStore`. Three categories:
///
///   · Lifecycle (`.openFailed`, `.alreadyStarted`) — thrown out of
///     `start()`; the store never ran.
///   · Directory-level (`.seedFailed`, `.scanFailed`) — surfaced via
///     `ProfileStoreSnapshot.directoryError` AND every listener
///     callback so the UI can render the real cause instead of an
///     ambiguous empty profile list (review v1 F3+F4).
///
/// Per-file parse failures are surfaced through
/// `ProfileLoadResult.error`, not these.
public enum ProfileStoreError: Error, CustomStringConvertible, Equatable {
  case openFailed(path: String, errno: Int32)
  case alreadyStarted
  case seedFailed(path: String, underlying: String)
  case scanFailed(path: String, underlying: String)
  /// Reading the persisted active-profile marker (`activeProfileURL`)
  /// failed for a reason other than "file is absent". Permission
  /// denied, path-is-a-directory, UTF-8 decode failure, IO error —
  /// every case surfaced here so HelperResumeAction can render a
  /// distinct outcome instead of silently treating the helper as
  /// having no selection (review cycle 149/150 F1).
  case activeProfileReadFailed(path: String, underlying: String)
  /// Writing the seeded active-profile marker on first launch failed
  /// ( review v1 F2). Surfaced via `lastActiveProfileError`
  /// + snapshot so a listener can render an actionable banner;
  /// logging-only would re-introduce the silent-no-op the fix
  /// addresses — `start()` would commit `.absent` and HelperResumeAction
  /// would see the bug-pattern state (id=nil, error=nil) again.
  case activeProfileSeedFailed(path: String, underlying: String)
  /// `Profile.dump()` threw while serializing a profile in
  /// `createProfile(_:filename:)`. Wraps the underlying
  /// `ProfileError.parseFailure` message so the caller (and the
  /// future GUI surface) sees the precise cause instead of a
  /// generic write failure. Review v3 F3.
  case dumpFailed(path: String, underlying: String)
  /// `setModel(_:forProfileID:)` was asked to write a model onto a
  /// profile id that is absent or failed to parse. Surfaced so
  /// the caller never silently no-ops a "set as default" write.
  case profileNotFound(id: String)

  public var description: String {
    switch self {
    case let .openFailed(path, e):
      return "ProfileStore open(\(path)) failed: errno=\(e) (\(String(cString: strerror(e))))"
    case .alreadyStarted:
      return "ProfileStore.start() called twice"
    case let .seedFailed(path, underlying):
      return "ProfileStore seed write to \(path) failed: \(underlying)"
    case let .scanFailed(path, underlying):
      return "ProfileStore scan of \(path) failed: \(underlying)"
    case let .activeProfileReadFailed(path, underlying):
      return "ProfileStore active-profile read at \(path) failed: \(underlying)"
    case let .activeProfileSeedFailed(path, underlying):
      return "ProfileStore active-profile seed write at \(path) failed: \(underlying)"
    case let .dumpFailed(path, underlying):
      return "ProfileStore dump for \(path) failed: \(underlying)"
    case let .profileNotFound(id):
      return "ProfileStore has no editable profile with id=\(id)"
    }
  }
}

/// Bundles the list of parsed profiles with the most recent
/// directory-level error so listeners can distinguish "no profiles
/// found" from "could not read the profiles directory" (review v1 F3,
/// F4). UI code should render `directoryError` when non-nil rather
/// than the empty-state placeholder.
///
/// `directoryError` priority (newest signal wins):
///   1. `.scanFailed` — most recent reload could not enumerate the
///      directory (deleted under us, perms revoked, etc.).
///   2. `.seedFailed` — first-launch chat seed write failed AND the
///      directory is still empty. Cleared as soon as a scan finds at
///      least one `*.toml` (user / external process repaired it).
///   3. `.seedFailed` — the existence-gated built-in (Fast Think) seed
///      write failed (review v1 F1). Surfaces regardless of whether the
///      directory has other profiles, since the built-in is seeded into
///      populated installs; not cleared by a non-empty scan.
///   4. `nil` — clean.
public struct ProfileStoreSnapshot {
  public let entries: [ProfileLoadResult]
  public let directoryError: ProfileStoreError?
  /// Set when the persisted active-profile marker could not be read
  /// for a reason other than "absent". Independent of
  /// `directoryError` because the marker lives outside `directory`
  /// and an unreadable selection file does not invalidate the
  /// profile listing itself.
  public let activeProfileError: ProfileStoreError?
  /// Currently-selected profile id at the moment the snapshot was
  /// built. Exposed on the snapshot (in addition to `ProfileStore.
  /// activeProfileID`) so callers of `reloadActiveProfile()` can
  /// make a decision on the post-retry state from one race-free
  /// read (review v5 F5). Polling `store.activeProfileID` after the
  /// reload races against a concurrent FS event that could mutate
  /// the property between the two observations.
  public let activeProfileID: String?

  public init(entries: [ProfileLoadResult],
              directoryError: ProfileStoreError?,
              activeProfileError: ProfileStoreError? = nil,
              activeProfileID: String? = nil) {
    self.entries            = entries
    self.directoryError     = directoryError
    self.activeProfileError = activeProfileError
    self.activeProfileID    = activeProfileID
  }
}

/// Minimal profile identity shown when a model delete would clear one
/// or more profile defaults.
public struct ProfileModelReference: Equatable, Sendable {
  public let id: String
  public let name: String

  public init(id: String, name: String) {
    self.id = id
    self.name = name
  }
}

public enum ProfileModelDefaultsRollbackState: Equatable, Sendable, CustomStringConvertible {
  case notNeeded
  case succeeded
  case failed(String)

  public var description: String {
    switch self {
    case .notNeeded:
      return "no profile defaults needed restoration"
    case .succeeded:
      return "profile defaults were restored"
    case .failed(let reason):
      return "profile defaults could not be fully restored: \(reason)"
    }
  }
}

public struct ProfileModelDefaultsOperationResult<Output> {
  public let affectedProfiles: [ProfileModelReference]
  public let output: Output

  public init(affectedProfiles: [ProfileModelReference], output: Output) {
    self.affectedProfiles = affectedProfiles
    self.output = output
  }
}

public enum ProfileModelDefaultsTransactionError: Error, CustomStringConvertible {
  case clearFailed(
    modelID: String,
    cleared: [ProfileModelReference],
    underlying: String,
    rollback: ProfileModelDefaultsRollbackState
  )
  case operationFailed(
    modelID: String,
    cleared: [ProfileModelReference],
    underlying: String,
    rollback: ProfileModelDefaultsRollbackState
  )

  public var description: String {
    switch self {
    case .clearFailed(let modelID, let cleared, let underlying, let rollback):
      return "Clearing profile defaults for \(modelID) failed after \(cleared.count) profile(s) changed: \(underlying); \(rollback)"
    case .operationFailed(let modelID, let cleared, let underlying, let rollback):
      return "Model operation for \(modelID) failed after clearing \(cleared.count) profile default(s): \(underlying); \(rollback)"
    }
  }
}

private struct ProfileModelDefaultTarget {
  let profile: Profile
  let filename: String
  let reference: ProfileModelReference
}

/// Watches `~/Library/Application Support/RatioThink/profiles/` (or any
/// directory passed at init) via `DispatchSource.makeFileSystemObject
/// Source`. Reloads on change, parses each `*.toml` file, surfaces
/// per-section v2 warnings, and seeds a default `chat.toml` on first
/// launch when the directory is empty.
///
/// Threading: all callback invocations and internal state mutations
/// run on the store's serial `DispatchQueue`. Listeners receive
/// snapshots — no shared mutable state escapes.
///
/// Lifecycle: `start()` opens the directory fd + installs the
/// watcher; `stop()` (and `deinit`) tear it down. Re-`start()`-ing a
/// stopped store is allowed.
/// `ObservableObject` conformance is for SwiftUI ownership
/// (`@StateObject`/`@EnvironmentObject`) only. The store publishes no
/// `@Published` state — its synthesized `objectWillChange` never fires;
/// consumers observe updates through `addListener(_:)` and re-read
/// `snapshot`/`entries` imperatively. This keeps the off-main FS-watcher
/// mutations off SwiftUI's main-actor publish path.
public final class ProfileStore: ObservableObject {
  public let directory: URL

  /// On-disk location of the persisted active-profile id. One line of
  /// UTF-8 text holding the id of the currently selected profile, or
  /// the file is absent when no selection has been made.
  ///
  /// Lives outside `directory` (alongside `profiles/`) so the FS
  /// watcher's `*.toml` scan is unaffected by selection writes. Tests
  /// inject a custom URL; production defaults to
  /// `directory.deletingLastPathComponent()/active-profile`.
  public let activeProfileURL: URL

  /// Debounce window for FS-event coalescing. The system fires
  /// multiple `.write` events for a single `mv tmp final.toml`
  /// rename; coalescing avoids a thundering-herd of rescans.
  public var debounceInterval: DispatchTimeInterval = .milliseconds(50)

  /// Default `chat.toml` written on first launch when the profiles
  /// directory is empty. Public so tests and Settings UI can show the
  /// exact bytes the user will see on disk.
  ///  review v2 F1: the seeded default is the `<repo>/<file>` SLUG
  /// the downloader writes and `LaunchSpecResolver.joinModelPath`
  /// resolves — NOT a bare leaf name. `ModelDownloader.start(repo:file:)`
  /// writes to `<modelsRoot>/<repo>/<file>`, so the seeded slug must be
  /// that same relative path for "Load the active profile's default" to
  /// resolve the file the recommended curated starter downloads. A bare
  /// leaf name joins to a flat top-level path and misses.
  /// `CuratedModelCatalogTests` pins the resolution invariant
  /// (joined path == download destination). UI renders the friendly
  /// leaf via `ModelDisplayName.leaf`, never this raw slug.
  public static let defaultChatModelID = "Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf"
  /// HF repo the seeded default lives in — the SAME repo the recommended
  /// curated entry downloads from. Used by the resolver's HF-cache
  /// fallback (`LaunchSpecResolver.hfIdentity`) when the model is not
  /// staged in RatioThink's app models directory.
  public static let defaultChatHFRepoID = "Qwen/Qwen3-0.6B-GGUF"

  public static let defaultChatTOML: String = """
  id = "chat"
  name = "Chat"
  icon = "bubble.left.and.bubble.right"
  model = "\(defaultChatModelID)"
  inferlet = "chat-apc"
  system_prompt = "You are a helpful assistant."

  [sampling]
  temperature = 0.7
  top_p = 0.9
  max_tokens = 2048

  """

  /// Filename written by `seedDefaultsIfEmpty()` on first launch.
  public static let defaultChatFilename = "chat.toml"

  /// Example tree-of-thought profile (#413) seeded alongside `chat.toml`
  /// on first launch so the live tree-search feature is reachable: the
  /// user just switches to it. Reuses the same default model + the
  /// `chat-apc` inferlet (ToT is a per-request dispatch mode, not a
  /// separate wasm); `inferlet_args.mode = "tree-of-thought"` is what
  /// `Profile.treeOfThought` keys on, and the breadth/depth/beam_width
  /// are the bounded search shape (server-validated). The profiles editor
  /// only displays `inferlet_args`, so seeding the file is how a user gets
  /// a ToT profile without hand-editing TOML.
  public static let treeOfThoughtFilename = "tree-of-thought.toml"
  public static let treeOfThoughtTOML: String = """
  id = "tree-of-thought"
  name = "Tree of Thought"
  icon = "point.3.connected.trianglepath.dotted"
  model = "\(defaultChatModelID)"
  inferlet = "chat-apc"
  system_prompt = "You are a helpful assistant."

  [sampling]
  temperature = 0.7
  top_p = 0.9
  max_tokens = 2048

  [inferlet_args]
  mode = "tree-of-thought"
  breadth = 3
  depth = 2
  beam_width = 2
  max_tokens_per_node = 256

  """

  /// Profile id encoded in `defaultChatTOML`. Also the value written
  /// to the `activeProfileURL` marker on first launch:
  /// without seeding the marker the menu-bar Resume click is a silent
  /// no-op on fresh installs.
  public static let defaultProfileID = "chat"

  /// Built-in "Fast Think" profile id (#426). A second seeded profile that
  /// turns on the chat-apc speculative drafter. Greedy by definition
  /// (temperature 0) so drafting actually engages — see
  /// `ChatSendController.makeRequest`.
  public static let defaultFastThinkProfileID = "fast-think"

  /// Filename for the seeded Fast Think profile.
  public static let defaultFastThinkFilename = "fast-think.toml"

  /// Seed body for the Fast Think profile. Same model + inferlet as the
  /// default Chat profile (so selecting it is a silent same-model swap,
  /// no reload), but greedy (`temperature = 0`) with `[speculation]`
  /// enabled. `leader_len`/`draft_len` are omitted so the inferlet applies
  /// its #418 defaults (1 / 3).
  public static let defaultFastThinkTOML: String = """
  id = "fast-think"
  name = "Fast Think"
  icon = "bolt"
  model = "\(defaultChatModelID)"
  inferlet = "chat-apc"
  system_prompt = "You are a helpful assistant."

  [sampling]
  temperature = 0.0
  top_p = 0.9
  max_tokens = 2048

  [speculation]
  enabled = true

  """

  private let queue: DispatchQueue
  /// Per-instance specific key so any method can detect whether the
  /// current thread is already running on THIS store's `queue`
  /// before doing `queue.sync` — reentrancy from a listener callback
  /// or from `createProfile`-after-reload would otherwise deadlock
  /// the serial queue. Must be `let` per-instance, not `static`, so
  /// two `ProfileStore`s in the same process do not alias each
  /// other's reentry probe.
  private let queueKey = DispatchSpecificKey<Void>()
  private var fd: Int32 = -1
  private var source: DispatchSourceFileSystemObject?
  private var debounceItem: DispatchWorkItem?
  private var _entries: [ProfileLoadResult] = []
  private var _lastSeedError: ProfileStoreError?
  private var _lastScanError: ProfileStoreError?
  /// Write failure from the existence-gated built-in (Fast Think) seed
  /// (review v1 F1). Distinct from `_lastSeedError` (the empty-dir chat
  /// seed): the built-in is seeded into installs that ALREADY have
  /// profiles, so its failure must surface even when `_entries` is
  /// non-empty — and must NOT be cleared by a successful scan the way
  /// the empty-dir seed error is. Self-clears on the next `start()` whose
  /// seed succeeds (set fresh every start), and on `stop()`.
  private var _builtinSeedError: ProfileStoreError?
  private var _activeProfileID: String?
  private var _activeProfileError: ProfileStoreError?
  /// Listener fan-out invariant (review v6 F7).
  ///
  ///   · `reloadLocked` (FS-watcher rescan path) fires listeners
  ///     SYNCHRONOUSLY inline on `queue`.
  ///   · `setActiveProfileID` / `clearActiveProfileID` /
  ///     `reloadActiveProfile` fire listeners ASYNCHRONOUSLY via
  ///     `queue.async { cb(snap) }`.
  ///
  /// Post-cycle-188 architectural decoupling: `reloadLocked` no
  /// longer touches the active-profile marker, so a listener
  /// triggering another mutating call (createProfile, set/clear,
  /// reloadActiveProfile) does not re-enter the same code path. The
  /// pre-cycle-188 `_reloadInFlight` reentrancy guard is therefore
  /// removed.
  ///
  /// IMPORTANT contract regression flagged by review v7 F3: the
  /// removed guard previously turned reentrant calls into a logged
  /// short-circuit. Post-cycle-188 a listener that UNCONDITIONALLY
  /// calls `createProfile()` (or any other path that synchronously
  /// re-enters `reloadLocked` via `performOnQueue`) will recurse
  /// until SIGSEGV. Listeners that mutate store state inside their
  /// callback MUST observe one-shot semantics (a `fired` flag, a
  /// dedupe set, or an equivalent gate). `createProfile`'s
  /// `reloadLocked` fan-out is the stack-overflow risk;
  /// `reloadActiveProfile`'s async fan-out is bounded per-tick but
  /// produces an unbounded queue-tick storm under the same listener
  /// shape. A DEBUG-only recursion-depth canary in `reloadLocked`
  /// (see `Self.debugReloadDepthThreshold`) emits a `Log.store.error`
  /// to surface the violation under tests / dev builds without
  /// re-introducing the runtime guard.
  private var listeners: [((ProfileStoreSnapshot) -> Void)] = []
  private let stateLock = NSLock()

  /// Recursion-depth canary for `reloadLocked` (review v7 F3 → v8 F1).
  /// Increments on entry, decrements via `defer`. At
  /// `reloadDepthThreshold` we log `Log.store.error` AND short-circuit
  /// the fan-out — preventing the SIGSEGV that a misbehaving
  /// listener-from-listener `createProfile` loop would otherwise hit
  /// in production. The per-reload cost (one `withLock` + compare)
  /// is negligible against the syscalls `scanDirectory` already
  /// performs.
  private var _reloadDepth = 0
  internal static let reloadDepthThreshold = 4
  /// Set by the short-circuit branch; consumed by the outermost
  /// reloadLocked's defer when `_reloadDepth` returns to 0 (review
  /// v10 F3). Triggers exactly one listener fan-out with the final
  /// post-recursion snapshot so non-recursive listeners (status-bar
  /// UI, telemetry) attached for unrelated reasons get their
  /// immediate-visibility contract honored even when an unrelated
  /// recursive chain happened to short-circuit the fan-out.
  private var _pendingPostRecursionFanOut = false
  /// Snapshot captured at the moment the short-circuit branch fires
  /// (review v11 F1). Pre-v11 the depth-0 defer constructed a FRESH
  /// snapshot via `makeSnapshotLocked()` — but the unwinding stack
  /// passes through frames N-1…1 whose normal fan-out can invoke
  /// listeners that mutate `_activeProfileID` / `_entries`. The
  /// fresh snapshot would reflect those mutations, not the
  /// post-recursion-write state the deferred fan-out is supposed
  /// to deliver. Stashing the snapshot at short-circuit and
  /// delivering it verbatim at depth-0 keeps the documented "writes
  /// you missed" contract honest.
  private var _pendingPostRecursionSnapshot: ProfileStoreSnapshot?
  /// Lifecycle epoch (review v11 F2). Incremented on every
  /// `stopInternal()` call. Deferred async fan-out callbacks capture
  /// the epoch at dispatch time and check it on the queue tick
  /// before firing; a stop() between dispatch and execution shifts
  /// the epoch so stale callbacks no-op instead of delivering a
  /// pre-stop snapshot to a listener that thinks the store is torn
  /// down. Survives stop/start cycles cleanly: a fresh start does
  /// not reset the counter, only stopInternal bumps it.
  private var _lifecycleEpoch: UInt64 = 0
  /// Storage backing the locked accessor (review v10 F5). Mutated
  /// only under `stateLock`; consumers read via the
  /// `reloadShortCircuitCount` computed property below so the field
  /// is never accessed without the lock (TSAN-clean).
  ///
  /// Process-monotonic post-v11 F4 — `stopInternal()` does NOT
  /// reset the counter. A stop/start cycle preserves the cumulative
  /// signal so operators reading the canary see the lifetime count
  /// across a settings-panel reopen / helper resume, not zero.
  private var _reloadShortCircuitCount = 0
  /// Test-visible counter incremented each time `reloadLocked` short-
  /// circuits at the threshold (review v8 F1, v10 F5). Always read
  /// under `stateLock` to close the data race the pre-v10 direct
  /// `private(set)` accessor exposed.
  internal var reloadShortCircuitCount: Int {
    stateLock.withLock { _reloadShortCircuitCount }
  }

  public init(
    directory: URL,
    activeProfileURL: URL? = nil,
    queue: DispatchQueue = DispatchQueue(label: "com.ratiothink.profile-store"),
    seedsExampleProfiles: Bool = true
  ) {
    self.directory = directory
    self.activeProfileURL = activeProfileURL
      ?? directory.deletingLastPathComponent()
        .appendingPathComponent("active-profile", isDirectory: false)
    self.queue = queue
    self.seedsExampleProfiles = seedsExampleProfiles
    queue.setSpecific(key: queueKey, value: ())
  }

  /// When false, `start()` skips the #413 tree-of-thought example-profile
  /// backfill. Production defaults to true; scan/lifecycle tests that
  /// assert exact directory contents pass false to keep their fixture
  /// hermetic.
  private let seedsExampleProfiles: Bool

  /// Run `work` on `queue` exactly once: inline when the caller is
  /// already on `queue` (listener callback, post-reload work),
  /// `queue.sync` from any other thread. The reentrancy probe is
  /// load-bearing for `reloadActiveProfile()` and `createProfile()`,
  /// both of which are documented as caller-facing APIs that may be
  /// invoked from a listener (review v4 F5).
  private func performOnQueue<T>(_ work: () -> T) -> T {
    if DispatchQueue.getSpecific(key: queueKey) != nil {
      return work()
    }
    return queue.sync(execute: work)
  }

  deinit {
    stopInternal()
  }

  // MARK: - lifecycle

  /// Idempotent-by-error: throws `.alreadyStarted` if called twice
  /// without an intervening `stop()`. Creates the profiles directory
  /// if missing, seeds the default `chat.toml` when empty, performs
  /// the initial scan, then installs the dispatch source.
  ///
  /// Directory-level failures during seed or initial scan do NOT
  /// throw out of `start()` — they're recorded on the snapshot so
  /// the watcher still runs and a subsequent FS event (perm fix,
  /// dir restore) can clear the error. Lifecycle errors that prevent
  /// the watcher itself from running (`open(O_EVTONLY)`) still throw.
  public func start() throws {
    try stateLock.withLock {
      guard source == nil else { throw ProfileStoreError.alreadyStarted }

      try FileManager.default.createDirectory(at: directory,
                                              withIntermediateDirectories: true)

      let fd = open(directory.path, O_EVTONLY)
      guard fd >= 0 else {
        throw ProfileStoreError.openFailed(path: directory.path, errno: errno)
      }

      self.fd = fd
      let src = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: fd,
        eventMask: [.write, .delete, .rename, .extend, .attrib],
        queue: queue
      )
      src.setEventHandler { [weak self] in self?.scheduleReload() }
      src.setCancelHandler { [weak self] in
        guard let self else { return }
        if self.fd >= 0 {
          close(self.fd)
          self.fd = -1
        }
      }
      self.source = src
    }

    // Seed + initial marker read + initial scan happen synchronously
    // on `queue` so the first listener registration sees a
    // deterministic state without racing the first watcher event.
    //
    // Post-cycle-188 the marker is read explicitly here (one of the
    // three authoritative paths); reloadLocked itself rescans the
    // directory but does NOT touch the marker.
    queue.sync {
      let seed = self.seedDefaultsIfEmpty()
      // #413: backfill the example tree-of-thought profile if absent —
      // runs BEFORE the `reloadLocked()` scan below so the first snapshot
      // already lists it. Independent of the dir-empty seed, so existing
      // installs get it too.
      self.backfillTreeOfThoughtProfile()
      // Ensure the built-in Fast Think profile exists even on installs
      // that already seeded chat.toml (the empty-dir seed above is a no-op
      // there). Runs before `reloadLocked()` below so the initial scan
      // picks it up. (#426)
      let fastThinkSeedError = self.ensureBuiltinFastThinkProfile()
      let readResult = self.readActiveProfileIDFromDisk()
      self.stateLock.withLock {
        self._lastSeedError = seed.dirError
        // The built-in (Fast Think) seed error rides its own channel: it
        // is seeded into populated dirs, so it must surface even when
        // `_entries` is non-empty (review v1 F1) — `_lastSeedError` is
        // gated on an empty dir and cleared by the next non-empty scan.
        self._builtinSeedError = fastThinkSeedError
        self.commitActiveReadResultLocked(readResult, source: .start)
        //  review v1 F2: a marker-seed failure must NOT
        // be silent. The override below fills `_activeProfileError`
        // when the read commit left it nil (the typical case: marker
        // never written → read returns `.absent` → committed error
        // is nil, indistinguishable from the healthy "operator hasn't
        // picked yet" state).
        //
        // Review v2 F2: when the read commit ALREADY surfaced an
        // error (a separate fault hit both the seed write AND the
        // marker readback), keep the read error and log the
        // displacement. Last-writer-wins without logging would
        // silently drop a concurrent fault from the snapshot.
        if let markerErr = seed.markerError {
          if let prior = self._activeProfileError {
            Log.store.error("start: keeping read error; seed-marker error suppressed (prior=\(String(describing: prior), privacy: .public), markerErr=\(String(describing: markerErr), privacy: .public))")
          } else {
            self._activeProfileError = markerErr
          }
        }
      }
      self.reloadLocked()
    }

    source?.resume()
  }

  /// Tears the watcher down. Safe to call multiple times.
  public func stop() {
    // Review v10 F2: drain the serial queue before resetting state.
    // An in-flight `reloadLocked` may already have called
    // `scanDirectory()` unlocked and be about to re-acquire
    // `stateLock` to commit; without `queue.sync` the v9 F2 reset
    // could run BETWEEN those two steps and be silently undone when
    // the in-flight reload finally committed its results. The sync
    // hop forces the queue to drain first.
    //
    // Reentrancy: if `stop()` is invoked from a listener callback
    // (which already runs on `queue`), `queue.sync` would deadlock.
    // `queueKey` detection inlines the body in that case — matching
    // the `performOnQueue` pattern used by mutating APIs.
    if DispatchQueue.getSpecific(key: queueKey) != nil {
      stateLock.withLock { stopInternal() }
    } else {
      queue.sync { self.stateLock.withLock { self.stopInternal() } }
    }
  }

  private func stopInternal() {
    debounceItem?.cancel()
    debounceItem = nil
    if let src = source {
      src.cancel()  // cancel handler closes fd
      source = nil
    } else if fd >= 0 {
      close(fd)
      fd = -1
    }
    // Reset every piece of cached lifecycle state so a stop/start
    // sequence cannot leak prior-lifecycle observations through the
    // public `snapshot` / `entries` / `lastDirectoryError` surface.
    //
    // Review v10 F1: `_activeProfileID` and `_activeProfileError` are
    // wiped TOGETHER so the snapshot mask invariant (error nil ↔ id
    // visible) stays coherent post-stop.
    //
    // Review v10 F4: `_reloadDepth` is NOT reset here. With the v10
    // F2 queue-drain, there can be no in-flight reloadLocked whose
    // deferred decrement would underflow against a manual reset.
    //
    // Review v11 F3 / v12 F4: log at `.error` to mirror the
    // short-circuit's scheduling log severity (`Log.store.error` at
    // the rescan + stash site). Symmetric severities keep the
    // schedule-vs-cancel audit pair inside the same alerting band —
    // a production OSLog pipeline filtering at `.error` would
    // otherwise see the scheduled fire but miss the cancellation,
    // producing the exact "fire-and-forget that never fired" gap
    // F3 was scoped to close.
    if _pendingPostRecursionFanOut {
      Log.store.error("stopInternal: cancelled pending deferred post-recursion fan-out for \(self.listeners.count, privacy: .public) listener(s)")
    }
    // Review v11 F2: bump the lifecycle epoch so any async fan-out
    // callbacks already queued behind this stop() drop on the floor
    // instead of delivering a pre-stop snapshot to listeners that
    // (correctly) assume "stop ⇒ no further callbacks".
    _lifecycleEpoch &+= 1
    // Review v11 F4: do NOT reset `_reloadShortCircuitCount`. The
    // canary is process-monotonic — a transient stop/start cycle
    // (settings panel, helper resume) must not erase the lifetime
    // signal that the recursion canary ever tripped.
    _entries = []
    _lastSeedError = nil
    _lastScanError = nil
    _builtinSeedError = nil
    _activeProfileID = nil
    _activeProfileError = nil
    _pendingPostRecursionFanOut = false
    _pendingPostRecursionSnapshot = nil
  }

  // MARK: - public API

  /// Full snapshot (entries + directory-level error). Prefer this
  /// over `entries` when the UI needs to distinguish empty from
  /// broken.
  public var snapshot: ProfileStoreSnapshot {
    stateLock.withLock { makeSnapshotLocked() }
  }

  /// Convenience accessor for the entries list. Equivalent to
  /// `snapshot.entries`; does NOT surface directory-level errors —
  /// use `snapshot` or `lastDirectoryError` for that.
  public var entries: [ProfileLoadResult] {
    stateLock.withLock { _entries }
  }

  /// Convenience accessor for the current directory-level error
  /// (nil when clean). Same value as `snapshot.directoryError`.
  public var lastDirectoryError: ProfileStoreError? {
    stateLock.withLock { resolvedDirectoryErrorLocked() }
  }

  /// Most recent error from reading the persisted active-profile
  /// marker. Same value as `snapshot.activeProfileError`. Stays set
  /// until the next successful `setActiveProfileID` /
  /// `clearActiveProfileID` write replaces or removes the file.
  public var lastActiveProfileError: ProfileStoreError? {
    stateLock.withLock { _activeProfileError }
  }

  /// Register a listener fired on every reload (initial scan + each
  /// debounced FS event). Callbacks run on the store's serial queue
  /// and receive the full `ProfileStoreSnapshot` (entries +
  /// directory-level error).
  public func addListener(_ listener: @escaping (ProfileStoreSnapshot) -> Void) {
    stateLock.withLock { listeners.append(listener) }
    // Fire once with the current state so callers don't miss the
    // initial scan (or a directory-level error captured before they
    // registered).
    let snap = snapshot
    queue.async { listener(snap) }
  }

  // MARK: - active profile

  /// Currently selected profile id (persisted across launches). `nil`
  /// when no selection has been made yet or `clearActiveProfileID()`
  /// was called. Does NOT validate that a matching profile exists in
  /// the directory — callers use `activeProfile` for that lookup.
  public var activeProfileID: String? {
    stateLock.withLock { _activeProfileID }
  }

  /// Resolves the currently selected profile against the most recent
  /// scan. Returns `nil` when:
  ///   · no active id has been set, OR
  ///   · the active id points at a profile that is missing or failed
  ///     to parse (callers surface `.profileMissing` on this path), OR
  ///   · the on-disk marker is currently in an error state (review
  ///     v8 F3). The v7 F1 contract preserves `_activeProfileID`
  ///     across a `.failed` read on the retry path, but every caller
  ///     of `activeProfile` would have to independently check
  ///     `lastActiveProfileError` to detect the broken-marker case.
  ///     Hiding the cached id behind `_activeProfileError != nil`
  ///     converts the silent-success surface into an explicit nil so
  ///     a future status-bar / debug overlay / XPC bridge consumer
  ///     cannot observe a clean Profile while disk is broken. The
  ///     retry contract is unchanged — the underlying state still
  ///     carries the id, and a successful `reloadActiveProfile()`
  ///     clears the error and re-exposes the Profile here.
  public var activeProfile: Profile? {
    stateLock.withLock {
      guard _activeProfileError == nil else { return nil }
      guard let id = _activeProfileID else { return nil }
      return _entries.first { $0.profile?.id == id }?.profile
    }
  }

  // MARK: - per-profile default model

  /// The model a profile carries as its default. This is the value the
  /// swap-confirm prompt PRE-FILLS — it is never auto-loaded. Returns
  /// nil when no profile with `id` exists or it failed to parse, so the
  /// caller resolves to "no model" rather than a fabricated default.
  /// `modelForProfile` in `ProfileSwapCoordinator` is wired to this.
  public func model(forProfileID id: String) -> String? {
    stateLock.withLock {
      guard let model = _entries.first(where: { $0.profile?.id == id })?.profile?.model,
            !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return nil
      }
      return model
    }
  }

  /// Valid profiles whose default model is exactly `modelID`, in the
  /// same stable order as `entries`. Used before deleting an installed
  /// model so the confirmation can name/count affected profiles.
  public func profilesReferencingModel(_ modelID: String) -> [ProfileModelReference] {
    stateLock.withLock {
      _entries.compactMap { entry in
        guard let profile = entry.profile,
              profile.model == modelID else { return nil }
        return ProfileModelReference(id: profile.id, name: profile.name)
      }
    }
  }

  /// The full parsed `Profile` for `id`, or nil when the id is absent or
  /// its file failed to parse. The chat send path reads this to detect a
  /// tree-of-thought profile (`Profile.treeOfThought`) and route the turn
  /// to the ToT dispatch (#413); ordinary callers want `model(forProfileID:)`.
  public func profile(forProfileID id: String) -> Profile? {
    stateLock.withLock {
      _entries.first { $0.profile?.id == id }?.profile
    }
  }

  /// The speculative-decoding ("Fast Think") settings a profile carries,
  /// or `nil` when the profile has no `[speculation]` section / does not
  /// exist / failed to parse. `ChatScaffoldView.sendAssistantTurn` reads
  /// this for the chat's selected profile and threads it into the request
  /// options so `ChatSendController` can inject it (#426). Mirrors
  /// `model(forProfileID:)`.
  public func speculation(forProfileID id: String) -> Profile.Speculation? {
    stateLock.withLock {
      _entries.first { $0.profile?.id == id }?.profile?.speculation
    }
  }


  /// Persist a new default `model` onto the profile with `id`, leaving
  /// every other field untouched. Writes back to the profile's own
  /// on-disk file (not an assumed `<id>.toml`) and force-reloads so the
  /// change is visible without waiting on the FS-watcher debounce.
  /// Throws `.profileNotFound` when the id is absent or unparsable so a
  /// "Set as default" / editor write never silently vanishes.
  public func setModel(_ model: String, forProfileID id: String) throws {
    let target: (profile: Profile, filename: String) = try stateLock.withLock {
      guard let entry = _entries.first(where: { $0.profile?.id == id }),
            let profile = entry.profile else {
        throw ProfileStoreError.profileNotFound(id: id)
      }
      return (profile, entry.url.lastPathComponent)
    }
    var updated = target.profile
    updated.model = model
    try createProfile(updated, filename: target.filename)
  }

  /// Clear a profile's default model, preserving every other field and
  /// keeping the profile parseable as an explicit no-default state.
  public func clearModel(forProfileID id: String) throws {
    let target: (profile: Profile, filename: String) = try stateLock.withLock {
      guard let entry = _entries.first(where: { $0.profile?.id == id }),
            let profile = entry.profile else {
        throw ProfileStoreError.profileNotFound(id: id)
      }
      return (profile, entry.url.lastPathComponent)
    }
    var updated = target.profile
    updated.model = nil
    try createProfile(updated, filename: target.filename)
  }

  /// Clear every valid profile whose default references `modelID`.
  /// Matching is exact; no fallback model is selected. If any profile
  /// write fails mid-batch, earlier writes are restored before the
  /// error is surfaced so callers do not observe silently partial
  /// no-default state.
  @discardableResult
  public func clearModelDefaults(referencing modelID: String) throws -> [ProfileModelReference] {
    try withClearedModelDefaults(referencing: modelID) { () }.affectedProfiles
  }

  /// Temporarily clear every default referencing `modelID`, perform a
  /// caller-supplied operation, and restore the original defaults if
  /// that operation fails. This lets model deletion treat the profile
  /// cleanup and Trash move as one recoverable operation: a failed
  /// Trash move cannot leave profiles silently cleared.
  @discardableResult
  public func withClearedModelDefaults<Output>(
    referencing modelID: String,
    operation: () throws -> Output
  ) throws -> ProfileModelDefaultsOperationResult<Output> {
    try withClearedModelDefaults(
      referencing: modelID,
      writeProfile: { [self] profile, filename in
        try createProfile(profile, filename: filename)
      },
      operation: operation
    )
  }

  @discardableResult
  internal func withClearedModelDefaults<Output>(
    referencing modelID: String,
    writeProfile: (Profile, String) throws -> Void,
    operation: () throws -> Output
  ) throws -> ProfileModelDefaultsOperationResult<Output> {
    let targets: [ProfileModelDefaultTarget] = stateLock.withLock {
      _entries.compactMap { entry in
        guard let profile = entry.profile,
              profile.model == modelID else { return nil }
        return ProfileModelDefaultTarget(
          profile: profile,
          filename: entry.url.lastPathComponent,
          reference: ProfileModelReference(id: profile.id, name: profile.name)
        )
      }
    }
    var cleared: [ProfileModelDefaultTarget] = []
    do {
      for target in targets {
        var updated = target.profile
        updated.model = nil
        try writeProfile(updated, target.filename)
        cleared.append(target)
      }
    } catch {
      let rollback = restoreModelDefaultTargets(cleared, writeProfile: writeProfile)
      throw ProfileModelDefaultsTransactionError.clearFailed(
        modelID: modelID,
        cleared: cleared.map(\.reference),
        underlying: String(describing: error),
        rollback: rollback
      )
    }

    do {
      let output = try operation()
      return ProfileModelDefaultsOperationResult(
        affectedProfiles: targets.map(\.reference),
        output: output
      )
    } catch {
      let rollback = restoreModelDefaultTargets(cleared, writeProfile: writeProfile)
      throw ProfileModelDefaultsTransactionError.operationFailed(
        modelID: modelID,
        cleared: cleared.map(\.reference),
        underlying: String(describing: error),
        rollback: rollback
      )
    }
  }

  private func restoreModelDefaultTargets(
    _ targets: [ProfileModelDefaultTarget],
    writeProfile: (Profile, String) throws -> Void
  ) -> ProfileModelDefaultsRollbackState {
    guard !targets.isEmpty else { return .notNeeded }
    var failures: [String] = []
    for target in targets.reversed() {
      do {
        try writeProfile(target.profile, target.filename)
      } catch {
        failures.append("\(target.reference.id): \(error)")
      }
    }
    return failures.isEmpty ? .succeeded : .failed(failures.joined(separator: "; "))
  }

  /// Persist `id` as the active profile. Writes atomically to
  /// `activeProfileURL` so a crashed write never leaves a half-line
  /// file the next launch interprets as a non-existent id. Notifies
  /// listeners after the write so UI selection state stays in sync.
  /// A successful write also clears any stale
  /// `_activeProfileError` because the on-disk marker is now
  /// definitively readable.
  ///
  /// Disk-write + memory-update + debounce-cancel run as ONE
  /// queue-serial unit (review v5 F3). Earlier, the disk write
  /// happened off-queue and only the post-write state mutation was
  /// serialized — two concurrent setters could observe their disk
  /// writes in one order and their queue arrival in the other,
  /// producing a disk/memory mismatch (last queue arrival wins for
  /// memory, last filesystem rename wins for disk). Pulling the
  /// write inside `performOnQueue` makes disk-then-memory atomic
  /// from any caller's vantage.
  public func setActiveProfileID(_ id: String) throws {
    var thrown: Error?
    var snap: ProfileStoreSnapshot?
    var toFire: [((ProfileStoreSnapshot) -> Void)] = []
    performOnQueue {
      do {
        try self.writeActiveProfileIDToDisk(id)
      } catch {
        // Log before propagating (review v6 F4). A caller using
        // `try?` would otherwise silently drop the failure: disk
        // unchanged, in-memory state unchanged, no listener fire,
        // no audit trail. Mirrors the error-log pattern in
        // `readActiveProfileIDFromDisk` so write failures and read
        // failures appear in os_log under the same category.
        Log.store.error("setActiveProfileID: write to \(self.activeProfileURL.path, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        thrown = error
        return
      }
      self.debounceItem?.cancel()
      self.debounceItem = nil
      self.stateLock.withLock {
        self._activeProfileID = id
        self._activeProfileError = nil
        snap   = self.makeSnapshotLocked()
        toFire = self.listeners
      }
    }
    if let thrown { throw thrown }
    if let snap {
      for cb in toFire { queue.async { cb(snap) } }
    }
  }

  /// Forget the active selection. Removes the on-disk marker; safe to
  /// call when the file is already absent. Also clears any stale
  /// `_activeProfileError` — the file is gone, there is nothing left
  /// to fail to read. Same queue-atomicity contract as
  /// `setActiveProfileID` (review v4 F4 + v5 F3): disk removal +
  /// memory update + debounce cancel are one queue-serial unit.
  public func clearActiveProfileID() throws {
    var thrown: Error?
    var snap: ProfileStoreSnapshot?
    var toFire: [((ProfileStoreSnapshot) -> Void)] = []
    performOnQueue {
      do {
        try self.removeActiveProfileFromDisk()
      } catch {
        // Review v6 F4 — log before propagating, see setActiveProfileID.
        Log.store.error("clearActiveProfileID: remove of \(self.activeProfileURL.path, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        thrown = error
        return
      }
      self.debounceItem?.cancel()
      self.debounceItem = nil
      self.stateLock.withLock {
        self._activeProfileID = nil
        self._activeProfileError = nil
        snap   = self.makeSnapshotLocked()
        toFire = self.listeners
      }
    }
    if let thrown { throw thrown }
    if let snap {
      for cb in toFire { queue.async { cb(snap) } }
    }
  }

  // MARK: - profile CRUD

  /// Writes `profile.dump()` to `<directory>/<filename>` so the FS
  /// watcher picks it up on the next debounced reload. `filename`
  /// defaults to `<profile.id>.toml`; callers that need a different
  /// on-disk name (collision, legacy slug) pass it explicitly.
  ///
  /// Atomic write — a crashed partial file cannot be observed by the
  /// watcher because `String.write(atomically:)` renames into place.
  @discardableResult
  public func createProfile(_ profile: Profile,
                            filename: String? = nil) throws -> URL {
    try createProfile(profile,
                      filename: filename,
                      dumpProvider: { try $0.dump() })
  }

  /// Testable overload (review v4 F1) — accepts an injectable
  /// `dumpProvider` so unit tests can drive the throwing branch of
  /// the dump → `.dumpFailed` wrap without needing TOMLKit to fail
  /// on its own output (which is unreachable in practice — see
  /// review v4 F1's "defensive depth-in-depth" rationale). Internal
  /// so production callers can only reach the public overload above.
  @discardableResult
  internal func createProfile(_ profile: Profile,
                              filename: String?,
                              dumpProvider: (Profile) throws -> String) throws -> URL {
    let name = filename ?? "\(profile.id).toml"
    let url  = directory.appendingPathComponent(name, isDirectory: false)
    let body: String
    do {
      body = try dumpProvider(profile)
    } catch {
      // Promote `ProfileError.parseFailure` from the clone round-trip
      // to a directory-level `.dumpFailed` (review v3 F3). Before this,
      // a TOMLKit round-trip failure inside `dump()` silently fell
      // back to an empty table and a syntactically valid but
      // amputated TOML hit disk; surfacing the throw here aborts the
      // write so no caller observes the truncation.
      throw ProfileStoreError.dumpFailed(path: url.path,
                                         underlying: String(describing: error))
    }
    try body.write(to: url, atomically: true, encoding: .utf8)
    // Force an immediate directory rescan so callers that
    // activate-after-create see the new entry before the FS-watcher
    // debounce fires. Post-cycle-188 reloadLocked only rescans the
    // directory (no marker read), so calling it from inside a
    // listener simply re-scans + fires listeners — no recursion via
    // marker re-read. The `performOnQueue` reentrancy probe still
    // serializes against the queue without deadlocking when invoked
    // from a listener callback.
    _ = performOnQueue { self.reloadLocked() }
    return url
  }

  // MARK: - active-profile disk helpers

  /// Typed result of reading the persisted active-profile marker.
  ///   · `.absent`     — file missing or empty; canonical "no selection".
  ///   · `.ok(id)`     — file holds a usable id.
  ///   · `.failed(err)` — explicit, structured error.
  ///
  /// Post-cycle-188 the marker is read only on authoritative paths
  /// (`start()`, `reloadActiveProfile()`); there is no background /
  /// FS-watcher marker re-read, so no transient-vs-persistent
  /// classification is needed — every failure commits.
  internal enum ActiveProfileReadResult {
    case absent
    case ok(String)
    case failed(ProfileStoreError)
  }

  /// `try? Data(contentsOf:)` is deliberately avoided (review cycle
  /// 149/150 F1): it collapses permission denials, IO errors, and
  /// UTF-8 decode failures into "no selection", silently masking a
  /// broken marker the GUI needs to render an actionable banner.
  private func readActiveProfileIDFromDisk() -> ActiveProfileReadResult {
    let path = activeProfileURL.path
    var isDir: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
    if !exists {
      return .absent
    }
    if isDir.boolValue {
      let msg = "active-profile path is a directory, not a file"
      Log.store.error("readActiveProfileIDFromDisk: \(msg, privacy: .public) at \(path, privacy: .public)")
      return .failed(.activeProfileReadFailed(path: path, underlying: msg))
    }
    let data: Data
    do {
      data = try Data(contentsOf: activeProfileURL)
    } catch {
      let underlying = String(describing: error)
      Log.store.error("readActiveProfileIDFromDisk: read failed at \(path, privacy: .public): \(underlying, privacy: .public)")
      return .failed(.activeProfileReadFailed(path: path, underlying: underlying))
    }
    guard let raw = String(data: data, encoding: .utf8) else {
      let msg = "marker contents are not valid UTF-8 (size=\(data.count) bytes)"
      Log.store.error("readActiveProfileIDFromDisk: \(msg, privacy: .public) at \(path, privacy: .public)")
      return .failed(.activeProfileReadFailed(path: path, underlying: msg))
    }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? .absent : .ok(trimmed)
  }

  /// Caller context for `commitActiveReadResultLocked` (review v8 F2).
  /// The pre-v8 single-policy commit preserved `_activeProfileID` on
  /// `.failed` unconditionally — fine on the retry path (v7 F1
  /// contract: known-good in-memory truth must survive a transient
  /// disk hiccup) but WRONG at boot: a `stop()`-ped store retains
  /// its prior `_activeProfileID`, so `start()` against a freshly
  /// corrupted marker would resurrect a stale id from the previous
  /// lifecycle while surfacing a structured error for a different
  /// selection. Splitting the policy at the call site makes the
  /// divergence explicit:
  ///
  ///   · `.start`  — boot path. No in-memory state worth preserving
  ///     across an `open(fd) → read marker` round-trip; commit the
  ///     disk truth (id == nil on .failed) so the snapshot reflects
  ///     reality.
  ///   · `.reload` — operator-initiated retry. Preserve the
  ///     in-memory id across `.failed` per v7 F1 so a transient
  ///     hiccup does not silently mask a known-good selection.
  internal enum CommitSource {
    case start
    case reload
  }

  /// Apply the result of an authoritative marker read to in-memory
  /// state. Caller must hold `stateLock`. Used by `start()` (with
  /// `source: .start`) and `reloadActiveProfile()` (with
  /// `source: .reload`) — the only two paths that read the marker
  /// post-cycle-188.
  ///
  /// `.absent` and `.ok` commit fully regardless of source: those
  /// are successful reads that intentionally changed state.
  ///
  /// `.failed` semantics diverge by source (see `CommitSource`).
  /// Both branches log at `.error` (review v9 F4: promoted from
  /// `.notice` so the policy decision sits at the same severity as
  /// its proximate cause — `readActiveProfileIDFromDisk` already
  /// logs `.error`, and every other consequential failure in this
  /// file uses `.error`). The `.start` wipe discards a persisted
  /// selection; the `.reload` preserve papers over a disk fault —
  /// both warrant `.error` severity for grep-by-severity workflows.
  private func commitActiveReadResultLocked(_ result: ActiveProfileReadResult,
                                            source: CommitSource) {
    switch (result, source) {
    case (.absent, _):
      _activeProfileID = nil
      _activeProfileError = nil
    case (.ok(let id), _):
      _activeProfileID = id
      _activeProfileError = nil
    case (.failed(let err), .start):
      // Boot — no in-memory state worth preserving across the
      // open-and-read round-trip. Commit disk truth so the snapshot
      // matches reality and a prior-lifecycle id cannot resurface
      // through stop/start.
      Log.store.error("commitActiveReadResultLocked(.start): read failed; committing nil id + error per boot contract. cause=\(String(describing: err), privacy: .public)")
      _activeProfileID = nil
      _activeProfileError = err
    case (.failed(let err), .reload):
      // Retry — preserve known-good in-memory id per v7 F1. Log
      // here so a future operator debugging "wrong profile started"
      // can grep the policy boundary directly rather than inferring
      // the preserve action from an unchanged id.
      Log.store.error("commitActiveReadResultLocked(.reload): read failed (\(String(describing: err), privacy: .public)); preserving in-memory id=\(self._activeProfileID ?? "<nil>", privacy: .public) per v7 F1 contract")
      _activeProfileError = err
      // _activeProfileID intentionally preserved.
    }
  }

  private func writeActiveProfileIDToDisk(_ id: String) throws {
    let parent = activeProfileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parent,
                                            withIntermediateDirectories: true)
    try id.write(to: activeProfileURL, atomically: true, encoding: .utf8)
  }

  private func removeActiveProfileFromDisk() throws {
    let fm = FileManager.default
    guard fm.fileExists(atPath: activeProfileURL.path) else { return }
    try fm.removeItem(at: activeProfileURL)
  }

  // MARK: - seeding

  /// Pair of errors produced by `seedDefaultsIfEmpty`. Split because
  /// the chat.toml seed and the active-profile marker seed land on
  /// different snapshot channels: `dirError` → `_lastSeedError` /
  /// snapshot `directoryError`, `markerError` → `_activeProfileError` /
  /// snapshot `activeProfileError`. Conflating them would either
  /// suppress chat.toml success (if both routed to `_lastSeedError`)
  /// or — worse — leave the marker-write failure silent and re-create
  /// the exact "no operator-visible error, Resume is a no-op" state
  ///  exists to eliminate (review v1 F2).
  private struct SeedResult {
    let dirError: ProfileStoreError?
    let markerError: ProfileStoreError?
  }

  /// Writes `chat.toml` containing `defaultChatTOML` when the
  /// profiles directory has no `*.toml` files, AND seeds the
  /// active-profile marker when it is absent. Idempotent: re-running
  /// against a populated directory is a no-op for the chat.toml seed,
  /// and the marker seed uses exclusive-create semantics so a
  /// concurrent process's marker always wins (review v1 F3).
  /// #413: ensure the example tree-of-thought profile exists so the live
  /// tree-search feature is reachable (the user just switches to it).
  ///
  /// Unlike `seedDefaultsIfEmpty` (which writes only when the profiles dir
  /// is TRULY EMPTY = fresh install), this WRITE-IF-ABSENT backfill runs on
  /// every `start()`, so an EXISTING install — whose dir already holds
  /// `chat.toml` from before #413, making the seed a no-op — gets the
  /// profile too. It never clobbers a user-edited copy (writes only when
  /// the file is missing). Best-effort: a failure must NOT fail `start()`
  /// (the user can still chat). The Settings editor only DISPLAYS
  /// `inferlet_args`, so seeding the file is the only way a user gets a ToT
  /// profile without hand-writing TOML.
  ///
  /// Runs on `queue` (called from `start()` inside `queue.sync`). Does not
  /// touch the active-profile marker — `chat` stays the default; ToT is
  /// opt-in via the picker.
  private func backfillTreeOfThoughtProfile() {
    guard seedsExampleProfiles else { return }
    let target = directory.appendingPathComponent(Self.treeOfThoughtFilename)
    guard !FileManager.default.fileExists(atPath: target.path) else { return }
    do {
      try Self.treeOfThoughtTOML.write(to: target, atomically: true, encoding: .utf8)
      Log.store.info("backfilled tree-of-thought profile at \(target.path, privacy: .public)")
    } catch {
      Log.store.error(
        "backfill tree-of-thought profile failed (non-fatal): \(String(describing: error), privacy: .public)"
      )
    }
  }

  private func seedDefaultsIfEmpty() -> SeedResult {
    let existing = (try? FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    )) ?? []
    let tomls = existing.filter { $0.pathExtension == "toml" }
    guard tomls.isEmpty else { return SeedResult(dirError: nil, markerError: nil) }

    let target = directory.appendingPathComponent(Self.defaultChatFilename)
    do {
      try Self.defaultChatTOML.write(to: target, atomically: true, encoding: .utf8)
      Log.store.info("seeded default profile at \(target.path, privacy: .public)")
    } catch {
      let underlying = String(describing: error)
      Log.store.error("seed default profile failed: \(underlying, privacy: .public)")
      // Skip marker seed when chat.toml itself failed — the marker
      // would point at an id with no parsed entry, which is a worse
      // state than "absent" (HelperResumeAction would surface
      // `.resolverFailed(.profileMissing)` instead of the actionable
      // seed-failed banner).
      return SeedResult(
        dirError: .seedFailed(path: target.path, underlying: underlying),
        markerError: nil
      )
    }

    // #413: the example tree-of-thought profile is NOT written here. It is
    // backfilled by `backfillTreeOfThoughtProfile()` (write-if-absent on
    // every start), so EXISTING installs — whose profiles dir is non-empty,
    // making this seed a no-op — get it too, not just fresh installs.

    // : pair the chat.toml seed with an active-profile
    // marker so the first-run menu-bar Resume click resolves into a
    // real start instead of `.noActiveProfile`. A pre-existing marker
    // is the operator's prior selection (rare on a freshly-seeded
    // dir, but possible if tomls were manually removed, OR if a
    // sibling Pie process raced our seed) and must win.
    let markerError = seedActiveProfileMarker()
    return SeedResult(dirError: nil, markerError: markerError)
  }

  /// Ensure the built-in "Fast Think" profile exists (#426). Unlike
  /// `seedDefaultsIfEmpty` (gated on an empty dir), this writes
  /// `fast-think.toml` whenever it is ABSENT — so installs that already
  /// have a `chat.toml` (i.e. every install past first launch) still gain
  /// Fast Think on the next start. Existence-gated, so a user's edits to
  /// the file survive; deleting it re-creates it next launch, which is the
  /// accepted contract for a built-in default (edit it, don't delete it).
  /// Never touches the active-profile marker — the default selection stays
  /// `chat`. Returns `.seedFailed` on a write failure; `start()` routes it
  /// to the dedicated `_builtinSeedError` channel, which surfaces on the
  /// snapshot's `directoryError` even when the directory already has
  /// profiles (review v1 F1). A nil return is success-or-exists.
  private func ensureBuiltinFastThinkProfile() -> ProfileStoreError? {
    let target = directory.appendingPathComponent(Self.defaultFastThinkFilename)
    if FileManager.default.fileExists(atPath: target.path) { return nil }
    do {
      try Self.defaultFastThinkTOML.write(to: target, atomically: true, encoding: .utf8)
      Log.store.info("seeded built-in Fast Think profile at \(target.path, privacy: .public)")
      return nil
    } catch {
      let underlying = String(describing: error)
      Log.store.error("seed Fast Think profile failed: \(underlying, privacy: .public)")
      return .seedFailed(path: target.path, underlying: underlying)
    }
  }

  /// Exclusive-create write of the active-profile marker (review v1 F3).
  ///
  /// Implemented via `open(2)` with `O_CREAT | O_EXCL | O_WRONLY`
  /// instead of the prior `fileExists` + `write(atomically:)` pair —
  /// the prior pattern was TOCTOU-vulnerable under the documented
  /// multi-process layout (helper + app both calling `start()`
  /// against a shared `PIE_HOME`). With `O_EXCL` the kernel
  /// guarantees at most one writer wins; the loser sees `EEXIST` and
  /// returns success — the existing marker IS the prior selection
  /// the seed comment promises to preserve.
  ///
  /// Returns nil on success-or-already-exists. Returns
  /// `.activeProfileSeedFailed` on any other failure (review v1 F2);
  /// logging-only is the silent-no-op the fix addresses.
  private func seedActiveProfileMarker() -> ProfileStoreError? {
    let parent = activeProfileURL.deletingLastPathComponent()
    do {
      try FileManager.default.createDirectory(at: parent,
                                              withIntermediateDirectories: true)
    } catch {
      let underlying = String(describing: error)
      Log.store.error("seed active-profile marker: mkdir of parent failed: \(underlying, privacy: .public)")
      return .activeProfileSeedFailed(path: activeProfileURL.path, underlying: underlying)
    }

    let fd = activeProfileURL.path.withCString { cpath in
      open(cpath, O_CREAT | O_EXCL | O_WRONLY, 0o644)
    }
    if fd < 0 {
      let err = errno
      if err == EEXIST {
        // Review v2 F4: EEXIST is type-blind under POSIX. Confirm the
        // existing inode is a regular file before claiming "existing
        // marker wins" — a directory at the marker path produces a
        // log line that misleads anyone debugging "Resume returns
        // noActiveProfile despite seed log saying success".
        var st = stat()
        let rc = activeProfileURL.path.withCString { lstat($0, &st) }
        if rc != 0 {
          let lerr = errno
          let underlying = "EEXIST then lstat failed: errno=\(lerr) (\(String(cString: strerror(lerr))))"
          Log.store.error("seed active-profile marker: \(underlying, privacy: .public)")
          return .activeProfileSeedFailed(path: activeProfileURL.path, underlying: underlying)
        }
        let mode = st.st_mode
        if (mode & S_IFMT) == S_IFREG {
          Log.store.info("seed active-profile marker: \(self.activeProfileURL.path, privacy: .public) already exists as regular file; existing marker wins (race-safe path)")
          return nil
        }
        let typeDesc = inodeTypeDescription(mode)
        let underlying = "marker path exists as \(typeDesc) — refusing to treat as a valid marker"
        Log.store.error("seed active-profile marker: \(underlying, privacy: .public) at \(self.activeProfileURL.path, privacy: .public)")
        return .activeProfileSeedFailed(path: activeProfileURL.path, underlying: underlying)
      }
      let underlying = "open(O_CREAT|O_EXCL|O_WRONLY) errno=\(err) (\(String(cString: strerror(err))))"
      Log.store.error("seed active-profile marker failed: \(underlying, privacy: .public)")
      return .activeProfileSeedFailed(path: activeProfileURL.path, underlying: underlying)
    }
    defer { close(fd) }

    let bytes = Array(Self.defaultProfileID.utf8)
    // Review v2 F3: retry on EINTR. A signal delivered between
    // open(2) and write(2) — possible during first-launch TCC
    // prompts — would otherwise return -1 / errno=EINTR, surface
    // as `.activeProfileSeedFailed`, and (since the seed path is
    // one-shot per `PIE_HOME` lifetime) leave the helper in a
    // permanent broken state. Standard POSIX I/O hygiene.
    var written: Int = 0
    bytes.withUnsafeBufferPointer { buf in
      repeat {
        written = Darwin.write(fd, buf.baseAddress, buf.count)
      } while written < 0 && errno == EINTR
    }
    if written != bytes.count {
      let err = errno
      let underlying = "short write: wrote \(written) of \(bytes.count) bytes, errno=\(err) (\(String(cString: strerror(err))))"
      Log.store.error("seed active-profile marker write incomplete: \(underlying, privacy: .public)")
      // Best-effort unlink — leaving a partial/empty marker behind
      // would cause the next `start()` to hit the EEXIST-as-success
      // path and decode an empty/short id, producing a confusing
      // "marker exists but resolves to nothing" state.
      //
      // Review v2 F5: log unlink failure so the operator can grep
      // for the residual half-written marker (the caller already
      // surfaces an error to the snapshot, so log-only is OK here).
      if unlink(activeProfileURL.path) != 0 {
        let uerr = errno
        Log.store.error("seed active-profile marker: post-short-write unlink failed: errno=\(uerr, privacy: .public) (\(String(cString: strerror(uerr)), privacy: .public)); residual marker may persist at \(self.activeProfileURL.path, privacy: .public)")
      }
      return .activeProfileSeedFailed(path: activeProfileURL.path, underlying: underlying)
    }
    Log.store.info("seeded active-profile marker at \(self.activeProfileURL.path, privacy: .public) -> \(Self.defaultProfileID, privacy: .public)")
    return nil
  }

  /// Human-readable inode type tag for the F4 EEXIST diagnostic.
  /// Covers the common cases (`dir`, `symlink`, `fifo`, `socket`,
  /// `chr`/`blk` devices); falls back to the raw mode bits for any
  /// future Darwin-specific type.
  private func inodeTypeDescription(_ mode: mode_t) -> String {
    switch mode & S_IFMT {
    case S_IFDIR:  return "directory"
    case S_IFLNK:  return "symlink"
    case S_IFIFO:  return "fifo"
    case S_IFSOCK: return "socket"
    case S_IFCHR:  return "character device"
    case S_IFBLK:  return "block device"
    case S_IFREG:  return "regular file"
    default:       return "unknown(mode=0o\(String(mode, radix: 8)))"
    }
  }

  // MARK: - reload

  /// Coalesces back-to-back FS events into a single reload. Called
  /// from the dispatch source's event handler (already on `queue`),
  /// so debounce scheduling is queue-local.
  private func scheduleReload() {
    debounceItem?.cancel()
    let item = DispatchWorkItem { [weak self] in
      self?.reloadLocked()
    }
    debounceItem = item
    queue.asyncAfter(deadline: .now() + debounceInterval, execute: item)
  }

  /// FS-watcher rescan path (post-cycle-188 architectural decoupling).
  ///
  /// Rescans the profiles directory, updates `_entries`, fires
  /// listeners synchronously inline on `queue`. Does NOT touch the
  /// active-profile marker — the marker is owned by the three
  /// explicit paths (`start()`, set/clear, `reloadActiveProfile()`).
  /// Stripping marker handling here removed the recursive
  /// marker-read trap that motivated the v5 F4 reentrancy guard,
  /// which is now gone.
  /// Commit a directory-scan result to in-memory state. Caller must
  /// hold `stateLock`. Extracted (review v10 F6) so the short-circuit
  /// branch and the normal branch of `reloadLocked` share the
  /// `_entries` / `_lastScanError` / `_lastSeedError` policy.
  private func commitScanResultsLocked(results: [ProfileLoadResult],
                                       scanErr: ProfileStoreError?) {
    _entries       = results
    _lastScanError = scanErr
    // Clear stale seed error once the directory recovers (user
    // dropped a profile in manually, perms fixed, etc.).
    if scanErr == nil && !results.isEmpty {
      _lastSeedError = nil
    }
  }

  @discardableResult
  private func reloadLocked() -> ProfileStoreSnapshot {
    // Out-of-DEBUG recursion canary with short-circuit (review v7
    // F3 → v8 F1 → v9 F3 → v10 F3). A listener that unconditionally
    // calls createProfile (which synchronously re-enters reloadLocked
    // via performOnQueue) used to stack-overflow in release. At
    // threshold we rescan + commit `_entries` (so recursive writes
    // are visible) but suppress the immediate fan-out; one final
    // fan-out is scheduled via `_pendingPostRecursionFanOut` and
    // delivered by the outermost reloadLocked's defer when the
    // recursion chain unwinds to depth 0. That gives non-recursive
    // listeners attached for unrelated reasons their
    // immediate-visibility contract back, while bounding the
    // recursive case.
    let depth: Int = stateLock.withLock {
      _reloadDepth += 1
      return _reloadDepth
    }
    defer {
      // v10 F3 deferred fan-out: when this defer is the last frame
      // (depth returns to 0) AND the short-circuit set the pending
      // flag, deliver one final fan-out with the snapshot CAPTURED
      // AT SHORT-CIRCUIT TIME (review v11 F1) — not a fresh one,
      // which would reflect any state mutations made by listeners
      // firing during the intermediate unwind frames.
      //
      // v10 F4 underflow guard: `max(0, …)` defends against a
      // hypothetical reordering where stopInternal raced an
      // in-flight reloadLocked. Combined with v10 F2's queue-drain
      // in `stop()`, the race is structurally eliminated; the guard
      // is belt-and-suspenders.
      let dispatch: (snap: ProfileStoreSnapshot,
                     listeners: [((ProfileStoreSnapshot) -> Void)],
                     epoch: UInt64)?
      dispatch = stateLock.withLock { () -> (snap: ProfileStoreSnapshot,
                                              listeners: [((ProfileStoreSnapshot) -> Void)],
                                              epoch: UInt64)? in
        _reloadDepth = max(0, _reloadDepth - 1)
        if _reloadDepth == 0,
           _pendingPostRecursionFanOut,
           let stashed = _pendingPostRecursionSnapshot {
          _pendingPostRecursionFanOut = false
          _pendingPostRecursionSnapshot = nil
          return (stashed, listeners, _lifecycleEpoch)
        }
        return nil
      }
      if let dispatch {
        // ASYNC fan-out — sync fire from this defer would immediately
        // re-enter reloadLocked if a listener body triggers recursion,
        // rebuilding the stack the short-circuit existed to prevent.
        // Queueing turns the worst case into a bounded queue-tick
        // storm rather than stack overflow.
        //
        // v11 F2: capture the epoch at dispatch; the callback aborts
        // when a stop() between dispatch and execution has shifted
        // the epoch. Prevents post-stop callback delivery from a
        // pre-stop snapshot.
        let capturedSnap = dispatch.snap
        let capturedEpoch = dispatch.epoch
        for cb in dispatch.listeners {
          queue.async { [weak self] in
            guard let self else { return }
            let stillCurrent = self.stateLock.withLock {
              self._lifecycleEpoch == capturedEpoch
            }
            if stillCurrent { cb(capturedSnap) }
          }
        }
      }
    }
    if depth >= Self.reloadDepthThreshold {
      // Rescan + commit `_entries` even on short-circuit (v9 F3).
      // Set the pending-fan-out flag so the outermost defer delivers
      // ONE fan-out with the post-recursion-settled snapshot (v10
      // F3); non-recursive listeners no longer silently miss the
      // recursive chain's writes.
      let (results, scanErr) = scanDirectory()
      let overwrotePriorStash: Bool
      let snap: ProfileStoreSnapshot
      (overwrotePriorStash, snap) = stateLock.withLock { () -> (Bool, ProfileStoreSnapshot) in
        commitScanResultsLocked(results: results, scanErr: scanErr)
        _reloadShortCircuitCount += 1
        // v12 F3: detect nested short-circuit within the same unwind
        // chain — a listener firing during intermediate unwind
        // frames triggered another sub-chain that ALSO crossed
        // threshold. The newer snapshot is strictly more recent and
        // subsumes the older writes; reporting the overwrite from
        // the call site lets operators correlate the canary trip
        // count with the number of distinct chains.
        let priorWasPending = _pendingPostRecursionFanOut
        _pendingPostRecursionFanOut = true
        // v11 F1: stash the snapshot AT short-circuit time. The
        // depth-0 defer delivers this exact value; any listener
        // running during the intermediate unwind frames that mutates
        // store state will not corrupt the post-recursion-write
        // snapshot promise.
        let s = makeSnapshotLocked()
        _pendingPostRecursionSnapshot = s
        return (priorWasPending, s)
      }
      if overwrotePriorStash {
        Log.store.error("reloadLocked: short-circuit overwriting prior stash within same unwind chain (nested recursion). reloadShortCircuitCount=\(self.reloadShortCircuitCount, privacy: .public)")
      }
      Log.store.error("reloadLocked recursion depth=\(depth, privacy: .public) >= threshold=\(Self.reloadDepthThreshold, privacy: .public); committed rescan + stashed snapshot for one deferred fan-out at depth 0. Caller must observe one-shot listener semantics (see ProfileStore.listeners doc)")
      return snap
    }

    let (results, scanErr) = scanDirectory()
    var snap: ProfileStoreSnapshot!
    var toFire: [((ProfileStoreSnapshot) -> Void)] = []
    stateLock.withLock {
      commitScanResultsLocked(results: results, scanErr: scanErr)
      snap   = makeSnapshotLocked()
      toFire = listeners
    }
    for cb in toFire {
      cb(snap)
    }
    return snap
  }

  /// Public retry hook (review v3 F2). Forces a re-read of the
  /// active-profile marker outside the FS watcher's debounced
  /// `*.toml`-reload path. A GUI "retry" button on the broken-marker
  /// banner can call this after the operator repairs perms / removes
  /// a planted directory, so the state clears without round-tripping
  /// through `setActiveProfileID` (which would force a specific id).
  ///
  /// Authoritative — a still-failing marker read here commits to
  /// `_activeProfileError`; an absent/valid marker commits the
  /// healed state. Returns the post-read snapshot so callers do not
  /// have to poll `lastActiveProfileError` afterwards (v5 F5).
  ///
  /// Reentrancy: `performOnQueue` runs inline when the caller is
  /// already on `queue` (listener callback). Post-cycle-188 there is
  /// no recursive marker-read path because `reloadLocked` does not
  /// touch the marker; listeners that call `reloadActiveProfile()`
  /// must still observe normal one-shot semantics if they would
  /// otherwise re-trigger their own fire (standard observer
  /// contract).
  @discardableResult
  public func reloadActiveProfile() -> ProfileStoreSnapshot {
    performOnQueue {
      let readResult = self.readActiveProfileIDFromDisk()
      var snap: ProfileStoreSnapshot!
      var toFire: [((ProfileStoreSnapshot) -> Void)] = []
      self.stateLock.withLock {
        self.commitActiveReadResultLocked(readResult, source: .reload)
        snap   = self.makeSnapshotLocked()
        toFire = self.listeners
      }
      // Fan out asynchronously so a listener that calls
      // `reloadActiveProfile()` from inside its callback cannot
      // synchronously stack-recurse into this same function.
      for cb in toFire { self.queue.async { cb(snap) } }
      return snap
    }
  }

  /// Caller must hold `stateLock`.
  ///
  /// Snapshot-level masking (review v9 F1): when `_activeProfileError`
  /// is set, the snapshot's `activeProfileID` is emitted as nil even
  /// though the underlying `_activeProfileID` is preserved for the v7
  /// F1 retry-continuity contract. Pre-v9, masking applied only to
  /// the convenience `activeProfile` accessor; the documented
  /// listener-surface (ProfileStoreSnapshot) still emitted both
  /// signals, so any consumer following the snapshot pattern
  /// `snap.entries.first { $0.profile?.id == snap.activeProfileID }`
  /// reconstructed exactly the clean Profile the accessor masking
  /// promised was impossible. Masking at the snapshot factory
  /// collapses both surfaces to the same shape: error live → no id
  /// visible to consumers.
  private func makeSnapshotLocked() -> ProfileStoreSnapshot {
    let visibleID: String? = (_activeProfileError == nil) ? _activeProfileID : nil
    return ProfileStoreSnapshot(
      entries: _entries,
      directoryError: resolvedDirectoryErrorLocked(),
      activeProfileError: _activeProfileError,
      activeProfileID: visibleID
    )
  }

  /// Caller must hold `stateLock`. Scan errors take priority over
  /// seed errors (scan reflects the most recent FS interaction); the
  /// empty-dir chat seed error only surfaces while the directory is
  /// still empty. The built-in (Fast Think) seed error surfaces
  /// regardless of `_entries.isEmpty` — its whole purpose is populated
  /// installs (review v1 F1) — at lowest priority, since a scan failure
  /// or a failed empty-dir chat seed is the more actionable signal.
  private func resolvedDirectoryErrorLocked() -> ProfileStoreError? {
    if let s = _lastScanError { return s }
    if let s = _lastSeedError, _entries.isEmpty { return s }
    if let s = _builtinSeedError { return s }
    return nil
  }

  private func scanDirectory() -> ([ProfileLoadResult], ProfileStoreError?) {
    Self.scan(directory: directory)
  }

  /// Public re-entrant scan. Read-only consumers (Settings → Profiles
  /// tab, ad-hoc tools) call this directly instead of duplicating the
  /// `contentsOfDirectory` + `Profile.parse` + warning-aggregation
  /// logic — and so they don't drift on the extension-match rule
  /// (review v2 F9: tab previously used `pathExtension.lowercased()
  /// == "toml"` while this scan uses literal `== "toml"`; canonical
  /// rule is now the literal lowercase match below, matching what
  /// the FS-watcher actually keys on).
  public static func scan(
    directory: URL,
    fileManager: FileManager = .default
  ) -> ([ProfileLoadResult], ProfileStoreError?) {
    let files: [URL]
    do {
      files = try fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
      )
    } catch {
      let underlying = String(describing: error)
      Log.store.error("scan(\(directory.path, privacy: .public)) failed: \(underlying, privacy: .public)")
      return ([], .scanFailed(path: directory.path, underlying: underlying))
    }
    let tomls = files
      .filter { $0.pathExtension == "toml" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }

    let parsed = tomls.map { url -> ProfileLoadResult in
      let source: String
      do {
        source = try String(contentsOf: url, encoding: .utf8)
      } catch {
        return ProfileLoadResult(
          url: url,
          profile: nil,
          error: .parseFailure("read failed: \(String(describing: error))"),
          warnings: []
        )
      }
      do {
        let profile = try Profile.parse(toml: source)
        return ProfileLoadResult(
          url: url,
          profile: profile,
          error: nil,
          warnings: profile.sectionWarnings()
        )
      } catch let err as ProfileError {
        return ProfileLoadResult(url: url, profile: nil, error: err, warnings: [])
      } catch {
        return ProfileLoadResult(
          url: url,
          profile: nil,
          error: .parseFailure(String(describing: error)),
          warnings: []
        )
      }
    }
    return (parsed, nil)
  }
}

private extension NSLock {
  func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
