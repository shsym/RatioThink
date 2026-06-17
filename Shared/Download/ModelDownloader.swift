import Foundation
import CryptoKit
import Darwin
import os

/// Per-download progress snapshot. Codable so a future XPC selector (or
/// reverse-XPC channel) can ferry it back to the GUI without further
/// reshaping. Phase 2.5 surfaces progress only through the in-process
/// `AsyncStream` returned by `ModelDownloader.progress(for:)` — the GUI
/// is still on `MockEngineClient`, so wiring a real XPC pipe is Phase 6
/// work (tracked in ).
///
/// `verification` is nil for in-flight phases; on `.completed` it
/// records whether HF advertised a digest we matched against
/// (`.verified`), explicitly skipped because no header arrived
/// (`.notAdvertised`), or any other terminal state (`.notApplicable`).
/// Surface added in review v1 F14 so the GUI can badge unverified
/// completions instead of treating verified and unverified downloads
/// as indistinguishable.
public struct DownloadProgress: Codable, Equatable, Sendable {
  public enum Phase: String, Codable, Sendable {
    case starting
    case downloading
    case verifying
    case completed
    case cancelled
    case failed
  }

  public enum VerificationStatus: String, Codable, Sendable {
    case verified
    case notAdvertised
    case notApplicable
  }

  /// Why a `.starting` event was emitted. Nil on every non-starting
  /// phase. Surfaces the difference between a clean cold start, a
  /// resumed task, and a fresh task that abandoned an unusable `.resume`
  /// sidecar (corrupt/unreadable/missing-keys, or an orphan-resume
  /// restart). The GUI uses this to badge the abandoned-resume case so a
  /// user isn't silently re-fetching from byte 0 without a diagnostic.
  public enum StartReason: String, Codable, Sendable {
    case fresh
    case resumed
    /// `didCompleteWithError(NSURLErrorCannotOpenFile)` fired — the
    /// resume blob referenced a vanished temp file. The downloader
    /// swapped in a fresh task from byte 0 within the same handle.
    /// Surfaced so subscribers can render the byte-counter rewind
    /// instead of seeing progress mysteriously go backwards (review
    /// v4 F2).
    case restartedAfterOrphanResume
    /// Sidecar was present but unusable: corrupt/unreadable bytes,
    /// plist-parse failure, missing required URLSession keys, OR an
    /// `unsafe-sentinel` marker indicating a prior cancel's
    /// `fsyncDirectory` failed. `loadResumeBlobOrPurge` purged the
    /// sidecar; the fresh download starts from byte 0. Distinct from
    /// `.fresh` so the GUI surface can render the abandonment
    /// rather than silently re-fetching — review v18 user-facing
    /// observability pass.
    case restartedAfterCorruptResume
  }

  public let handleID: UUID
  public let phase: Phase
  public let bytesReceived: Int64
  public let bytesExpected: Int64?
  public let etaSeconds: Double?
  public let verification: VerificationStatus?
  public let startReason: StartReason?
  /// Human-readable producer reason that accompanies `phase ==
  /// .failed`. Nil for every non-failure phase, and Codable so the
  /// XPC payload preserves it across the wire (review v3 F24 —
  /// downstream consumers were inventing "download failed" strings
  /// because the actual `DownloadError` reason was being logged but
  /// never put on the AsyncStream payload).
  public let failureReason: String?

  public init(handleID: UUID,
              phase: Phase,
              bytesReceived: Int64,
              bytesExpected: Int64?,
              etaSeconds: Double?,
              verification: VerificationStatus? = nil,
              startReason: StartReason? = nil,
              failureReason: String? = nil) {
    self.handleID = handleID
    self.phase = phase
    self.bytesReceived = bytesReceived
    self.bytesExpected = bytesExpected
    self.etaSeconds = etaSeconds
    self.verification = verification
    self.startReason = startReason
    self.failureReason = failureReason
  }
}

/// Failures specific to `ModelDownloader`. Distinct from `EngineError`
/// because the helper-side XPC adapter must re-stamp these into
/// `EngineErrorCode` slots at the wire boundary — keeping the
/// downloader's type private lets the test bundle assert on exact
/// causes without scraping wire bytes.
/// Structured cause that downstream consumers can branch on instead
/// of regex-scraping a free-form `message`. Carries the underlying
/// NSError's `domain`/`code` plus a best-effort POSIX errno
/// extracted from `NSUnderlyingErrorKey` or the error itself.
///
/// Review v7 F5: prior versions of `DownloadError.writeFailed`
/// flattened the underlying NSError via string interpolation; the
/// GUI / log scraper had no way to branch on EBUSY vs EPERM vs
/// EROFS for retry policy. `Equatable` + `Sendable` keep
/// `DownloadError` conformance.
public struct ErrorCause: Equatable, Sendable {
  public let domain: String
  public let code: Int
  public let posixErrno: Int32?

  public init(domain: String, code: Int, posixErrno: Int32? = nil) {
    self.domain = domain
    self.code = code
    self.posixErrno = posixErrno
  }

  /// Maximum number of `NSUnderlyingErrorKey` hops the cause-walk
  /// will follow. Review v10 F3: raised 4 → 6 because real field
  /// chains stack `NSURLErrorDomain` wrappers around Foundation
  /// file-IO chains that already nest 2-3 deep, pushing the POSIX
  /// bottom to hop 4-5. The original 4-hop bound silently
  /// truncated those.
  static let errorCauseWalkMaxHops = 6

  /// Walk `NSUnderlyingErrorKey` to surface a POSIX errno when the
  /// chain bottoms out at `NSPOSIXErrorDomain`. Foundation file-IO
  /// errors usually wrap POSIX one hop deep; structurally-legal
  /// multi-hop chains exist (e.g. `NSFileWriteUnknownError` →
  /// `NSFileWriteVolumeReadOnlyError` → `NSPOSIXErrorDomain/EROFS`).
  ///
  /// The hop bound is the SOLE termination guarantee here (review
  /// v9 F3 — the v8 `ObjectIdentifier` seen-set was load-bearing
  /// only for Cocoa-allocated chains; Foundation bridges Swift
  /// struct errors via a fresh `NSError` wrapper on every `as
  /// NSError` cast, so the seen-set could never trigger on a
  /// bridged producer and gave maintainers a false sense that the
  /// hop bound could be removed). Real producers cap chain depth at
  /// 2-3, sometimes up to 5 when an outer transport wrapper layers
  /// on; bound is set at 6 to leave headroom without exposing a
  /// runaway path.
  ///
  /// Review v11 F1 + F5: emits `.notice` (was `.debug` in v10) when
  /// the walk truncates with a remaining chain. `.debug` was
  /// filtered out of default-persisted unified logging, so the
  /// truncation telemetry the bound-hit signal was meant to provide
  /// could never surface in a sysdiagnose bundle — the same
  /// antipattern v10 F1 fixed for the orphan-detected cause line.
  /// `.notice` is the default persistence level, so the next time
  /// field chains grow past the bound the team has passive
  /// telemetry to detect it before the silent-truncation pattern
  /// re-emerges.
  public static func from(_ error: Error) -> ErrorCause {
    let ns = error as NSError
    let posix: Int32? = {
      if let pe = error as? POSIXError {
        return Int32(pe.code.rawValue)
      }
      var current: NSError? = ns
      var hops = 0
      while let here = current, hops < errorCauseWalkMaxHops {
        if here.domain == NSPOSIXErrorDomain { return Int32(here.code) }
        current = here.userInfo[NSUnderlyingErrorKey] as? NSError
        hops += 1
      }
      if let truncated = current {
        Logger(subsystem: "com.ratiothink.app.helper", category: "downloader")
          .notice("ErrorCause: hop bound \(errorCauseWalkMaxHops, privacy: .public) reached, posix walk truncated at domain=\(truncated.domain, privacy: .public) code=\(truncated.code, privacy: .public)")
      }
      return nil
    }()
    return ErrorCause(domain: ns.domain, code: ns.code, posixErrno: posix)
  }
}

public enum DownloadError: Error, Equatable, Sendable {
  case unknownHandle
  case cancelled
  case alreadyInFlight(repo: String, file: String)
  /// `resumeAvailable` is `true` when URLSession produced a resume
  /// blob AND we successfully persisted (and fsynced) it next to the
  /// destination. `false` when either no blob was offered or the
  /// sidecar write/fsync itself failed — in that case a retry will
  /// restart from byte 0 (review v2 F5). The GUI uses this to decide
  /// whether to warn the user before offering "Retry".
  /// `urlErrorCode` carries the underlying `URLError.Code.rawValue`
  /// (e.g. `NSURLErrorTimedOut`) when the failure originated from a
  /// `URLSession` transport error, so `userFacingMessage` can render a
  /// specific "timed out" / "check your connection" caption instead of
  /// a generic one (#720). `nil` for synthesized transport failures
  /// with no `URLError` origin (e.g. the missing-finish-callback
  /// reclaim path).
  case transportFailed(message: String, resumeAvailable: Bool, urlErrorCode: Int?)
  case sha256Mismatch(expected: String, actual: String)
  /// `cause` carries the underlying NSError's `domain`/`code` plus
  /// POSIX errno (when extractable) so the GUI / log scraper can
  /// branch on EBUSY/EPERM/EROFS for retry policy without parsing
  /// `message` (review v7 F5). `nil` for synthesized failures whose
  /// origin is a Swift-side guard rather than a syscall.
  case writeFailed(message: String, cause: ErrorCause?)
  case modelsRootUnavailable(message: String)
  /// XPC client supplied a `repo`/`file` (or other argument) that
  /// failed input validation: `..` segment, leading `/`, NUL byte,
  /// post-resolution descendant escape, or a URL the builder could
  /// not encode. Distinguished from `.modelsRootUnavailable` so the
  /// GUI / log scraper can separate "disk locked, retry later" from
  /// "we just rejected a malformed (possibly malicious) XPC payload"
  /// — the latter is a wire-contract violation, not a retryable
  /// transient. Review v16 F2.
  case invalidArguments(message: String)
  case httpStatus(code: Int)
}

extension DownloadError {
  /// Single source of clean, user-facing copy for a download failure
  /// (#720). The raw `DownloadError` (with its NSError dumps, paths,
  /// and digests) stays in the logs via `String(describing:)`; this is
  /// what the GUI shows in the download row / action-error slot.
  ///
  /// Mirrors the code-aware framing `LocalAPIState.failureReason` uses
  /// for engine failures: honest about the category, actionable where a
  /// retry helps, and never leaking the underlying transport string.
  public var userFacingMessage: String {
    switch self {
    case .transportFailed(_, _, let urlErrorCode):
      switch urlErrorCode {
      case NSURLErrorTimedOut:
        return "Download timed out — check your connection and try again."
      case NSURLErrorNotConnectedToInternet,
           NSURLErrorNetworkConnectionLost,
           NSURLErrorCannotFindHost,
           NSURLErrorCannotConnectToHost,
           NSURLErrorDNSLookupFailed:
        return "Can’t reach the server — check your internet connection and try again."
      default:
        return "Download failed because of a network problem. Try again."
      }
    case .httpStatus(let code):
      if code == 404 {
        return "That file wasn’t found on the server (HTTP 404)."
      }
      return "The server returned an error (HTTP \(code)). Try again later."
    case .sha256Mismatch:
      return "The download didn’t pass its integrity check. Try downloading it again."
    case .writeFailed:
      return "Couldn’t save the download — check available disk space and permissions."
    case .modelsRootUnavailable:
      return "Couldn’t access the models folder. Check disk space and permissions."
    case .invalidArguments:
      return "That download request was invalid."
    case .alreadyInFlight(_, let file):
      return "“\(file)” is already downloading."
    case .unknownHandle:
      return "This download is no longer active."
    case .cancelled:
      return "Download cancelled."
    }
  }
}

/// Manages background HF GGUF downloads on behalf of the Helper.
///
/// One instance per helper process; serializes its mutable state with
/// `OSAllocatedUnfairLock` because URLSession delegate callbacks land
/// on an arbitrary `OperationQueue` and `start` / `cancel` are called
/// from XPC selector queues. Marked `@unchecked Sendable` because the
/// `URLSession` reference is set once during init and the lock guards
/// every other field.
///
/// Wire layout per task:
///   `<modelsRoot>/<repo>/<file>`            — final placed file
///   `<modelsRoot>/<repo>/<file>.partial`    — verified payload pre-rename
///   `<modelsRoot>/<repo>/<file>.resume`     — URLSession resume blob
///
/// A user **cancel is a hard cancel** (#218): the in-flight task is
/// dropped with no resume blob and any existing `.resume` sidecar is
/// purged, so the next `start(repo:file:)` re-downloads from byte 0.
/// Resume blobs are still written on a *transport failure* (a network
/// drop mid-download, not a user cancel) so an automatic retry can
/// continue from where it stopped; those are stable across helper
/// restarts (URLSession serializes them as plist).
///
/// SHA-256 verification uses the `X-Linked-Etag` header HF's CDN
/// returns for LFS-backed assets — quoted lowercase hex digest, with
/// or without a leading `sha256:` namespace. When the header is
/// absent we surface `verification = .notAdvertised` on the terminal
/// `.completed` event so callers can decide whether to badge the
/// download as unverified (review v1 F14).
public final class ModelDownloader: NSObject, @unchecked Sendable {

  // MARK: - Injection seams

  /// Builds the canonical HF resolve URL for `<repo>/<file>`. Phase 2.5
  /// pins `revision=main`; selecting a non-default revision is tracked
  /// in .
  ///
  /// Returns `nil` when the inputs cannot produce a valid URL even
  /// after percent-encoding (in practice: unreachable when callers
  /// validate inputs via `rejectionForUnsafePathComponent` first, but
  /// nil-safety closes the gap so an XPC-supplied surprise doesn't
  /// crash the privileged helper — review v15 F2).
  public typealias URLBuilder = (_ repo: String, _ file: String) -> URL?

  public static let huggingFaceURLBuilder: URLBuilder = { repo, file in
    // Build with URLComponents + per-segment percent-encoding so raw
    // `#`, `?`, space, `+`, `=` in `repo`/`file` can't break URL
    // parsing or smuggle query/fragment delimiters into the path.
    // `.urlPathAllowed` permits `+` and `=` (RFC 3986 sub-delims),
    // which would survive into the URL string and be interpreted as
    // space / key separator by some downstream parsers. Subtract
    // them so a literal `+`/`=` becomes `%2B`/`%3D`. Encode each
    // `/`-split segment independently then assign to
    // `percentEncodedPath` so URLComponents doesn't re-encode the
    // `%` sentinels.
    let pathSegmentAllowed: CharacterSet = {
      var s = CharacterSet.urlPathAllowed
      s.remove(charactersIn: "+=")
      return s
    }()
    func encodeSegments(_ s: String) -> String? {
      let parts = s.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
      var encoded: [String] = []
      encoded.reserveCapacity(parts.count)
      for part in parts {
        guard let e = part.addingPercentEncoding(withAllowedCharacters: pathSegmentAllowed) else {
          return nil
        }
        encoded.append(e)
      }
      return encoded.joined(separator: "/")
    }
    guard let repoPath = encodeSegments(repo), let filePath = encodeSegments(file) else {
      return nil
    }
    var components = URLComponents()
    components.scheme = "https"
    components.host = "huggingface.co"
    components.percentEncodedPath = "/\(repoPath)/resolve/main/\(filePath)"
    components.queryItems = [URLQueryItem(name: "download", value: "true")]
    return components.url
  }

  // MARK: - Private state

  private struct ActiveDownload {
    let handle: DownloadHandle
    var task: URLSessionDownloadTask
    let destinationDir: URL
    let destination: URL
    let partial: URL
    let resumeFile: URL
    var expectedSHA256: String?
    let startedAt: Date
    var totalBytes: Int64?
    var receivedBytes: Int64
    var continuations: [UUID: AsyncStream<DownloadProgress>.Continuation]
    var lastProgress: DownloadProgress
    /// Set when `didFinishDownloadingTo` has captured the temp file
    /// and dispatched `completeDownload` to the verify queue. Used by
    /// `didCompleteWithError(nil)` to distinguish "URLSession skipped
    /// the finish callback" (F15 reclaim path) from "finish callback
    /// fired and the completion is still in flight on the verify
    /// queue" (normal path — don't touch state).
    var didFinishCallbackFired: Bool = false
    /// Set by `completeDownload` once verification has passed and
    /// the placement syscall is imminent; cleared after `finishAll`.
    /// `finishCancelled` checks this flag — if `true`, the placement
    /// is past the point of no-cleanup-without-disk-fight, so the
    /// cancel is dropped as a no-op (placement-wins semantics) and
    /// the subscriber receives `.completed`, not `.cancelled`
    /// (review v3 F5 — the prior v2 gate only narrowed the window,
    /// did not close it).
    var placementInProgress: Bool = false
    /// Tracks whether we already auto-restarted this handle after a
    /// `NSURLErrorCannotOpenFile` / `CannotCreateFile` raised by an
    /// orphan resume blob (review v3 F6). Prevents an infinite loop
    /// if the fresh restart fails the same way.
    var resumeOpenFailureRestartAttempted: Bool = false
    /// Wall-clock of the last `.downloading` frame actually PUBLISHED to
    /// subscribers (#218). `didWriteData` fires per network chunk
    /// (hundreds/sec on a fast link); publishing each one floods the
    /// consumer's `@MainActor` and makes the UI janky + delays the
    /// cancel response. `nil` until the first frame publishes. Throttle
    /// only gates the PUBLISH — `lastProgress`/`receivedBytes` are
    /// updated every chunk so a late subscriber still sees current bytes.
    var lastDownloadingPublishAt: Date? = nil
  }

  private struct State {
    var active: [UUID: ActiveDownload] = [:]
    var taskToHandle: [Int: UUID] = [:]
    /// `<repo>/<file>` → handle ID. Used to refuse a second concurrent
    /// download of the same path.
    var inFlightByPath: [String: UUID] = [:]
    /// Bounded snapshot cache so a `progress(for:)` call that arrives
    /// after the download terminated still observes the terminal
    /// `DownloadProgress` instead of getting an immediately-finished
    /// stream indistinguishable from an unknown handle (review v1 F2).
    /// Insertion-ordered; trimmed at the head when it exceeds
    /// `terminalCacheCap` (review v1 F2).
    var terminalCache: [(UUID, DownloadProgress)] = []
  }

  /// Cap on the terminal-snapshot cache. 64 is enough headroom for a
  /// typical GUI session that might have several models queued; the
  /// cap exists so a helper running for days doesn't accumulate
  /// unbounded snapshots.
  private static let terminalCacheCap = 64

  /// Minimum wall-clock gap between published `.downloading` frames
  /// (#218). 0.1s = 10 Hz — smooth for a progress bar while collapsing
  /// the hundreds-of-chunks-per-second `didWriteData` flood that
  /// otherwise re-renders the consumer's download list per chunk and
  /// stalls the cancel response. The terminal phases
  /// (`.verifying`/`.completed`/`.cancelled`/`.failed`) bypass the
  /// throttle, so the final byte count always reaches subscribers.
  static let downloadingPublishMinInterval: TimeInterval = 0.1

  /// Producer-side throttle decision for `.downloading` frames. Publish
  /// when this is the first frame, when the download just reached
  /// 100%-by-bytes (so the bar visibly fills before `.verifying`), or
  /// when at least `minInterval` has elapsed since the last published
  /// frame. Pure function so the policy is unit-testable without driving
  /// `URLSession` at chunk granularity.
  static func shouldPublishDownloadingFrame(
    now: Date,
    lastPublishedAt: Date?,
    minInterval: TimeInterval,
    bytesReceived: Int64,
    totalBytes: Int64?
  ) -> Bool {
    guard let last = lastPublishedAt else { return true }
    if let total = totalBytes, total > 0, bytesReceived >= total { return true }
    return now.timeIntervalSince(last) >= minInterval
  }

  private let log = Logger(subsystem: "com.ratiothink.app.helper", category: "downloader")
  private let modelsRootProvider: () throws -> URL
  private let urlBuilder: URLBuilder
  private let fileManager: FileManager
  /// `rename(2)` used by `completeDownload`'s atomic placement.
  /// Internal (not public) test seam: `@testable` tests assign a hook
  /// BEFORE `start()` to interpose at the exact moment the GGUF becomes
  /// visible — e.g. to assert the `.unverified` danger-marker is
  /// already on disk before placement (review v3 F11 ordering
  /// invariant). Defaults to the real syscall. Kept internal so the
  /// public init does not have to expose the internal `RenameResult`
  /// type; production code never reassigns it.
  var renameSyscall: @Sendable (UnsafePointer<CChar>, UnsafePointer<CChar>) -> RenameResult
    = ModelDownloader.posixRenameSyscall
  private let lock = OSAllocatedUnfairLock(initialState: State())
  private var session: URLSession!

  /// Background queue for hashing + final placement. Verify is hopped
  /// off the URLSession delegate queue (review v1 F5) because hashing a
  /// multi-GiB GGUF would otherwise block every other download's
  /// progress and cancel-with-resume-data callbacks. `.utility` matches
  /// the user-initiated-but-not-foreground priority a download
  /// completion fits.
  ///
  /// Internal-visibility so tests under `@testable import` can
  /// `suspend()` / `resume()` the queue to deterministically provoke
  /// the cancel-vs-verifyQueue race the v2 F1 gate guards against.
  /// Production code MUST NOT call suspend/resume here.
  let verifyQueue = DispatchQueue(
    label: "com.ratiothink.app.helper.downloader.verify",
    qos: .utility,
    attributes: .concurrent
  )

  // MARK: - Init

  public init(sessionConfiguration: URLSessionConfiguration = .default,
              modelsRoot: @escaping () throws -> URL = { try PieDirs.models() },
              urlBuilder: @escaping URLBuilder = ModelDownloader.huggingFaceURLBuilder,
              fileManager: FileManager = .default) {
    self.modelsRootProvider = modelsRoot
    self.urlBuilder = urlBuilder
    self.fileManager = fileManager
    super.init()
    let queue = OperationQueue()
    queue.name = "com.ratiothink.app.helper.downloader.delegate"
    queue.maxConcurrentOperationCount = 1
    self.session = URLSession(configuration: sessionConfiguration,
                              delegate: self,
                              delegateQueue: queue)
  }

  /// Tear the URLSession down. The helper itself never calls this in
  /// production (the downloader's lifetime equals the helper process'),
  /// but tests need it so URLProtocol stubs aren't kept alive by an
  /// idle session.
  public func invalidate() {
    session.invalidateAndCancel()
  }

  // MARK: - Public API

  /// Start a download for `<repo>/<file>`. Returns a handle whose `id`
  /// uniquely identifies this attempt; the GUI uses it to subscribe to
  /// progress (`progress(for:)`) and cancel (`cancel(handle:)`).
  ///
  /// Refuses with `.alreadyInFlight` when a download for the same path
  /// is already running. Refuses with `.modelsRootUnavailable` when
  /// `PieDirs.models()` throws.
  public func start(repo: String, file: String) -> Result<DownloadHandle, DownloadError> {
    let pathKey = "\(repo)/\(file)"
    let modelsRoot: URL
    do {
      modelsRoot = try modelsRootProvider()
    } catch {
      log.error("start \(pathKey, privacy: .public): modelsRoot unavailable: \(String(describing: error), privacy: .public)")
      return .failure(.modelsRootUnavailable(message: String(describing: error)))
    }
    // Review v15 F1 / v16 F1: validate XPC-supplied `repo`/`file`
    // BEFORE any filesystem op. `appendingPathComponent` does NOT
    // normalize `..` segments, so a malicious GUI/XPC client could
    // supply `repo="../../Users/$USER/Library/LaunchAgents"` and have
    // the privileged helper create dirs + atomic-replace files
    // anywhere under the helper UID. Reject absolute paths, `..`
    // segments, NUL bytes, and empty/empty-segment inputs early.
    //
    // Then verify the composed `destination` resolves to a descendant
    // of `modelsRoot` via `resolvingSymlinksInPath()` — which calls
    // `realpath(3)` (review v16 F1). `standardizedFileURL` does only
    // lexical normalization (`.`/`..`) and would NOT catch a planted
    // symlink at `<modelsRoot>/<name> → /Users/$USER/Library/...`
    // through which `repo="<name>"` (no `..`) would let the helper
    // atomic-rename outside the real models root. Failure to
    // resolve the rooted prefix surfaces as `.invalidArguments` so
    // the GUI / scraper sees a wire-contract-violation code rather
    // than the retryable `.modelsRootUnavailable`.
    if let reject = Self.rejectionForUnsafePathComponent(repo, role: "repo") {
      log.error("start \(pathKey, privacy: .public): \(reject, privacy: .public)")
      return .failure(.invalidArguments(message: reject))
    }
    if let reject = Self.rejectionForUnsafePathComponent(file, role: "file") {
      log.error("start \(pathKey, privacy: .public): \(reject, privacy: .public)")
      return .failure(.invalidArguments(message: reject))
    }
    let destinationDir = modelsRoot.appendingPathComponent(repo, isDirectory: true)
    let destination = destinationDir.appendingPathComponent(file)
    // `URL.resolvingSymlinksInPath()` resolves links ONLY on path
    // components that exist on disk; a non-existent leaf is returned
    // unchanged. So resolving `destination` directly cannot detect a
    // symlink-in-the-middle when the leaf file doesn't exist yet
    // (the normal case for a fresh download). Resolve the deepest
    // ancestor that DOES exist instead, which catches any planted
    // symlink in `destinationDir`'s chain. Review v16 F1.
    let rootResolved = modelsRoot.resolvingSymlinksInPath().path
    let destResolved = Self.resolveExistingAncestor(of: destination).path
    let rootPrefix = rootResolved.hasSuffix("/") ? rootResolved : rootResolved + "/"
    guard destResolved == rootResolved || destResolved.hasPrefix(rootPrefix) else {
      let msg = "start: composed destination escapes modelsRoot after symlink resolution (resolved=\(destResolved) root=\(rootResolved))"
      log.error("\(msg, privacy: .public)")
      return .failure(.invalidArguments(message: msg))
    }
    do {
      try fileManager.createDirectory(at: destinationDir,
                                      withIntermediateDirectories: true)
    } catch {
      log.error("start \(pathKey, privacy: .public): mkdir destinationDir failed: \(String(describing: error), privacy: .public)")
      return .failure(.writeFailed(message: "mkdir(\(destinationDir.path)): \(error)",
                                   cause: ErrorCause.from(error)))
    }
    let partial = destinationDir.appendingPathComponent(file + ".partial")
    let resumeFile = destinationDir.appendingPathComponent(file + ".resume")

    let handle = DownloadHandle(repo: repo, file: file)

    let dedupeResult: Result<DownloadHandle, DownloadError> = lock.withLock { state in
      if state.inFlightByPath[pathKey] != nil {
        return .failure(.alreadyInFlight(repo: repo, file: file))
      }
      state.inFlightByPath[pathKey] = handle.id
      return .success(handle)
    }
    guard case .success = dedupeResult else { return dedupeResult }

    // Defensive: if the canonical destination already exists, any
    // `.resume` next to it is by definition stale — either a previous
    // completion's cleanup failed (review v2 F3) or external storage
    // imported the file. Purge the sidecar before considering it.
    //
    // Review v6 F3 / v7 F4: when the canonical destination already
    // exists, any adjacent `.resume` is by definition stale. This
    // site is the single greppable choke point for the orphan-
    // sidecar condition. Log at `.error` so an operator scanning
    // `log stream` can find concrete evidence (path + handle
    // context); the routine cancel-blob write at the OTHER site
    // uses the `cancel-blob:write` token (`.info`) and is filtered
    // out by an `eventMessage CONTAINS "cancel-blob:orphan-detected"`
    // predicate.
    //
    // Possible causes (enumerated, none asserted as most-likely):
    //  (a) cancel-vs-placement TOCTOU — the cancel-closure's
    //      resume-blob write landed AFTER `completeDownload` placed
    //      the destination (see cancel-closure TRADE-OFF comment).
    //  (b) prior completion's `.resume` cleanup failed under
    //      EROFS / AV-lock / indexer hold (review v2 F3).
    //  (c) external import — user copied the destination file in
    //      from elsewhere, leaving an old sidecar from a prior
    //      attempt next to it.
    // Inspection of file mtimes + recent cancel logs distinguishes
    // these; the log line carries paths so an operator can correlate
    // manually.
    if fileManager.fileExists(atPath: destination.path) {
      if fileManager.fileExists(atPath: resumeFile.path) {
        // Two log lines so each fits comfortably under OSLog's
        // 1024-byte soft limit even with deep sandboxed paths, while
        // still giving an operator with `log stream` (no source
        // access — third-party deployments, support triage from log
        // bundles) the cause partition they need to pick next
        // investigation steps (review v8 F4 → v9 F4). Both lines
        // share the `cancel-blob:orphan-detected` prefix so they
        // grep-correlate as a single event.
        log.error("cancel-blob:orphan-detected sidecar=\(resumeFile.path, privacy: .public) destination=\(destination.path, privacy: .public)")
        // Review v10 F1: emit at `.notice` (was `.info` in v9) so
        // the cause partition lives in default-persisted unified
        // logging. `.info` is suppressed unless the subsystem is
        // configured via `log config --mode "level:info"`, so
        // sysdiagnose bundles and third-party support triage lost
        // the partition entirely. `.notice` matches the default
        // persistence level without amplifying volume the way
        // `.error` (paired with the actual error headline above)
        // would.
        log.notice("cancel-blob:orphan-detected:causes (a)toctou-cancel-vs-placement (b)prior-cleanup-blocked (c)external-import")
      }
      purgeResumeSidecar(resumeFile, pathKey: pathKey)
    }

    // Load `.resume` defensively. Truncated / permission-denied reads
    // delete the sidecar so a future retry doesn't keep re-reading the
    // poisoned blob (review v1 F3). File-not-exists is the normal
    // first-start case and falls through to a fresh download task.
    //
    // Review v18: `untrusted == true` means the sidecar (or its
    // unsafe-sentinel) was present but we couldn't use it (corrupt,
    // unreadable, missing keys, or dir-entry possibly lost). The
    // fresh-restart path emits `.restartedAfterCorruptResume` so
    // the GUI distinguishes "had resume data, was bad" from a
    // clean first start.
    let (resumeData, untrusted) = loadResumeBlobOrPurge(resumeFile: resumeFile, pathKey: pathKey)
    let task: URLSessionDownloadTask
    let startReason: DownloadProgress.StartReason
    if let resumeData {
      log.info("start \(pathKey, privacy: .public): resuming from \(resumeData.count, privacy: .public)B resume blob")
      task = session.downloadTask(withResumeData: resumeData)
      startReason = .resumed
    } else {
      // Review v15 F2 / v16 F2: builder may return nil for inputs
      // that produce an invalid URL even after percent-encoding. F1
      // validation already rejects the known-dangerous shapes
      // upstream, but failing closed here closes the defense-in-
      // depth gap. Surface as `.invalidArguments` (wire-contract
      // violation, not retryable) so the GUI doesn't route this to
      // auto-retry.
      guard let url = urlBuilder(repo, file) else {
        let msg = "start: URL builder rejected repo=\(repo) file=\(file)"
        log.error("\(msg, privacy: .public)")
        lock.withLock { $0.inFlightByPath[pathKey] = nil }
        return .failure(.invalidArguments(message: msg))
      }
      task = session.downloadTask(with: url)
      // A sidecar that was present but unusable (corrupt/unreadable,
      // missing keys, or unsafe-sentinel) surfaces as a distinct
      // restart reason so the GUI can render the byte-0 abandonment
      // rather than a silent re-fetch; otherwise it's a clean cold start.
      startReason = untrusted ? .restartedAfterCorruptResume : .fresh
    }

    let startProgress = DownloadProgress(handleID: handle.id,
                                         phase: .starting,
                                         bytesReceived: 0,
                                         bytesExpected: nil,
                                         etaSeconds: nil,
                                         verification: nil,
                                         startReason: startReason)
    let active = ActiveDownload(handle: handle,
                                task: task,
                                destinationDir: destinationDir,
                                destination: destination,
                                partial: partial,
                                resumeFile: resumeFile,
                                expectedSHA256: nil,
                                startedAt: Date(),
                                totalBytes: nil,
                                receivedBytes: 0,
                                continuations: [:],
                                lastProgress: startProgress)
    lock.withLock { state in
      state.active[handle.id] = active
      state.taskToHandle[task.taskIdentifier] = handle.id
    }
    task.resume()
    log.info("start \(pathKey, privacy: .public): handle=\(handle.id.uuidString, privacy: .public) task=\(task.taskIdentifier, privacy: .public)")
    return .success(handle)
  }

  /// Cancel an in-flight download — **hard cancel, no resume** (#218).
  /// Issues a plain `task.cancel()` so URLSession tears the connection
  /// down and discards its temp file WITHOUT producing a resume blob,
  /// then synchronously emits `.cancelled` and tears the handle down via
  /// `finishCancelled`. The UI therefore flips the instant the user
  /// confirms, instead of waiting on CFNetwork to serialize resume data
  /// (the old `cancel(byProducingResumeData:)` deferred `.cancelled`
  /// until `didCompleteWithError`, which queued behind the per-chunk
  /// progress flood — the user-perceived "slow cancel"). Any pre-existing
  /// `.resume` sidecar for this path is purged so the next `start()`
  /// re-downloads from byte 0. Returns `.unknownHandle` when the id
  /// doesn't match a live download.
  ///
  /// Placement-wins (review v3 F5) is preserved: `finishCancelled`
  /// re-checks `placementInProgress` under the lock, so a cancel that
  /// races a winning placement is dropped and the subscriber correctly
  /// sees `.completed`. The synchronous `finishCancelled` here and the
  /// one in `didCompleteWithError(NSURLErrorCancelled)` are mutually
  /// idempotent — `mutateAndPublish` no-ops once `finishAll` has removed
  /// the handle, so exactly one `.cancelled` is emitted regardless of
  /// which runs first.
  public func cancel(handle: DownloadHandle) -> DownloadError? {
    let captured: (URLSessionDownloadTask, URL)? = lock.withLock { state in
      guard let active = state.active[handle.id] else { return nil }
      return (active.task, active.resumeFile)
    }
    guard let (task, resumeFile) = captured else { return .unknownHandle }
    // Plain cancel: no `byProducingResumeData`. The user confirmed a hard
    // cancel, so resumable state is deliberately dropped — URLSession
    // discards its temp file and emits `didCompleteWithError(.cancelled)`
    // promptly (no resume-blob serialization to wait on).
    task.cancel()
    // Purge any pre-existing `.resume` sidecar (e.g. from a prior
    // transport-failure retry) so the next `start()` for this path is a
    // clean byte-0 download rather than a silent resume.
    do {
      try Self.removeIgnoringNoSuchFile(resumeFile, fileManager: fileManager)
    } catch {
      log.error("cancel handle=\(handle.id.uuidString, privacy: .public): .resume purge failed at \(resumeFile.path, privacy: .public): \(String(describing: error), privacy: .public)")
    }
    // Emit `.cancelled` synchronously (placement-wins re-checked inside).
    // `.partial` cleanup is intentionally left to `completeDownload`'s
    // vanished-handle gate so we never race `placeAtomic`'s rename of
    // `.partial` into the destination.
    finishCancelled(handle.id)
    log.info("cancel handle=\(handle.id.uuidString, privacy: .public) (hard-cancel, no resume)")
    return nil
  }

  /// Subscribe to progress events for `handle`.
  ///
  /// Three outcomes:
  /// - **Active**: yields the current `lastProgress` immediately, every
  ///   subsequent transition, and finishes on terminal events.
  /// - **Terminal cache hit** (review v1 F2): yields the cached
  ///   terminal snapshot once, then finishes. Lets the GUI subscribe
  ///   after the row went green and still observe the terminal phase.
  /// - **Unknown handle**: finishes with no events. Callers
  ///   distinguish "completed before subscribe" (one event then
  ///   finish) from "unknown handle" (no event, immediate finish).
  public func progress(for handle: DownloadHandle) -> AsyncStream<DownloadProgress> {
    AsyncStream { continuation in
      let token = UUID()
      enum Outcome {
        case active(DownloadProgress)
        case terminal(DownloadProgress)
        case unknown
      }
      let outcome = lock.withLock { state -> Outcome in
        if var active = state.active[handle.id] {
          active.continuations[token] = continuation
          state.active[handle.id] = active
          return .active(active.lastProgress)
        }
        if let cached = state.terminalCache.first(where: { $0.0 == handle.id })?.1 {
          return .terminal(cached)
        }
        return .unknown
      }
      switch outcome {
      case .active(let snap):
        continuation.yield(snap)
        continuation.onTermination = { [weak self] _ in
          self?.lock.withLock { state in
            if var active = state.active[handle.id] {
              active.continuations.removeValue(forKey: token)
              state.active[handle.id] = active
            }
          }
        }
      case .terminal(let snap):
        continuation.yield(snap)
        continuation.finish()
      case .unknown:
        continuation.finish()
      }
    }
  }

  // MARK: - Internals

  /// Keys URLSession's resume-data plist must contain for
  /// `downloadTask(withResumeData:)` to be safe to call. CFNetwork's
  /// `_expandResumeData` raises an uncatchable Obj-C exception when
  /// the dict is missing these (review v1 F3 — observed at
  /// `+[__NSCFLocalDownloadTask _expandResumeData:]`).
  ///
  /// Keys are public CFNetwork constants but not exported as Swift
  /// API; we string-match the names that have been stable since
  /// macOS 10.9. `NSURLSessionResumeInfoVersion` alone is enough — it
  /// gates every code path inside CFNetwork's expander.
  private static let resumeDataRequiredKeys: Set<String> = [
    "NSURLSessionResumeInfoVersion",
    "NSURLSessionDownloadURL",
  ]

  /// Try to load the `.resume` sidecar.
  ///
  /// Outcomes:
  /// - File missing → nil (normal first-start path).
  /// - File present + parseable as a plist dict with the keys
  ///   URLSession's resume-expander requires → returns the bytes.
  /// - Anything else (read error, non-plist, plist-but-missing keys)
  ///   → deletes the sidecar and returns nil. Validating before we
  ///   hand the blob to URLSession is critical: a malformed blob
  ///   reaches `_expandResumeData` which raises an Obj-C
  ///   `NSException` we can't catch from Swift, crashing the helper
  ///   process. Review v1 F3.
  /// Returns `(data, untrusted)`:
  ///   - `data: non-nil` — sidecar parsed and `.resumed` is safe.
  ///   - `data: nil, untrusted: false` — sidecar absent (normal
  ///     first-start case).
  ///   - `data: nil, untrusted: true` — sidecar (or unsafe-sentinel)
  ///     was present but unusable; we purged it and the caller must
  ///     surface `.restartedAfterCorruptResume` so the GUI / log
  ///     trail distinguishes "we had resume data but it was bad"
  ///     from a clean fresh start (v18 observability pass).
  ///
  /// The fresh download that follows this purge has no separate
  /// user-visible error event — the `.starting` event's
  /// `startReason = .restartedAfterCorruptResume` IS the visible
  /// signal. If that fresh task itself fails, the normal
  /// `.transportFailed` / `.httpStatus` / `.sha256Mismatch` /
  /// `.writeFailed` paths surface to the caller as terminal
  /// `.failed` events. There is no silent restart path.
  private func loadResumeBlobOrPurge(resumeFile: URL, pathKey: String) -> (Data?, untrusted: Bool) {
    // Review v16 F4 / v17 F4: if a prior cancel-path dir-fsync failed
    // the sidecar's dir entry may not have survived a crash. The
    // sentinel was written then as a marker — purge BOTH and start
    // fresh rather than trust a possibly-lost entry. v17 F4 leaves
    // the sentinel in place when sidecar removal fails so next
    // start retries the purge.
    //
    // Review v18 user-facing observability: log at `.notice` (not
    // `.error`) — the situation is recovery-by-design, not a
    // helper-internal failure; `.notice` is OSLog's default-
    // persistence level so sysdiagnose still captures it without
    // amplifying the apparent severity in operator dashboards.
    let unsafe = Self.unsafeSentinelURL(forResumeFile: resumeFile)
    if fileManager.fileExists(atPath: unsafe.path) {
      log.notice("placeAtomic:sidecar-distrusted — previous cancel may not be durable; restarting from byte 0 (pathKey=\(pathKey, privacy: .public) sentinel=\(unsafe.path, privacy: .public))")
      purgeResumeSidecar(resumeFile, pathKey: pathKey)
      if fileManager.fileExists(atPath: resumeFile.path) {
        log.error("start \(pathKey, privacy: .public): sidecar still present after purge — leaving unsafe-sentinel in place so next start retries (\(resumeFile.path, privacy: .public))")
      } else {
        try? fileManager.removeItem(at: unsafe)
      }
      return (nil, untrusted: true)
    }
    guard fileManager.fileExists(atPath: resumeFile.path) else { return (nil, untrusted: false) }
    let data: Data
    do {
      data = try Data(contentsOf: resumeFile)
    } catch {
      log.error("start \(pathKey, privacy: .public): .resume read failed — purging sidecar: \(String(describing: error), privacy: .public)")
      purgeResumeSidecar(resumeFile, pathKey: pathKey)
      return (nil, untrusted: true)
    }
    let parsed: Any
    do {
      parsed = try PropertyListSerialization.propertyList(from: data, format: nil)
    } catch {
      log.error("start \(pathKey, privacy: .public): .resume plist parse failed — purging sidecar: \(String(describing: error), privacy: .public)")
      purgeResumeSidecar(resumeFile, pathKey: pathKey)
      return (nil, untrusted: true)
    }
    guard let dict = parsed as? [String: Any],
          Self.resumeDataRequiredKeys.isSubset(of: Set(dict.keys)) else {
      log.error("start \(pathKey, privacy: .public): .resume missing URLSession resume-data keys — purging sidecar")
      purgeResumeSidecar(resumeFile, pathKey: pathKey)
      return (nil, untrusted: true)
    }
    return (data, untrusted: false)
  }

  private func purgeResumeSidecar(_ resumeFile: URL, pathKey: String) {
    do {
      try fileManager.removeItem(at: resumeFile)
    } catch let removeError as NSError where Self.isFileNotFound(removeError) {
      return
    } catch {
      log.error("start \(pathKey, privacy: .public): .resume purge failed: \(String(describing: error), privacy: .public)")
    }
  }

  /// Apply `mutate` to the `ActiveDownload` keyed by `handleID` and
  /// publish the resulting progress snapshot to subscribers. Returns
  /// the mutated `ActiveDownload` so callers can act on its fields
  /// outside the lock. Returns nil when the handle vanished mid-flight
  /// (review v1 F16: logs the diagnostic so a silent drop is still
  /// observable in `log stream`).
  @discardableResult
  private func mutateAndPublish(_ handleID: UUID,
                                site: StaticString = #function,
                                _ mutate: (inout ActiveDownload) -> Void)
                                -> ActiveDownload? {
    let result = lock.withLock { state -> (ActiveDownload, [AsyncStream<DownloadProgress>.Continuation])? in
      guard var active = state.active[handleID] else { return nil }
      mutate(&active)
      state.active[handleID] = active
      return (active, Array(active.continuations.values))
    }
    guard let (active, conts) = result else {
      log.info("\(String(describing: site), privacy: .public): handle \(handleID.uuidString, privacy: .public) vanished mid-flight (no-op)")
      return nil
    }
    for c in conts { c.yield(active.lastProgress) }
    return active
  }

  /// Finalize a download. Re-reads the *current* continuations under
  /// the lock so a `progress(for:)` call that landed between
  /// `mutateAndPublish(terminal)` and this method still gets its
  /// continuation finished (review v1 F1 — the prior snapshot-only
  /// version leaked late subscribers). Also stashes the terminal
  /// snapshot in `state.terminalCache` for subscribe-after-complete
  /// consumers (review v1 F2).
  private func finishAll(_ active: ActiveDownload) {
    let conts: [AsyncStream<DownloadProgress>.Continuation] = lock.withLock { state in
      let current = state.active[active.handle.id]?.continuations.values.map { $0 } ?? []
      state.active.removeValue(forKey: active.handle.id)
      state.taskToHandle.removeValue(forKey: active.task.taskIdentifier)
      state.inFlightByPath.removeValue(forKey: "\(active.handle.repo)/\(active.handle.file)")
      state.terminalCache.append((active.handle.id, active.lastProgress))
      if state.terminalCache.count > Self.terminalCacheCap {
        state.terminalCache.removeFirst(state.terminalCache.count - Self.terminalCacheCap)
      }
      return current
    }
    for c in conts { c.finish() }
  }

  /// Pull a SHA-256 digest out of HF's `X-Linked-Etag` header. The CDN
  /// returns the LFS object's SHA-256 as a quoted lowercase hex digest;
  /// occasionally namespaced with a `sha256:` prefix. We accept both
  /// shapes and reject anything else as "verification not advertised."
  static func parseSHA256(fromXLinkedEtag header: String) -> String? {
    var v = header.trimmingCharacters(in: .whitespacesAndNewlines)
    if v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2 {
      v = String(v.dropFirst().dropLast())
    }
    if v.hasPrefix("sha256:") {
      v = String(v.dropFirst("sha256:".count))
    }
    let lower = v.lowercased()
    let isHex = lower.allSatisfy { $0.isHexDigit }
    return (lower.count == 64 && isHex) ? lower : nil
  }

  /// Extract a SHA-256 from an HTTPURLResponse's `X-Linked-Etag` (HF's
  /// LFS-backed content digest). nil when the header is absent or
  /// unparseable.
  ///
  /// ONLY `X-Linked-Etag` is trusted — there is intentionally no
  /// `Etag` fallback. On HF's Xet-backed CDN the final
  /// response's plain `ETag` is the Xet blob id: a 64-hex value that
  /// is NOT the file's sha256, so falling back to it produced a false
  /// `sha256Mismatch` on every modern GGUF. `X-Linked-Etag` rides only
  /// the `huggingface.co/resolve` 3xx response, which URLSession
  /// discards when it auto-follows the redirect — so the digest is
  /// captured in `willPerformHTTPRedirection` (the redirect delegate)
  /// rather than from `task.response`. `didWriteData` /
  /// `didFinishDownloadingTo` still re-read here for the rare direct
  /// (non-redirected) response that carries `X-Linked-Etag`, and
  /// because URLSession can surface buffered bytes before populating
  /// `task.response` on resumed tasks (review v1 F8).
  static func extractAdvertisedSHA256(from response: URLResponse?) -> String? {
    guard let http = response as? HTTPURLResponse else { return nil }
    guard let raw = http.value(forHTTPHeaderField: "X-Linked-Etag") else { return nil }
    return parseSHA256(fromXLinkedEtag: raw)
  }

  /// Stream-hash the file at `url`. 1 MiB chunks (CryptoKit `SHA256`
  /// is an incremental hasher) so we never page the whole GGUF into
  /// memory; `autoreleasepool` wraps the read loop because
  /// `FileHandle.read` returns autoreleased `Data` on Darwin.
  ///
  /// Propagates `FileHandle.close()` errors (review v1 F13). On
  /// network volumes `close(2)` can surface EIO that was queued during
  /// the read loop — swallowing it means the digest may have been
  /// computed over a short read, and the caller would treat the
  /// resulting hash as authoritative. Propagating fails verification
  /// instead, which is the safe default.
  static func sha256OfFile(at url: URL) throws -> String {
    var hasher = SHA256()
    let handle = try FileHandle(forReadingFrom: url)
    do {
      while true {
        let chunk = try autoreleasepool { () throws -> Data in
          try handle.read(upToCount: 1 << 20) ?? Data()
        }
        if chunk.isEmpty { break }
        hasher.update(data: chunk)
      }
      try handle.close()
    } catch {
      // Best-effort close on the error path — the original error is
      // the interesting one. A close-error here is redundant noise.
      try? handle.close()
      throw error
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  /// Force the file's data + metadata to stable storage before any
  /// rename. Uses `FileHandle.synchronize()` (wraps `fsync(2)`) +
  /// a best-effort `F_FULLFSYNC` via `fcntl` on the same descriptor —
  /// `F_FULLFSYNC` is the Darwin-only spelling that flushes the disk's
  /// write cache (regular `fsync(2)` does not on Darwin), but it's a
  /// best-effort path so a FS that rejects it still gets the standard
  /// `fsync` durability guarantee.
  ///
  /// Review v1 F6: without this, a power loss between rename and the
  /// next page-cache flush leaves the verified destination pointing
  /// at zeroed pages.
  static func fsyncFile(at url: URL, fileManager: FileManager) throws {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    // Best-effort F_FULLFSYNC; ignore failure and fall through to
    // FileHandle.synchronize().
    _ = fcntl(handle.fileDescriptor, F_FULLFSYNC)
    try handle.synchronize()
  }

  /// Force the directory entry holding the rename to disk. Same
  /// rationale as `fsyncFile` but on the parent dir, so the rename
  /// itself survives power loss. `FileHandle(forReadingFrom:)` on a
  /// directory URL succeeds on Darwin and gives us an fd we can
  /// fsync(2) — `synchronize()` is the Apple-blessed wrapper that
  /// avoids the manual `open(O_RDONLY)` + `Darwin.close` dance.
  static func fsyncDirectory(at url: URL) throws {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    _ = fcntl(handle.fileDescriptor, F_FULLFSYNC)
    try handle.synchronize()
  }

  /// `removeItem(at:)` that ignores "no such file" but surfaces every
  /// other error. Used in place of `try?` for cleanup steps where
  /// silently dropping EBUSY/EPERM/EROFS would leave landmines on
  /// disk (review v1 F11, F12).
  static func removeIgnoringNoSuchFile(_ url: URL, fileManager: FileManager) throws {
    do {
      try fileManager.removeItem(at: url)
    } catch let error as NSError where isFileNotFound(error) {
      return
    }
  }

  /// Result + errno surfaced by a `rename(2)`-shaped syscall.
  /// `result == 0` is success; otherwise `posixErrno` carries the
  /// cause. Field is named `posixErrno` (not `errno`) so any future
  /// closure-body code that reads the bare `errno` macro is
  /// syntactically jarring — a maintainer inserting a
  /// `log.debug("rename → \(r)")` between the `rename(2)` call and
  /// the snapshot below WILL clobber TLS errno (Logger calls
  /// malloc), so the value must be captured in the same expression
  /// as the syscall. Review v5 F3.
  struct RenameResult: Sendable {
    let result: Int32
    let posixErrno: Int32
  }

  /// Carries either a `rename(2)` invocation result or the signal
  /// that the URL could not be encoded into the filesystem
  /// representation at all (`withUnsafeFileSystemRepresentation`
  /// yielded nil). Distinct from `RenameResult` so callers can throw
  /// a typed error for the unrepresentable case instead of
  /// overloading errno=22 — real `rename(2)` returns EINVAL for
  /// legitimate kernel-rejected arg combinations, and retry policy
  /// keyed on the errno needs to tell those apart (review v16 F3).
  enum RenameOutcome {
    case unrepresentable(PathUnrepresentable.Which)
    case result(RenameResult)
  }

  /// Thrown by `placeAtomic` when Foundation could not encode the
  /// source or destination URL into a filesystem representation
  /// suitable for the libSystem `rename(2)` syscall. Surfaces as a
  /// caller-bug class of failure rather than a transient — retry
  /// policy should NOT auto-retry the same paths (review v16 F3).
  ///
  /// `Equatable` + `Sendable` so the error can cross actor / Task
  /// boundaries under Swift 6 strict-concurrency without an
  /// `@unchecked` escape hatch — `placeAtomic` is called from
  /// `verifyQueue` and the thrown error propagates back through
  /// `completeDownload`'s catch arm into the publish path which
  /// touches multiple queues (review v17 F6). `which` preserves the
  /// failure-class discriminator (partial-only vs destination-only
  /// vs both unrepresentable) through the `.invalidArguments`
  /// stringification so downstream callers can still pattern-match
  /// without parsing free-form message text.
  struct PathUnrepresentable: Error, Equatable, Sendable, CustomStringConvertible {
    enum Which: String, Equatable, Sendable {
      case partial
      case destination
      case both
    }
    let which: Which
    let partialPath: String
    let destinationPath: String
    var description: String {
      "placeAtomic: filesystem representation unavailable (which=\(which.rawValue)) for partial=\(partialPath) destination=\(destinationPath)"
    }
  }

  /// Production rename syscall closure. Default for `placeAtomic`.
  /// Wraps the libSystem `rename(2)` and captures `errno` in the
  /// same expression so a later Swift-side allocation can't clobber
  /// the TLS slot before we read it.
  static let posixRenameSyscall: @Sendable (UnsafePointer<CChar>, UnsafePointer<CChar>) -> RenameResult = { src, dst in
    let r = rename(src, dst)
    return RenameResult(result: r, posixErrno: r == 0 ? 0 : Darwin.errno)
  }

  /// Atomically place `partial` at `destination` via a single
  /// `rename(2)` syscall. `.partial` is always written into
  /// `destinationDir` (same directory as `destination`), so the
  /// source and destination are co-located on the same volume.
  /// EXDEV is therefore structurally impossible and there is no
  /// cross-volume fallback path.
  ///
  /// `renameSyscall` is injectable so tests can drive non-zero
  /// errno paths without a real failing fixture.
  static func placeAtomic(partial: URL,
                          destination: URL,
                          fileManager: FileManager,
                          log: Logger,
                          renameSyscall: @Sendable (UnsafePointer<CChar>, UnsafePointer<CChar>) -> RenameResult = posixRenameSyscall) throws {
    // `withUnsafeFileSystemRepresentation` yields nil when Foundation
    // cannot encode the URL into the filesystem representation
    // (exotic UTF-8 normalization, PATH_MAX overrun after intermediate
    // dir creation, etc.). Force-unwrapping would crash the privileged
    // helper on XPC-supplied input (review v15 F5). Review v16 F3:
    // throw a distinct typed error (`PathUnrepresentable`) rather
    // than synthesizing `RenameResult(-1, EINVAL)` — real `rename(2)`
    // returns EINVAL for legitimate kernel-rejected cases (dir into
    // own subdir, etc.) and overloading errno=22 makes the two
    // failure classes indistinguishable to retry-policy logic.
    // Capture WHICH URL was unrepresentable so the typed throw
    // preserves the failure-class discriminator through downstream
    // `.invalidArguments` mapping (review v17 F6).
    let outcome: RenameOutcome = partial.withUnsafeFileSystemRepresentation { src in
      destination.withUnsafeFileSystemRepresentation { dst -> RenameOutcome in
        switch (src, dst) {
        case (nil, nil): return .unrepresentable(.both)
        case (nil, _): return .unrepresentable(.partial)
        case (_, nil): return .unrepresentable(.destination)
        case (let src?, let dst?): return .result(renameSyscall(src, dst))
        }
      }
    }
    switch outcome {
    case .unrepresentable(let which):
      throw PathUnrepresentable(which: which,
                                partialPath: partial.path,
                                destinationPath: destination.path)
    case .result(let r):
      if r.result == 0 { return }
      throw POSIXError(POSIXError.Code(rawValue: r.posixErrno) ?? .EIO)
    }
  }

  /// Resolve symlinks on the deepest ancestor of `url` that exists
  /// on disk, then re-append the non-existent tail. `realpath(3)` /
  /// `URL.resolvingSymlinksInPath()` only follows links for path
  /// components that exist; a fresh download's destination has a
  /// non-existent leaf, so resolving the URL directly would miss a
  /// planted symlink in `destinationDir`'s chain. Walk up to find
  /// the deepest existing ancestor, resolve it, append the tail.
  /// Review v16 F1.
  static func resolveExistingAncestor(of url: URL) -> URL {
    let fm = FileManager.default
    var ancestor = url
    var tail: [String] = []
    while !fm.fileExists(atPath: ancestor.path) {
      let last = ancestor.lastPathComponent
      let parent = ancestor.deletingLastPathComponent()
      // Reached filesystem root with nothing existing — extremely
      // unlikely (`/` always exists) but guard against infinite loop.
      if parent.path == ancestor.path { break }
      tail.append(last)
      ancestor = parent
    }
    var resolved = ancestor.resolvingSymlinksInPath()
    for component in tail.reversed() {
      resolved = resolved.appendingPathComponent(component)
    }
    return resolved
  }

  /// Sibling-path of `<resumeFile>-unsafe` written by the cancel
  /// closure when `fsyncDirectory` fails. Presence at next `start()`
  /// signals the resume sidecar's dir entry may have been lost in a
  /// crash — `loadResumeBlobOrPurge` purges both files and forces a
  /// fresh download (review v16 F4).
  static func unsafeSentinelURL(forResumeFile resumeFile: URL) -> URL {
    let parent = resumeFile.deletingLastPathComponent()
    return parent.appendingPathComponent(resumeFile.lastPathComponent + "-unsafe")
  }

  /// Validate that an XPC-supplied path component (`repo` or `file`)
  /// cannot escape `modelsRoot` after composition. Returns `nil` when
  /// safe, or a human-readable rejection reason. Rules:
  ///   - non-empty
  ///   - no NUL bytes (filesystem refuses but C-string boundaries get
  ///     truncated silently in some paths)
  ///   - no leading `/` (absolute paths bypass `modelsRoot`)
  ///   - no `..` segments (parent-dir traversal)
  ///   - no empty interior segments (`foo//bar` normalizes weirdly)
  /// Allows `org/name` (single `/`) for `repo` since HF repos are
  /// always two-segment. `file` may itself contain `/` for
  /// subdirectory files (e.g. `quantized/Q4_K_M.gguf`) — same
  /// segment rules apply. Review v15 F1.
  static func rejectionForUnsafePathComponent(_ s: String, role: String) -> String? {
    if s.isEmpty {
      return "\(role) is empty"
    }
    if s.contains("\0") {
      return "\(role) contains NUL byte"
    }
    if s.hasPrefix("/") {
      return "\(role) is absolute path (leading '/')"
    }
    for segment in s.split(separator: "/", omittingEmptySubsequences: false) {
      if segment.isEmpty {
        return "\(role) has empty path segment"
      }
      if segment == ".." {
        return "\(role) contains '..' segment"
      }
    }
    return nil
  }

  static func isFileNotFound(_ error: NSError) -> Bool {
    (error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError)
      || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
  }
}

// MARK: - URLSessionDownloadDelegate

extension ModelDownloader: URLSessionDownloadDelegate {

  /// Capture HF's `X-Linked-Etag` from the redirect response before
  /// URLSession follows it and the header is lost. HF's
  /// `huggingface.co/resolve/main/<file>` returns a 3xx whose
  /// `X-Linked-Etag` is the LFS object's sha256; the redirect target
  /// is a Xet/S3 CDN whose final response carries no `X-Linked-Etag`
  /// (only a Xet blob-id `ETag` that is NOT the file sha256). Since
  /// `task.response` is the FINAL response, the digest must be lifted
  /// here. Capture-once (only when `expectedSHA256` is still nil) so a
  /// multi-hop chain or the orphan-resume restart's re-capture keeps
  /// the first HF-advertised digest. Always continue the redirect by
  /// passing `request` to the completion handler.
  public func urlSession(_ session: URLSession,
                         task: URLSessionTask,
                         willPerformHTTPRedirection response: HTTPURLResponse,
                         newRequest request: URLRequest,
                         completionHandler: @escaping (URLRequest?) -> Void) {
    if let advertised = ModelDownloader.extractAdvertisedSHA256(from: response) {
      let handleID = lock.withLock { state -> UUID? in
        guard let id = state.taskToHandle[task.taskIdentifier] else { return nil }
        guard var active = state.active[id], active.expectedSHA256 == nil else { return nil }
        active.expectedSHA256 = advertised
        state.active[id] = active
        return id
      }
      if let handleID {
        log.info("redirect: captured X-Linked-Etag digest for handle=\(handleID.uuidString, privacy: .public) task=\(task.taskIdentifier, privacy: .public)")
      }
    }
    completionHandler(request)
  }

  public func urlSession(_ session: URLSession,
                         downloadTask: URLSessionDownloadTask,
                         didWriteData bytesWritten: Int64,
                         totalBytesWritten: Int64,
                         totalBytesExpectedToWrite: Int64) {
    let handleID = lock.withLock { $0.taskToHandle[downloadTask.taskIdentifier] }
    guard let handleID else { return }
    let advertisedSHA = ModelDownloader.extractAdvertisedSHA256(from: downloadTask.response)
    let now = Date()
    // Producer-side throttle (#218): update the `lastProgress` snapshot +
    // byte counters on EVERY chunk (so a `progress(for:)` subscribe-after
    // still sees current bytes), but only YIELD to existing subscribers on
    // throttle boundaries — collapsing the per-chunk flood that re-renders
    // the consumer's download list and stalls the cancel response.
    let toYield: (DownloadProgress, [AsyncStream<DownloadProgress>.Continuation])? =
      lock.withLock { state in
      guard var active = state.active[handleID] else { return nil }
      if active.expectedSHA256 == nil, let advertisedSHA {
        active.expectedSHA256 = advertisedSHA
      }
      active.receivedBytes = totalBytesWritten
      let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
      active.totalBytes = expected
      let elapsed = now.timeIntervalSince(active.startedAt)
      let eta: Double? = {
        guard elapsed > 0.5,
              let expected,
              totalBytesWritten > 0,
              expected > totalBytesWritten else { return nil }
        let rate = Double(totalBytesWritten) / elapsed
        guard rate > 0 else { return nil }
        return Double(expected - totalBytesWritten) / rate
      }()
      let progress = DownloadProgress(handleID: handleID,
                                      phase: .downloading,
                                      bytesReceived: totalBytesWritten,
                                      bytesExpected: expected,
                                      etaSeconds: eta,
                                      verification: nil)
      active.lastProgress = progress
      let shouldPublish = Self.shouldPublishDownloadingFrame(
        now: now,
        lastPublishedAt: active.lastDownloadingPublishAt,
        minInterval: Self.downloadingPublishMinInterval,
        bytesReceived: totalBytesWritten,
        totalBytes: expected)
      if shouldPublish {
        active.lastDownloadingPublishAt = now
      }
      state.active[handleID] = active
      return shouldPublish ? (progress, Array(active.continuations.values)) : nil
    }
    if let (progress, conts) = toYield {
      for c in conts { c.yield(progress) }
    }
  }

  public func urlSession(_ session: URLSession,
                         downloadTask: URLSessionDownloadTask,
                         didFinishDownloadingTo location: URL) {
    let handleID = lock.withLock { $0.taskToHandle[downloadTask.taskIdentifier] }
    guard let handleID else { return }
    if let http = downloadTask.response as? HTTPURLResponse,
       !(200...299).contains(http.statusCode) {
      finishFailed(handleID, .httpStatus(code: http.statusCode))
      return
    }

    // Final-chance SHA capture (review v1 F8): a resumed task may have
    // flushed buffered bytes before `task.response` populated, so
    // `didWriteData` saw nil headers. Re-attempt here while we still
    // have a chance to verify. Also mark `didFinishCallbackFired` so
    // a racing `didCompleteWithError(nil)` doesn't spuriously trigger
    // the F15 reclaim path.
    let finalEtagSHA = ModelDownloader.extractAdvertisedSHA256(from: downloadTask.response)
    let active: ActiveDownload? = lock.withLock { state in
      guard var a = state.active[handleID] else { return nil }
      if a.expectedSHA256 == nil, let finalEtagSHA {
        a.expectedSHA256 = finalEtagSHA
      }
      a.didFinishCallbackFired = true
      state.active[handleID] = a
      return a
    }
    guard let active else {
      log.info("didFinishDownloadingTo: handle \(handleID.uuidString, privacy: .public) vanished — URLSession temp at \(location.path, privacy: .public) discarded")
      return
    }

    // Move temp → .partial synchronously: URLSession deletes the temp
    // file when this delegate method returns, so the move must
    // complete before we hop verification to the background queue.
    // `replaceItemAt` is atomic on Darwin and handles the
    // remove-then-rename window the prior fileExists/remove/move
    // sequence raced on (review v1 F7).
    do {
      try Self.removeIgnoringNoSuchFile(active.partial, fileManager: fileManager)
      try fileManager.moveItem(at: location, to: active.partial)
    } catch {
      finishFailed(handleID, .writeFailed(message: "move \(location.path) → \(active.partial.path): \(error)",
                                          cause: ErrorCause.from(error)))
      return
    }

    // Hop verify + rename to a background queue so a multi-GiB hash
    // doesn't block the URLSession delegate queue (review v1 F5).
    // The `active` entry stays in `state.active` until this work
    // completes — concurrent `start(repo:file:)` for the same path
    // still sees `.alreadyInFlight`.
    let captured = active
    verifyQueue.async { [weak self] in
      self?.completeDownload(captured)
    }
  }

  public func urlSession(_ session: URLSession,
                         task: URLSessionTask,
                         didCompleteWithError error: Error?) {
    let handleID = lock.withLock { $0.taskToHandle[task.taskIdentifier] }
    guard let handleID else { return }
    if error == nil {
      // Success path SHOULD route through `didFinishDownloadingTo` →
      // `completeDownload` → `finishAll` (which purges
      // `taskToHandle`). If we still resolve `handleID` here AND the
      // finish callback never fired, that path got skipped — reclaim
      // defensively so the handle doesn't leak in `inFlightByPath`
      // (review v1 F15). The `didFinishCallbackFired` check is
      // critical: didCompleteWithError(nil) fires AFTER
      // didFinishDownloadingTo's verify-queue dispatch but possibly
      // BEFORE `completeDownload` finishes; without the flag this
      // path would spuriously reclaim every successful download.
      let needsReclaim = lock.withLock { state -> Bool in
        guard let a = state.active[handleID] else { return false }
        return !a.didFinishCallbackFired
      }
      if needsReclaim {
        log.fault("didCompleteWithError(nil) with handle \(handleID.uuidString, privacy: .public) — URLSession skipped didFinishDownloadingTo; reclaiming")
        finishFailed(handleID,
                     .transportFailed(message: "download completed without finish callback",
                                      resumeAvailable: false,
                                      urlErrorCode: nil))
      }
      return
    }
    let nsErr = error! as NSError
    if nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled {
      // Delegate-side cancel completion. Hard-cancel (#218) emits
      // `.cancelled` synchronously from `cancel()`; this call is the
      // mutually-idempotent backstop — once `finishCancelled` →
      // `finishAll` removed the handle, `mutateAndPublish` no-ops, so
      // exactly one `.cancelled` is emitted regardless of order (see
      // the `cancel()` doc).
      finishCancelled(handleID)
      return
    }

    // Review v3 F6: orphan resume blob references a temp file that
    // no longer exists (process crash after cancel persisted the
    // blob + later /tmp cleanup or user deletion). CFNetwork
    // surfaces this as `NSURLErrorCannotOpenFile`. Auto-restart the
    // handle from byte 0 once — purge the sidecar, issue a fresh
    // `downloadTask(with:)`, swap into `state.active`. Track
    // `resumeOpenFailureRestartAttempted` so a same-error failure
    // on the fresh task doesn't loop forever.
    //
    // Review v4 F5: do NOT extend this trigger to
    // `NSURLErrorCannotCreateFile`. That code covers
    // destination-side failures (read-only FS, ENOSPC) which the
    // user's `.resume` did not cause and should not pay for —
    // purging the sidecar there would lose the resume position
    // *because* of a disk-full / permission diagnosis, then
    // re-fail the same way on the fresh task. Stay narrow.
    let resumeOpenFailed = nsErr.domain == NSURLErrorDomain
      && nsErr.code == NSURLErrorCannotOpenFile
    if resumeOpenFailed {
      let restartAttempted = lock.withLock { state -> Bool in
        state.active[handleID]?.resumeOpenFailureRestartAttempted ?? true
      }
      if !restartAttempted {
        if attemptOrphanResumeRestart(handleID: handleID, oldTaskID: task.taskIdentifier) {
          return
        }
      } else {
        log.error("didCompleteWithError(\(nsErr.code, privacy: .public)) for handle \(handleID.uuidString, privacy: .public): already retried once after orphan resume — surfacing failure")
      }
    }

    // Non-cancel error: persist resume data if URLSession attached one
    // so a later retry continues from the byte we stopped on. Track
    // whether persistence succeeded so the `.transportFailed`
    // carries an accurate `resumeAvailable` flag for in-process /
    // log diagnostics (review v2 F5 — wire surfacing deferred to
    //  per review v3 F1).
    var resumeAvailable = false
    if let resumeData = nsErr.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
      let resumeFile = lock.withLock { state in state.active[handleID]?.resumeFile }
      if let resumeFile {
        do {
          try resumeData.write(to: resumeFile, options: .atomic)
          try Self.fsyncFile(at: resumeFile, fileManager: fileManager)
          // Review v15 F4 / v16 F4: fsync the parent dir entry too —
          // file fsync alone does not flush the rename(2) that
          // `.atomic` write performs. If the dir-fsync fails (EIO,
          // fd-exhaustion), the dir entry may not survive a power
          // loss — we cannot promise the caller "sidecar is
          // durable", so leave `resumeAvailable = false`. A retry
          // will restart from byte 0; the GUI's "Retry" warning
          // covers this case.
          do {
            try Self.fsyncDirectory(at: resumeFile.deletingLastPathComponent())
            resumeAvailable = true
          } catch {
            log.error("fsyncDirectory(non-cancel resume) \(resumeFile.deletingLastPathComponent().path, privacy: .public) failed — marking resumeAvailable=false: \(String(describing: error), privacy: .public)")
          }
        } catch {
          log.error("persistResumeData(non-cancel) \(resumeFile.path, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
      }
    }
    // Carry the URL error code so `userFacingMessage` can render a
    // specific "timed out" / "check your connection" caption (#720).
    // Only meaningful for `NSURLErrorDomain` failures; other domains
    // fall through to the generic network copy.
    let urlErrorCode = nsErr.domain == NSURLErrorDomain ? nsErr.code : nil
    finishFailed(handleID,
                 .transportFailed(message: String(describing: error!),
                                  resumeAvailable: resumeAvailable,
                                  urlErrorCode: urlErrorCode))
  }

  /// Replace the failed (orphan-resume) task with a fresh
  /// `downloadTask(with:)` from byte 0. Returns true when the swap
  /// happened and the new task is running; false when the handle
  /// vanished (cancelled / invalidated) before we could swap.
  /// Review v3 F6 introduced; v4 F2/F3 hardened:
  /// - Reset `receivedBytes` / `totalBytes` / `startedAt` so
  ///   subscribers don't see byte progress run backwards mid-stream.
  /// - Emit a `.starting` event with `StartReason.restartedAfterOrphanResume`
  ///   so the GUI can render the rewind.
  /// - Clear `expectedSHA256` so the fresh response's `X-Linked-Etag`
  ///   is the only source of the digest — a benign HF re-upload
  ///   between the two requests must not surface as `.integrityFailed`.
  private func attemptOrphanResumeRestart(handleID: UUID,
                                          oldTaskID: Int) -> Bool {
    let snapshot: (DownloadHandle, URL)? = lock.withLock { state in
      guard let a = state.active[handleID] else { return nil }
      return (a.handle, a.resumeFile)
    }
    guard let (handle, resumeFile) = snapshot else { return false }
    log.error("didCompleteWithError: handle \(handleID.uuidString, privacy: .public) — orphan resume blob references missing temp file, restarting from byte 0")
    let pathKey = "\(handle.repo)/\(handle.file)"
    purgeResumeSidecar(resumeFile, pathKey: pathKey)
    // Review v15 F2: builder is now fallible. handle.repo / handle.file
    // were validated at start(), so reaching nil here means the
    // upstream invariants are broken — surface as transport failure
    // (sticks to existing finishFailed contract) rather than crash.
    guard let freshURL = urlBuilder(handle.repo, handle.file) else {
      log.error("attemptOrphanResumeRestart: URL builder returned nil for repo=\(handle.repo, privacy: .public) file=\(handle.file, privacy: .public)")
      return false
    }
    let freshTask = session.downloadTask(with: freshURL)
    let now = Date()
    let restartProgress = DownloadProgress(handleID: handleID,
                                           phase: .starting,
                                           bytesReceived: 0,
                                           bytesExpected: nil,
                                           etaSeconds: nil,
                                           verification: nil,
                                           startReason: .restartedAfterOrphanResume)
    let swapResult: (ActiveDownload, [AsyncStream<DownloadProgress>.Continuation])? =
      lock.withLock { state in
        guard var a = state.active[handleID] else { return nil }
        state.taskToHandle.removeValue(forKey: oldTaskID)
        a.task = freshTask
        a.resumeOpenFailureRestartAttempted = true
        a.didFinishCallbackFired = false
        a.receivedBytes = 0
        a.totalBytes = nil
        a.expectedSHA256 = nil
        // Reseat `startedAt` so subsequent ETA math is computed
        // from the fresh request, not the dead one (review v4 F2).
        // We can't mutate the `let` field by re-creating the struct
        // — capture the rest of the fields explicitly.
        let reseated = ActiveDownload(
          handle: a.handle,
          task: a.task,
          destinationDir: a.destinationDir,
          destination: a.destination,
          partial: a.partial,
          resumeFile: a.resumeFile,
          expectedSHA256: nil,
          startedAt: now,
          totalBytes: nil,
          receivedBytes: 0,
          continuations: a.continuations,
          lastProgress: restartProgress,
          didFinishCallbackFired: false,
          placementInProgress: a.placementInProgress,
          resumeOpenFailureRestartAttempted: true)
        state.active[handleID] = reseated
        state.taskToHandle[freshTask.taskIdentifier] = handleID
        return (reseated, Array(reseated.continuations.values))
      }
    guard let (_, continuations) = swapResult else {
      // Lost the swap race — handle was cancelled / invalidated
      // between the snapshot read and the swap lock. `freshTask`
      // was allocated (URLSession assigned it a taskIdentifier)
      // but never registered in `taskToHandle`. Cancelling it
      // releases CFNetwork's bookkeeping; a later
      // `didCompleteWithError(NSURLErrorCancelled)` for this task
      // will find no handle and silently drop. Log so the
      // unregistered-task drop is greppable (review v5 F4 — same
      // diagnostic-trail discipline as F15/F16).
      log.info("attemptOrphanResumeRestart: handle \(handleID.uuidString, privacy: .public) vanished during swap — discarding freshTask=\(freshTask.taskIdentifier, privacy: .public)")
      freshTask.cancel()
      return false
    }
    // Publish the restart event outside the lock so a slow
    // consumer can't block the URLSession delegate queue.
    for c in continuations { c.yield(restartProgress) }
    freshTask.resume()
    return true
  }

  // MARK: - terminal helpers

  /// Background-queue tail of `didFinishDownloadingTo`: hash the
  /// `.partial`, atomically place it at `destination`, fsync the file
  /// + parent dir, and emit `.completed`. Errors at any step finalize
  /// the handle via `finishFailed`.
  private func completeDownload(_ active: ActiveDownload) {
    let handleID = active.handle.id

    // Vanished-handle gate (review v2 F1). `didCompleteWithError(
    // NSURLErrorCancelled)` races this closure on a separate queue;
    // if it finalized first via `finishCancelled`, `state.active` is
    // gone and we have already emitted `.cancelled` to subscribers.
    // Without this gate we would still hash `.partial`, place the
    // file, and fsync the parent — landing a verified payload on
    // disk after the caller was told the download was cancelled.
    let stillActive = lock.withLock { state in state.active[handleID] != nil }
    guard stillActive else {
      // Clean up the `.partial` we moved into place in
      // `didFinishDownloadingTo` — leaving it would also strand a
      // partially-fetched payload in the models directory.
      do {
        try Self.removeIgnoringNoSuchFile(active.partial, fileManager: fileManager)
      } catch {
        log.error("completeDownload(vanished): .partial remove failed at \(active.partial.path, privacy: .public): \(String(describing: error), privacy: .public)")
      }
      log.info("completeDownload: handle \(handleID.uuidString, privacy: .public) vanished (cancelled/invalidated) before verify queue ran — aborted without placing destination")
      return
    }

    let verification: DownloadProgress.VerificationStatus
    if let expected = active.expectedSHA256 {
      mutateAndPublish(handleID) { active in
        active.lastProgress = DownloadProgress(handleID: handleID,
                                               phase: .verifying,
                                               bytesReceived: active.receivedBytes,
                                               bytesExpected: active.totalBytes,
                                               etaSeconds: nil,
                                               verification: nil)
      }
      let actual: String
      do {
        actual = try ModelDownloader.sha256OfFile(at: active.partial)
      } catch {
        cleanupPoisonedArtifacts(active, why: "sha256 read failed")
        finishFailed(handleID, .writeFailed(message: "sha256 read \(active.partial.path): \(error)",
                                            cause: ErrorCause.from(error)))
        return
      }
      if actual != expected {
        cleanupPoisonedArtifacts(active, why: "sha256 mismatch")
        finishFailed(handleID, .sha256Mismatch(expected: expected, actual: actual))
        return
      }
      verification = .verified
    } else {
      // No digest advertised — surface that on the terminal event so
      // the GUI can badge the file as unverified (review v1 F14).
      //
      //  F2: log at `.notice` (default-persisted) so a skipped
      // sha256 verification is greppable, matching this file's
      // observability discipline. The common cause is a resumed Xet
      // download that continued from the CDN URL and never re-hit the
      // resolve 302, so `willPerformHTTPRedirection` never captured
      // `X-Linked-Etag`. The file is still placed, but with NO
      // integrity check — operators need a durable trail of that.
      log.notice("verification skipped: no X-Linked-Etag advertised — installing UNVERIFIED handle=\(handleID.uuidString, privacy: .public) path=\(active.destination.path, privacy: .public)")
      verification = .notAdvertised
    }

    // Best-effort fsync of `.partial` data + metadata before rename.
    // Non-fatal: if the FS rejects F_FULLFSYNC (network volume, exotic
    // mount) we still place the file — the durability gap surfaces in
    // logs so an operator can investigate. Hard-failing here would
    // throw away a successful HTTP transfer + verified hash for what
    // is fundamentally a durability optimization (review v1 F6).
    do {
      try Self.fsyncFile(at: active.partial, fileManager: fileManager)
    } catch {
      log.error("fsync(.partial) \(active.partial.path, privacy: .public) failed (non-fatal): \(String(describing: error), privacy: .public)")
    }

    // Take the placement lock (review v3 F5). Sets
    // `placementInProgress = true` and re-checks `state.active` in
    // one critical section — closes the cancel-vs-placement window
    // the v2 gate only narrowed: if `finishCancelled` ran during
    // verify, `state.active` is already gone here and we abort
    // without placing. If it lands AFTER this section,
    // `finishCancelled` sees the flag and drops the cancel as a
    // no-op (placement wins).
    let proceedToPlacement = lock.withLock { state -> Bool in
      guard var a = state.active[handleID] else { return false }
      a.placementInProgress = true
      state.active[handleID] = a
      return true
    }
    guard proceedToPlacement else {
      do {
        try Self.removeIgnoringNoSuchFile(active.partial, fileManager: fileManager)
      } catch {
        log.error("completeDownload(post-verify vanished): .partial remove failed at \(active.partial.path, privacy: .public): \(String(describing: error), privacy: .public)")
      }
      log.info("completeDownload: handle \(handleID.uuidString, privacy: .public) cancelled during verify — placement aborted")
      return
    }

    //  F10/F11: for an UNVERIFIED placement, write the durable
    // `<file>.unverified` danger-marker BEFORE the rename makes the GGUF
    // visible/loadable. The only other record that the file is
    // unverified is the in-memory `active` row, which evaporates on
    // process death — so a crash between rename and a marker write
    // would leave a loadable GGUF that scans as verified (F11). Writing
    // the marker first closes that window: a sidecar that briefly
    // outlives a failed placement is harmless (no `.gguf` → no
    // InstalledModels row, the same tolerance the delete path
    // documents). The `.verified` REMOVAL stays AFTER placement (the
    // fail-safe direction — clear the marker only once the verified
    // file has landed). Best-effort: a write failure logs rather than
    // discarding a successfully verified payload.
    let unverifiedSidecar = URL(fileURLWithPath: active.destination.path + InstalledModels.unverifiedSuffix)
    if verification != .verified {
      do {
        try Data().write(to: unverifiedSidecar, options: .atomic)
        log.notice("place: wrote .unverified sidecar BEFORE placement (sha256 not checked) at \(unverifiedSidecar.path, privacy: .public)")
      } catch {
        log.error("place: .unverified sidecar write failed at \(unverifiedSidecar.path, privacy: .public): \(String(describing: error), privacy: .public)")
      }
    }

    // Atomic placement. POSIX `rename(2)` is the single-syscall
    // happy path: overwrites destination atomically when it exists,
    // succeeds when it doesn't, no TOCTOU between an existence check
    // and the rename (review v2 F2). `.partial` lives in
    // `destinationDir` (same volume as `destination`) so EXDEV is
    // structurally impossible — see `placeAtomic` doc.
    do {
      try Self.placeAtomic(partial: active.partial,
                           destination: active.destination,
                           fileManager: fileManager,
                           log: log,
                           renameSyscall: renameSyscall)
    } catch let unrepresentable as ModelDownloader.PathUnrepresentable {
      // Review v16 F3: the URL could not be encoded into a filesystem
      // representation at all. This is a caller-bug class (input
      // produced a path Foundation refused to turn into bytes the
      // kernel can use), NOT a transient. Surface as
      // `.invalidArguments` so retry policy treats it as a wire-
      // contract violation instead of conflating with an EINVAL
      // returned by a real `rename(2)` syscall.
      log.error("place \(active.destination.path, privacy: .public) failed (unrepresentable): \(String(describing: unrepresentable), privacy: .public)")
      finishFailed(handleID, .invalidArguments(message: String(describing: unrepresentable)))
      return
    } catch {
      log.error("place \(active.destination.path, privacy: .public) failed: \(String(describing: error), privacy: .public)")
      // Leave `.partial` in place — operator (or a later retry) can
      // recover the verified bytes from disk rather than re-fetch.
      // `ErrorCause.from(error)` walks `NSUnderlyingErrorKey` so the
      // surfaced wire error still carries POSIX errno when
      // available (review v7 F5).
      finishFailed(handleID, .writeFailed(message: "place \(active.partial.path) → \(active.destination.path) failed (verified payload preserved at .partial): \(error)",
                                          cause: ErrorCause.from(error)))
      return
    }

    do {
      try Self.fsyncDirectory(at: active.destinationDir)
    } catch {
      // Non-fatal: the file is in place; the directory entry may take
      // longer to flush. Log so an operator sees the durability gap.
      log.error("fsyncDirectory \(active.destinationDir.path, privacy: .public) failed: \(String(describing: error), privacy: .public)")
    }

    // Cleanup `.resume` — log on failure (review v1 F12). A stale
    // `.resume` next to a completed destination is a landmine.
    do {
      try Self.removeIgnoringNoSuchFile(active.resumeFile, fileManager: fileManager)
    } catch {
      log.error("place: stale .resume cleanup failed at \(active.resumeFile.path, privacy: .public): \(String(describing: error), privacy: .public)")
    }

    //  F10/F11: a `.verified` placement removes any stale
    // `.unverified` marker (e.g. a prior unverified attempt that a
    // re-download has now verified). This runs AFTER placement so the
    // marker clears only once the verified file has landed — the
    // fail-safe direction. (The unverified marker is written BEFORE
    // placement; see above.) `InstalledModels.scan` reads the marker to
    // badge the Installed-models row, and `LaunchSpecResolver` warns at
    // load time. Best-effort — a removal failure logs rather than
    // failing the completion.
    if verification == .verified {
      do {
        try Self.removeIgnoringNoSuchFile(unverifiedSidecar, fileManager: fileManager)
      } catch {
        log.error("place: stale .unverified sidecar cleanup failed at \(unverifiedSidecar.path, privacy: .public): \(String(describing: error), privacy: .public)")
      }
    }

    if let final = mutateAndPublish(handleID, { active in
      active.lastProgress = DownloadProgress(handleID: handleID,
                                             phase: .completed,
                                             bytesReceived: active.receivedBytes,
                                             bytesExpected: active.totalBytes,
                                             etaSeconds: nil,
                                             verification: verification)
    }) {
      log.info("completed handle=\(handleID.uuidString, privacy: .public) bytes=\(final.receivedBytes, privacy: .public) verification=\(verification.rawValue, privacy: .public) path=\(final.destination.path, privacy: .public)")
      finishAll(final)
    }
  }

  /// Remove `.partial` and `.resume` for a failed-verify or
  /// poisoned-artifact path. Both removals log on failure (review v1
  /// F11, F12) so a stuck file doesn't silently keep poisoning future
  /// retries.
  private func cleanupPoisonedArtifacts(_ active: ActiveDownload, why: String) {
    do {
      try Self.removeIgnoringNoSuchFile(active.partial, fileManager: fileManager)
    } catch {
      log.error("cleanup(\(why, privacy: .public)): .partial remove failed at \(active.partial.path, privacy: .public): \(String(describing: error), privacy: .public)")
    }
    do {
      try Self.removeIgnoringNoSuchFile(active.resumeFile, fileManager: fileManager)
    } catch {
      log.error("cleanup(\(why, privacy: .public)): .resume remove failed at \(active.resumeFile.path, privacy: .public): \(String(describing: error), privacy: .public)")
    }
  }

  private func finishCancelled(_ handleID: UUID) {
    // Review v3 F5: placement-wins semantics. If completeDownload
    // crossed the placement lock before this cancel landed, the
    // rename is imminent or already done — dropping the cancel
    // means the subscriber sees `.completed` (not `.cancelled`)
    // and the verified file is correctly on disk. Without this
    // check the v2 gate's documented invariant ("subscriber's
    // terminal phase matches on-disk state") fails for a narrow
    // but real race window.
    let placementWon = lock.withLock { state -> Bool in
      state.active[handleID]?.placementInProgress ?? false
    }
    if placementWon {
      log.info("finishCancelled handle=\(handleID.uuidString, privacy: .public): placement in progress — cancel dropped (placement wins)")
      return
    }
    if let final = mutateAndPublish(handleID, { active in
      active.lastProgress = DownloadProgress(handleID: handleID,
                                             phase: .cancelled,
                                             bytesReceived: active.receivedBytes,
                                             bytesExpected: active.totalBytes,
                                             etaSeconds: nil,
                                             verification: .notApplicable)
    }) {
      log.info("cancelled handle=\(handleID.uuidString, privacy: .public)")
      finishAll(final)
    }
  }

  private func finishFailed(_ handleID: UUID, _ reason: DownloadError) {
    // #720: the wire payload (and therefore the GUI caption) carries the
    // clean, user-facing message; the raw structured error stays in the
    // logs only via the `.error` line below.
    let reasonString = String(describing: reason)
    let userMessage = reason.userFacingMessage
    if let final = mutateAndPublish(handleID, { active in
      active.lastProgress = DownloadProgress(handleID: handleID,
                                             phase: .failed,
                                             bytesReceived: active.receivedBytes,
                                             bytesExpected: active.totalBytes,
                                             etaSeconds: nil,
                                             verification: .notApplicable,
                                             failureReason: userMessage)
    }) {
      log.error("failed handle=\(handleID.uuidString, privacy: .public) reason=\(reasonString, privacy: .public)")
      finishAll(final)
    }
  }
}
