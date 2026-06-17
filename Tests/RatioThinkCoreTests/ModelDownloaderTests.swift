import XCTest
import CryptoKit
import os
@testable import RatioThinkCore

/// Integration tests for `ModelDownloader` (, Phase 2.5).
///
/// All tests mount a `MockURLProtocol` on the downloader's
/// `URLSessionConfiguration` so no network traffic leaves the process.
/// Models root is a per-test temp dir injected through the
/// `modelsRoot:` provider — no `PieDirs.$homeOverride` plumbing needed
/// because the downloader's own provider is the seam.
final class ModelDownloaderTests: XCTestCase {

  override func setUp() {
    super.setUp()
    MockURLProtocol.reset()
  }

  override func tearDown() {
    MockURLProtocol.reset()
    super.tearDown()
  }

  // MARK: - parseSHA256

  func test_parseSHA256_strips_quotes_and_namespace() {
    let digest = String(repeating: "ab", count: 32)  // 64 hex chars
    XCTAssertEqual(ModelDownloader.parseSHA256(fromXLinkedEtag: digest), digest)
    XCTAssertEqual(ModelDownloader.parseSHA256(fromXLinkedEtag: "\"\(digest)\""), digest)
    XCTAssertEqual(ModelDownloader.parseSHA256(fromXLinkedEtag: "sha256:\(digest)"), digest)
    XCTAssertEqual(ModelDownloader.parseSHA256(fromXLinkedEtag: "\"sha256:\(digest)\""), digest)
    // Uppercase normalizes to lowercase.
    XCTAssertEqual(ModelDownloader.parseSHA256(fromXLinkedEtag: digest.uppercased()), digest)
  }

  func test_parseSHA256_rejects_non_hex_and_wrong_length() {
    XCTAssertNil(ModelDownloader.parseSHA256(fromXLinkedEtag: "abc"))
    XCTAssertNil(ModelDownloader.parseSHA256(fromXLinkedEtag: String(repeating: "g", count: 64)))
    XCTAssertNil(ModelDownloader.parseSHA256(fromXLinkedEtag: ""))
  }

  // MARK: - progress throttle (#218)

  /// The very first `.downloading` frame must always publish so the UI
  /// leaves the `.starting` spinner the instant bytes start flowing.
  func test_shouldPublishDownloadingFrame_first_frame_always_publishes() {
    let now = Date()
    XCTAssertTrue(ModelDownloader.shouldPublishDownloadingFrame(
      now: now, lastPublishedAt: nil, minInterval: 0.1,
      bytesReceived: 0, totalBytes: nil))
    XCTAssertTrue(ModelDownloader.shouldPublishDownloadingFrame(
      now: now, lastPublishedAt: nil, minInterval: 0.1,
      bytesReceived: 1, totalBytes: 1_000))
  }

  /// A frame inside the min-interval window with no completion is
  /// coalesced — this is the flood suppression that fixes the laggy UI.
  func test_shouldPublishDownloadingFrame_coalesces_within_interval() {
    let last = Date()
    let soon = last.addingTimeInterval(0.05)  // < 0.1s
    XCTAssertFalse(ModelDownloader.shouldPublishDownloadingFrame(
      now: soon, lastPublishedAt: last, minInterval: 0.1,
      bytesReceived: 500, totalBytes: 1_000))
  }

  /// Once the min-interval has elapsed, the next frame publishes.
  func test_shouldPublishDownloadingFrame_publishes_after_interval() {
    let last = Date()
    XCTAssertTrue(ModelDownloader.shouldPublishDownloadingFrame(
      now: last.addingTimeInterval(0.1), lastPublishedAt: last, minInterval: 0.1,
      bytesReceived: 500, totalBytes: 1_000))
    XCTAssertTrue(ModelDownloader.shouldPublishDownloadingFrame(
      now: last.addingTimeInterval(0.5), lastPublishedAt: last, minInterval: 0.1,
      bytesReceived: 600, totalBytes: 1_000))
  }

  /// Reaching 100%-by-bytes always publishes, even inside the window, so
  /// the bar visibly fills before the `.verifying`/`.completed` terminal.
  func test_shouldPublishDownloadingFrame_completion_overrides_throttle() {
    let last = Date()
    let soon = last.addingTimeInterval(0.01)  // well within window
    XCTAssertTrue(ModelDownloader.shouldPublishDownloadingFrame(
      now: soon, lastPublishedAt: last, minInterval: 0.1,
      bytesReceived: 1_000, totalBytes: 1_000))
    // Below total, still throttled.
    XCTAssertFalse(ModelDownloader.shouldPublishDownloadingFrame(
      now: soon, lastPublishedAt: last, minInterval: 0.1,
      bytesReceived: 999, totalBytes: 1_000))
    // Indeterminate (total nil/0) never trips the completion override.
    XCTAssertFalse(ModelDownloader.shouldPublishDownloadingFrame(
      now: soon, lastPublishedAt: last, minInterval: 0.1,
      bytesReceived: 1_000, totalBytes: nil))
  }

  // MARK: - sha256OfFile

  func test_sha256OfFile_matches_in_memory_digest() throws {
    let temp = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: temp) }
    let file = temp.appendingPathComponent("payload.bin")
    let payload = Data((0..<(3 << 20)).map { UInt8($0 & 0xff) })  // 3 MiB
    try payload.write(to: file)
    let expected = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    XCTAssertEqual(try ModelDownloader.sha256OfFile(at: file), expected)
  }

  // MARK: - happy path

  func test_start_places_file_at_destination_and_completes() async throws {
    let temp = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: temp) }
    let payload = Data("hello pie".utf8)
    MockURLProtocol.handler = { _ in
      let response = HTTPURLResponse(
        url: URL(string: "https://huggingface.co/repo/resolve/main/file.gguf")!,
        statusCode: 200,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Length": "\(payload.count)"])!
      return (response, payload)
    }
    let downloader = makeDownloader(modelsRoot: temp)
    defer { downloader.invalidate() }

    let result = downloader.start(repo: "acme/model", file: "file.gguf")
    let handle = try result.get()

    try await awaitTerminalProgress(for: handle, in: downloader,
                                    expected: .completed)
    let placed = temp.appendingPathComponent("acme/model/file.gguf")
    XCTAssertTrue(FileManager.default.fileExists(atPath: placed.path))
    XCTAssertEqual(try Data(contentsOf: placed), payload)
    // .partial + .resume must be cleaned up on success.
    XCTAssertFalse(FileManager.default.fileExists(atPath: placed.path + ".partial"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: placed.path + ".resume"))
  }

  // MARK: - SHA-256 verify

  func test_sha256_mismatch_marks_failed_and_removes_partial() async throws {
    let temp = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: temp) }
    let payload = Data("corrupted-bytes".utf8)
    let lyingDigest = String(repeating: "0", count: 64)
    MockURLProtocol.handler = { _ in
      let response = HTTPURLResponse(
        url: URL(string: "https://huggingface.co/x/resolve/main/m.gguf")!,
        statusCode: 200,
        httpVersion: "HTTP/1.1",
        headerFields: [
          "Content-Length": "\(payload.count)",
          "X-Linked-Etag": "\"sha256:\(lyingDigest)\"",
        ])!
      return (response, payload)
    }
    let downloader = makeDownloader(modelsRoot: temp)
    defer { downloader.invalidate() }

    let handle = try downloader.start(repo: "x/y", file: "m.gguf").get()
    try await awaitTerminalProgress(for: handle, in: downloader,
                                    expected: .failed)

    let placed = temp.appendingPathComponent("x/y/m.gguf")
    XCTAssertFalse(FileManager.default.fileExists(atPath: placed.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: placed.path + ".partial"),
                   ".partial must be removed after a verify failure so a retry doesn't resume from poisoned bytes")
  }

  func test_sha256_match_completes_when_xlinkedetag_advertised() async throws {
    let temp = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: temp) }
    let payload = Data("verifiable-bytes".utf8)
    let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    MockURLProtocol.handler = { _ in
      let response = HTTPURLResponse(
        url: URL(string: "https://huggingface.co/v/resolve/main/m.gguf")!,
        statusCode: 200,
        httpVersion: "HTTP/1.1",
        headerFields: [
          "Content-Length": "\(payload.count)",
          "X-Linked-Etag": "\"\(digest)\"",
        ])!
      return (response, payload)
    }
    let downloader = makeDownloader(modelsRoot: temp)
    defer { downloader.invalidate() }

    let handle = try downloader.start(repo: "v/v", file: "m.gguf").get()
    try await awaitTerminalProgress(for: handle, in: downloader,
                                    expected: .completed)
    let placed = temp.appendingPathComponent("v/v/m.gguf")
    XCTAssertEqual(try Data(contentsOf: placed), payload)
  }

  ///  regression. HF's real flow: the `huggingface.co/resolve`
  /// response is a 3xx carrying `X-Linked-Etag` (the LFS content
  /// sha256), redirecting to a Xet/S3 CDN whose FINAL response has NO
  /// `X-Linked-Etag` but a plain `ETag` that is a *different* 64-hex
  /// hash (the Xet blob id, not the file sha256). URLSession discards
  /// the redirect response, so the digest must be captured from the
  /// redirect — and the plain CDN `ETag` must NOT be used as a
  /// fallback, or every Xet-backed download fails a false
  /// sha256Mismatch.
  func test_sha256_verified_from_redirect_xlinkedetag_not_cdn_etag() async throws {
    let temp = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: temp) }
    let payload = Data("xet-backed-gguf-bytes".utf8)
    let realDigest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    // A *different* 64-hex value standing in for the Xet CDN ETag.
    let cdnBlobHash = String(repeating: "1", count: 64)
    XCTAssertNotEqual(realDigest, cdnBlobHash)
    let cdnURL = URL(string: "https://cas-bridge.example/blob?token=abc")!

    MockURLProtocol.redirectHandler = { request in
      guard request.url?.host == "huggingface.co" else { return nil }
      let redirect = HTTPURLResponse(
        url: request.url!,
        statusCode: 302,
        httpVersion: "HTTP/1.1",
        headerFields: [
          "Location": cdnURL.absoluteString,
          "X-Linked-Etag": "\"\(realDigest)\"",
          "X-Linked-Size": "\(payload.count)",
        ])!
      return (redirect, URLRequest(url: cdnURL))
    }
    MockURLProtocol.handler = { _ in
      let response = HTTPURLResponse(
        url: cdnURL,
        statusCode: 200,
        httpVersion: "HTTP/1.1",
        headerFields: [
          "Content-Length": "\(payload.count)",
          // CDN ETag is a 64-hex hash but NOT the file sha256.
          "ETag": "\"\(cdnBlobHash)\"",
        ])!
      return (response, payload)
    }
    let downloader = makeDownloader(modelsRoot: temp)
    defer { downloader.invalidate() }

    let handle = try downloader.start(repo: "Qwen/Qwen3-0.6B-GGUF",
                                      file: "Qwen3-0.6B-Q8_0.gguf").get()
    try await awaitTerminalProgress(for: handle, in: downloader,
                                    expected: .completed)
    let placed = temp.appendingPathComponent("Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf")
    XCTAssertEqual(try Data(contentsOf: placed), payload,
                   "verified body must be placed; digest comes from the redirect's X-Linked-Etag")
  }

  // MARK: - Live acquisition

  ///  acquisition leg. Drives the REAL `ModelDownloader`
  /// (real URLSession, real redirect handling) against live Hugging
  /// Face for the smallest curated catalog entry — the same
  /// coordinates Settings → Models → Add Model… enqueues. This is the
  /// reliable home for the acquisition substance: the SwiftUI Settings
  /// TabView is a documented unreliable XCUITest surface (its tab
  /// content is not exposed to `app.buttons[...]`), so the GUI tier
  /// asserts only that the Settings tabs exist (S5) and the download
  /// path is pinned here instead.
  ///
  /// It is also the end-to-end proof of the  fix: `.completed` with
  /// `verification == .verified` is emitted ONLY when the downloaded
  /// body's sha256 matches HF's `X-Linked-Etag` (captured from the
  /// `huggingface.co/resolve` 302 redirect, not the Xet CDN `ETag`).
  ///
  /// Network + bandwidth heavy, so gated behind `PIE_TEST_LIVE_HF=1`
  /// and skipped in the default unit run / CI (the only test in this
  /// file that touches the network). Run via
  /// `Scripts/run-real-model-acquisition.sh`.
  func test_acquire_smallest_curated_model_live() async throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["PIE_TEST_LIVE_HF"] == "1",
                      "live HF acquisition test — set PIE_TEST_LIVE_HF=1 to run")
    let model = try XCTUnwrap(CuratedModelCatalog.all.first,
                              "curated catalog is empty — nothing to acquire")
    // When the wrapper sets PIE_TEST_ACQUIRE_MODELS_ROOT it owns the
    // dir and re-verifies the placed bytes' sha256 against HF
    // independently — leave the file in place. Otherwise use a
    // self-cleaning temp.
    let keepRoot = ProcessInfo.processInfo.environment["PIE_TEST_ACQUIRE_MODELS_ROOT"]
    let temp: URL
    if let keepRoot, !keepRoot.isEmpty {
      temp = URL(fileURLWithPath: keepRoot, isDirectory: true)
      try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    } else {
      temp = try makeTempRoot()
    }
    defer { if keepRoot == nil { try? FileManager.default.removeItem(at: temp) } }
    let cfg = URLSessionConfiguration.default
    cfg.timeoutIntervalForResource = 1200
    let downloader = ModelDownloader(sessionConfiguration: cfg, modelsRoot: { temp })
    defer { downloader.invalidate() }

    let handle = try downloader.start(repo: model.huggingFaceRepo,
                                      file: model.huggingFaceFile).get()
    var terminal: DownloadProgress?
    for await event in downloader.progress(for: handle) {
      switch event.phase {
      case .completed, .failed, .cancelled:
        terminal = event
      default:
        continue
      }
      break
    }
    XCTAssertEqual(terminal?.phase, .completed,
                   "live acquisition of \(model.huggingFaceRepo)/\(model.huggingFaceFile) did not complete; terminal=\(String(describing: terminal))")
    XCTAssertEqual(terminal?.verification, .verified,
                   "completed download must be sha256-verified against HF's X-Linked-Etag")
    let placed = temp.appendingPathComponent("\(model.huggingFaceRepo)/\(model.huggingFaceFile)")
    XCTAssertTrue(FileManager.default.fileExists(atPath: placed.path),
                  "verified GGUF must be placed at \(placed.path)")
  }

  // MARK: - HTTP error

  func test_http_4xx_surfaces_as_failed() async throws {
    let temp = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: temp) }
    MockURLProtocol.handler = { _ in
      let response = HTTPURLResponse(
        url: URL(string: "https://huggingface.co/missing/resolve/main/file.gguf")!,
        statusCode: 404,
        httpVersion: "HTTP/1.1",
        headerFields: [:])!
      return (response, Data("not found".utf8))
    }
    let downloader = makeDownloader(modelsRoot: temp)
    defer { downloader.invalidate() }

    let handle = try downloader.start(repo: "missing/repo", file: "file.gguf").get()
    try await awaitTerminalProgress(for: handle, in: downloader,
                                    expected: .failed)
    let placed = temp.appendingPathComponent("missing/repo/file.gguf")
    XCTAssertFalse(FileManager.default.fileExists(atPath: placed.path))
  }

  // MARK: - dedupe

  func test_concurrent_start_for_same_path_is_refused() throws {
    let temp = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: temp) }
    // Use a handler that never finishes so the first download stays
    // in flight while the second start runs.
    MockURLProtocol.handler = { _ in
      // Throw URLError(.cancelled) to keep the protocol from emitting
      // a response immediately; the test only inspects the second
      // synchronous `start` call.
      throw URLError(.timedOut)
    }
    let downloader = makeDownloader(modelsRoot: temp)
    defer { downloader.invalidate() }

    let first = downloader.start(repo: "dup/repo", file: "f.gguf")
    XCTAssertNoThrow(try first.get())

    let second = downloader.start(repo: "dup/repo", file: "f.gguf")
    switch second {
    case .failure(.alreadyInFlight(let repo, let file)):
      XCTAssertEqual(repo, "dup/repo")
      XCTAssertEqual(file, "f.gguf")
    default:
      XCTFail("expected .alreadyInFlight, got \(second)")
    }
  }

  // MARK: - cancel

  func test_cancel_unknown_handle_returns_unknownHandle() {
    let temp = (try? makeTempRoot()) ?? URL(fileURLWithPath: NSTemporaryDirectory())
    let downloader = makeDownloader(modelsRoot: temp)
    defer { downloader.invalidate() }
    let phantom = DownloadHandle(repo: "x", file: "y")
    XCTAssertEqual(downloader.cancel(handle: phantom), .unknownHandle)
  }

  /// #218 hard-cancel: cancelling an in-flight download emits `.cancelled`
  /// synchronously (no wait on CFNetwork resume-data serialization),
  /// leaves NO `.resume` sidecar, and tears the handle down. A blocking
  /// handler keeps the task in-flight so the cancel races nothing.
  func test_cancel_inflight_is_hard_cancel_no_resume() async throws {
    let temp = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: temp) }
    let started = DispatchSemaphore(value: 0)
    let gate = DispatchSemaphore(value: 0)
    MockURLProtocol.handler = { _ in
      started.signal()
      gate.wait()  // held in-flight until the test cancels + releases
      let response = HTTPURLResponse(
        url: URL(string: "https://huggingface.co/r/x/resolve/main/m.gguf")!,
        statusCode: 200, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Length": "11"])!
      return (response, Data("hello-world".utf8))
    }
    let downloader = makeDownloader(modelsRoot: temp)
    defer { gate.signal(); downloader.invalidate() }

    let handle = try downloader.start(repo: "r/x", file: "m.gguf").get()
    XCTAssertEqual(started.wait(timeout: .now() + 5), .success,
                   "download task never entered the protocol handler")

    // Subscribe before cancel so we observe the synchronous terminal.
    let stream = downloader.progress(for: handle)
    XCTAssertNil(downloader.cancel(handle: handle), "cancel of a live handle must succeed")
    gate.signal()  // let the now-orphaned handler unwind; it no-ops

    let phase = await drainToTerminal(stream)
    XCTAssertEqual(phase, .cancelled, "hard cancel must terminate as .cancelled")

    let resumeFile = temp.appendingPathComponent("r/x")
      .appendingPathComponent("m.gguf.resume")
    XCTAssertFalse(FileManager.default.fileExists(atPath: resumeFile.path),
                   "hard cancel must not leave a .resume sidecar (no resume)")
    // Handle is torn down — a second cancel is unknown.
    XCTAssertEqual(downloader.cancel(handle: handle), .unknownHandle)
  }

  func test_modelsRoot_failure_returns_modelsRootUnavailable() {
    let downloader = ModelDownloader(
      sessionConfiguration: Self.protocolStubConfiguration(),
      modelsRoot: { throw NSError(domain: "test", code: 7) },
      urlBuilder: ModelDownloader.huggingFaceURLBuilder)
    defer { downloader.invalidate() }
    switch downloader.start(repo: "r", file: "f") {
    case .failure(.modelsRootUnavailable):
      break
    default:
      XCTFail("expected modelsRootUnavailable")
    }
  }

  // MARK: - subscribe-after-complete (review v1 F2)

  func test_progress_subscribe_after_complete_replays_terminal_event() async throws {
    let temp = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: temp) }
    let payload = Data("late-subscribe".utf8)
    MockURLProtocol.handler = { _ in
      let response = HTTPURLResponse(
        url: URL(string: "https://huggingface.co/x/resolve/main/m.gguf")!,
        statusCode: 200, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Length": "\(payload.count)"])!
      return (response, payload)
    }
    let downloader = makeDownloader(modelsRoot: temp)
    defer { downloader.invalidate() }
    let handle = try downloader.start(repo: "a/b", file: "m.gguf").get()
    // Drain to completion first.
    try await awaitTerminalProgress(for: handle, in: downloader,
                                    expected: .completed)
    // Subscribe AFTER completion — must replay the terminal snapshot
    // exactly once, then finish.
    let stream = downloader.progress(for: handle)
    var events: [DownloadProgress] = []
    for await event in stream { events.append(event) }
    XCTAssertEqual(events.count, 1,
                   "subscribe-after-complete must yield exactly one terminal event")
    XCTAssertEqual(events.first?.phase, .completed)
    XCTAssertEqual(events.first?.verification, .notAdvertised,
                   "no X-Linked-Etag was sent — completion must surface .notAdvertised (F14)")
  }

  func test_progress_unknown_handle_finishes_with_no_events() async throws {
    let temp = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: temp) }
    let downloader = makeDownloader(modelsRoot: temp)
    defer { downloader.invalidate() }
    let phantom = DownloadHandle(repo: "nope", file: "nope")
    let stream = downloader.progress(for: phantom)
    var count = 0
    for await _ in stream { count += 1 }
    XCTAssertEqual(count, 0,
                   "unknown handle must finish with zero events so callers can distinguish it from 'completed-before-subscribe'")
  }

  // MARK: - multi-subscriber fanout

  func test_multi_subscriber_each_sees_terminal_event() async throws {
    let temp = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: temp) }
    let payload = Data("multi-sub".utf8)
    MockURLProtocol.handler = { _ in
      let response = HTTPURLResponse(
        url: URL(string: "https://huggingface.co/x/resolve/main/m.gguf")!,
        statusCode: 200, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Length": "\(payload.count)"])!
      return (response, payload)
    }
    let downloader = makeDownloader(modelsRoot: temp)
    defer { downloader.invalidate() }
    let handle = try downloader.start(repo: "m/m", file: "m.gguf").get()
    // Two subscribers concurrently. Both must terminate.
    async let phaseA: DownloadProgress.Phase? = drainToTerminal(downloader.progress(for: handle))
    async let phaseB: DownloadProgress.Phase? = drainToTerminal(downloader.progress(for: handle))
    let results = await (phaseA, phaseB)
    XCTAssertEqual(results.0, .completed)
    XCTAssertEqual(results.1, .completed)
  }

  // MARK: - F14 verified flag

  func test_completion_verification_verified_when_etag_matches() async throws {
    let temp = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: temp) }
    let payload = Data("verified-payload".utf8)
    let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    MockURLProtocol.handler = { _ in
      let response = HTTPURLResponse(
        url: URL(string: "https://huggingface.co/v/resolve/main/m.gguf")!,
        statusCode: 200, httpVersion: "HTTP/1.1",
        headerFields: [
          "Content-Length": "\(payload.count)",
          "X-Linked-Etag": "\"\(digest)\"",
        ])!
      return (response, payload)
    }
    let downloader = makeDownloader(modelsRoot: temp)
    defer { downloader.invalidate() }
    let handle = try downloader.start(repo: "v/v", file: "m.gguf").get()
    let terminal = try await collectTerminalEvent(for: handle, in: downloader)
    XCTAssertEqual(terminal.phase, .completed)
    XCTAssertEqual(terminal.verification, .verified)
    //  F10: a verified placement must NOT leave an .unverified sidecar.
    let placed = temp.appendingPathComponent("v/v/m.gguf")
    XCTAssertFalse(FileManager.default.fileExists(atPath: placed.path + InstalledModels.unverifiedSuffix),
                   "verified download must not write the .unverified sidecar")
  }

  func test_completion_verification_notAdvertised_when_etag_absent() async throws {
    let temp = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: temp) }
    let payload = Data("no-etag".utf8)
    MockURLProtocol.handler = { _ in
      let response = HTTPURLResponse(
        url: URL(string: "https://huggingface.co/n/resolve/main/m.gguf")!,
        statusCode: 200, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Length": "\(payload.count)"])!
      return (response, payload)
    }
    let downloader = makeDownloader(modelsRoot: temp)
    defer { downloader.invalidate() }
    let handle = try downloader.start(repo: "n/n", file: "m.gguf").get()
    let terminal = try await collectTerminalEvent(for: handle, in: downloader)
    XCTAssertEqual(terminal.verification, .notAdvertised,
                   "GUI must be able to badge unverified downloads (F14)")
    //  F10: an unverified placement writes a durable .unverified
    // sidecar so InstalledModels.scan can flag it after rescan/restart.
    let placed = temp.appendingPathComponent("n/n/m.gguf")
    XCTAssertTrue(FileManager.default.fileExists(atPath: placed.path + InstalledModels.unverifiedSuffix),
                  "unverified download must write the durable .unverified sidecar")
  }

  ///  F11 ordering invariant: the `.unverified` danger-marker must
  /// exist BEFORE the atomic rename makes the GGUF visible/loadable, so
  /// a crash in that window can never leave a placed-but-unmarked file
  /// that scans as verified. Interposes on the rename to observe the
  /// on-disk state at the exact moment of placement.
  func test_unverified_sidecar_exists_before_placement_makes_gguf_visible() async throws {
    let temp = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: temp) }
    let payload = Data("ordering-no-etag".utf8)
    MockURLProtocol.handler = { _ in
      let response = HTTPURLResponse(
        url: URL(string: "https://huggingface.co/o/resolve/main/m.gguf")!,
        statusCode: 200, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Length": "\(payload.count)"])!  // no X-Linked-Etag → .notAdvertised
      return (response, payload)
    }
    let sidecarPath = temp.appendingPathComponent("o/o/m.gguf").path
      + InstalledModels.unverifiedSuffix
    let sidecarSeenBeforeRename = OSAllocatedUnfairLock(initialState: false)
    let downloader = ModelDownloader(
      sessionConfiguration: Self.protocolStubConfiguration(),
      modelsRoot: { temp })
    defer { downloader.invalidate() }
    // Interpose the rename (internal test seam) BEFORE start() so the
    // hook runs at the exact placement moment.
    downloader.renameSyscall = { src, dst in
      if FileManager.default.fileExists(atPath: sidecarPath) {
        sidecarSeenBeforeRename.withLock { $0 = true }
      }
      return ModelDownloader.posixRenameSyscall(src, dst)
    }

    let handle = try downloader.start(repo: "o/o", file: "m.gguf").get()
    let terminal = try await collectTerminalEvent(for: handle, in: downloader)
    XCTAssertEqual(terminal.phase, .completed)
    XCTAssertEqual(terminal.verification, .notAdvertised)
    XCTAssertTrue(sidecarSeenBeforeRename.withLock { $0 },
                  "the .unverified sidecar must exist BEFORE placeAtomic's rename makes the GGUF visible (F11)")
    XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarPath),
                  "the .unverified sidecar must remain after a completed unverified placement")
  }

  // MARK: - F3 stale .resume blob hygiene

  /// Pre-plant a corrupt `.resume` sidecar; `start()` must purge it
  /// rather than hand the garbage to `URLSession.downloadTask(withResumeData:)`,
  /// which would raise `-[__NSCFString objectForKey:]` (Obj-C
  /// exception). Review v1 F3 (poisoned-sidecar hygiene).
  func test_corrupt_resume_blob_purged_on_start() async throws {
    let temp = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: temp) }
    let destinationDir = temp.appendingPathComponent("s/r", isDirectory: true)
    try FileManager.default.createDirectory(at: destinationDir,
                                            withIntermediateDirectories: true)
    let resumeFile = destinationDir.appendingPathComponent("m.gguf.resume")
    try Data("garbage-not-a-valid-resume-plist".utf8).write(to: resumeFile)

    let payload = Data("fresh".utf8)
    MockURLProtocol.handler = { _ in
      let response = HTTPURLResponse(
        url: URL(string: "https://huggingface.co/s/resolve/main/m.gguf")!,
        statusCode: 200, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Length": "\(payload.count)"])!
      return (response, payload)
    }
    let downloader = makeDownloader(modelsRoot: temp)
    defer { downloader.invalidate() }

    // Start MUST NOT crash — purges sidecar, falls through to fresh
    // downloadTask.
    let handle = try downloader.start(repo: "s/r", file: "m.gguf").get()
    XCTAssertFalse(FileManager.default.fileExists(atPath: resumeFile.path),
                   ".resume must be purged before start hands it to URLSession (F3)")
    try await awaitTerminalProgress(for: handle, in: downloader,
                                    expected: .completed)
  }

  /// Validates the validator: a plist that parses but lacks the
  /// URLSession-resume keys (`NSURLSessionResumeInfoVersion`,
  /// `NSURLSessionDownloadURL`) is purged at start, not handed to
  /// `downloadTask(withResumeData:)` where CFNetwork's
  /// `_expandResumeData` would raise an uncatchable Obj-C exception
  /// (review v1 F3).
  func test_plist_resume_blob_missing_required_keys_is_purged() async throws {
    let temp = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: temp) }
    let destinationDir = temp.appendingPathComponent("p/q", isDirectory: true)
    try FileManager.default.createDirectory(at: destinationDir,
                                            withIntermediateDirectories: true)
    let resumeFile = destinationDir.appendingPathComponent("m.gguf.resume")
    // Valid plist, missing both required URLSession keys.
    let plistData = try PropertyListSerialization.data(
      fromPropertyList: ["other": "fields", "v": 1] as [String: Any],
      format: .binary, options: 0)
    try plistData.write(to: resumeFile)

    let payload = Data("fresh".utf8)
    MockURLProtocol.handler = { _ in
      let response = HTTPURLResponse(
        url: URL(string: "https://huggingface.co/p/resolve/main/m.gguf")!,
        statusCode: 200, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Length": "\(payload.count)"])!
      return (response, payload)
    }
    let downloader = makeDownloader(modelsRoot: temp)
    defer { downloader.invalidate() }

    let handle = try downloader.start(repo: "p/q", file: "m.gguf").get()
    XCTAssertFalse(FileManager.default.fileExists(atPath: resumeFile.path),
                   ".resume must be purged when it lacks URLSession resume-data keys (F3)")
    try await awaitTerminalProgress(for: handle, in: downloader,
                                    expected: .completed)
  }

  // MARK: - Review v2 F1: vanished-handle gate
  //
  // The vanished-handle gate at the top of `completeDownload` is
  // checked under the same lock that `finishCancelled` purges
  // `state.active` from, so the assertion is local and well-tested
  // by inspection. A deterministic race test would have to suspend
  // URLSession's delegate queue (not just `verifyQueue`) to wedge
  // `didCompleteWithError(NSURLErrorCancelled)` between
  // `didFinishDownloadingTo` and the verify-queue closure — that
  // exposes more internal queues than makes sense for a public test
  // seam, so this finding is verified by code review. The atomic
  // rename test below exercises the happy-path success route; if
  // the gate were missing, the cancel test above
  // (`test_concurrent_start_for_same_path_is_refused`) would not
  // trigger it either.

  // MARK: - Review v2 F2: atomic rename overwrites existing destination

  /// When the canonical destination already exists from a previous
  /// successful download, a fresh successful download must atomically
  /// overwrite it. `rename(2)` handles this in a single syscall — the
  /// prior `fileExists` + `replaceItemAt/moveItem` branch had a TOCTOU
  /// window between the existence check and the chosen branch
  /// (review v2 F2).
  func test_atomic_rename_overwrites_existing_destination() async throws {
    let temp = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: temp) }
    let destinationDir = temp.appendingPathComponent("o/d", isDirectory: true)
    try FileManager.default.createDirectory(at: destinationDir,
                                            withIntermediateDirectories: true)
    let destination = destinationDir.appendingPathComponent("m.gguf")
    // Plant a prior version of the file.
    try Data("OLD-OLD-OLD".utf8).write(to: destination)

    let payload = Data("NEW-PAYLOAD".utf8)
    MockURLProtocol.handler = { _ in
      let response = HTTPURLResponse(
        url: URL(string: "https://huggingface.co/o/resolve/main/m.gguf")!,
        statusCode: 200, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Length": "\(payload.count)"])!
      return (response, payload)
    }
    let downloader = makeDownloader(modelsRoot: temp)
    defer { downloader.invalidate() }

    let handle = try downloader.start(repo: "o/d", file: "m.gguf").get()
    try await awaitTerminalProgress(for: handle, in: downloader,
                                    expected: .completed)
    XCTAssertEqual(try Data(contentsOf: destination), payload,
                   "rename(2) must atomically overwrite a pre-existing destination (F2)")
  }

  // MARK: - Review v2 F3: stale .resume next to existing destination

  /// If `.resume` somehow survived a previous successful completion
  /// (cleanup failed under EROFS / AV lock), `start(repo:file:)` for
  /// the same path must purge it before considering it — otherwise
  /// CFNetwork issues a range request that may 416 against the
  /// already-placed destination (review v2 F3).
  func test_resume_sidecar_purged_when_destination_already_exists() async throws {
    let temp = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: temp) }
    let destinationDir = temp.appendingPathComponent("a/b", isDirectory: true)
    try FileManager.default.createDirectory(at: destinationDir,
                                            withIntermediateDirectories: true)
    let destination = destinationDir.appendingPathComponent("m.gguf")
    let resumeFile = destinationDir.appendingPathComponent("m.gguf.resume")
    // Both destination and a (validly-shaped) resume sidecar present
    // from a prior run.
    try Data("prior-content".utf8).write(to: destination)
    let resumeBlob = try PropertyListSerialization.data(
      fromPropertyList: [
        "NSURLSessionResumeInfoVersion": 2,
        "NSURLSessionDownloadURL": "https://huggingface.co/a/resolve/main/m.gguf",
      ] as [String: Any],
      format: .binary, options: 0)
    try resumeBlob.write(to: resumeFile)

    let payload = Data("payload-fresh".utf8)
    MockURLProtocol.handler = { _ in
      let response = HTTPURLResponse(
        url: URL(string: "https://huggingface.co/a/resolve/main/m.gguf")!,
        statusCode: 200, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Length": "\(payload.count)"])!
      return (response, payload)
    }
    let downloader = makeDownloader(modelsRoot: temp)
    defer { downloader.invalidate() }

    let handle = try downloader.start(repo: "a/b", file: "m.gguf").get()
    // The purge runs synchronously inside start before resume blob load.
    XCTAssertFalse(FileManager.default.fileExists(atPath: resumeFile.path),
                   ".resume next to an existing destination must be purged at start (F3)")
    try await awaitTerminalProgress(for: handle, in: downloader,
                                    expected: .completed)
    XCTAssertEqual(try Data(contentsOf: destination), payload)
  }

  func test_start_normal_path_surfaces_fresh_reason() async throws {
    let temp = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: temp) }
    let payload = Data("fresh-path".utf8)
    MockURLProtocol.handler = { _ in
      let response = HTTPURLResponse(
        url: URL(string: "https://huggingface.co/n/resolve/main/m.gguf")!,
        statusCode: 200, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Length": "\(payload.count)"])!
      return (response, payload)
    }
    let downloader = makeDownloader(modelsRoot: temp)
    defer { downloader.invalidate() }
    let handle = try downloader.start(repo: "n/n", file: "m.gguf").get()
    let firstEvent = try await collectFirstEvent(for: handle, in: downloader)
    XCTAssertEqual(firstEvent.startReason, .fresh)
  }

  // Review v2 F5 wire-smuggling test removed in review v3 F1: no GUI
  // consumer existed for the `resume=available|unavailable` token,
  // and the encode path was therefore dead code masquerading as a
  // user-visible signal. `resumeAvailable` is now a logs-only
  // diagnostic on `DownloadError.transportFailed`; the typed wire
  // field arrives with  (XPC progress channel) when there's an
  // actual consumer.

  // MARK: - Review v3 F1: transportFailed payload no longer encodes resume token

  /// Belt-and-braces: the message produced for `.transportFailed`
  /// must NOT contain `resume=` after review v3 F1 dropped the
  /// undefended wire smuggling. If a future contributor accidentally
  /// re-introduces the encode path without wiring a consumer, this
  /// test catches it.
  func test_transport_failure_engineerror_does_not_encode_resume_token() {
    let mapped = HelperExportedAPI.engineError(
      forDownload: .transportFailed(message: "ECONNRESET",
                                    resumeAvailable: true,
                                    urlErrorCode: nil))
    XCTAssertFalse(mapped.message.contains("resume="),
                   "F1: wire surface must not encode the resume token until a real consumer lands")
  }

  // MARK: - Review v3 F4: rename(2) helper invoked through public hook

  /// Smoke-tests `ModelDownloader.placeAtomic` against the happy
  /// path: source exists, destination doesn't.
  func test_placeAtomic_renames_when_destination_absent() throws {
    let temp = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: temp) }
    let partial = temp.appendingPathComponent("a.partial")
    let dest = temp.appendingPathComponent("a")
    try Data("payload".utf8).write(to: partial)
    let logger = Logger(subsystem: "test", category: "placeAtomic")
    try ModelDownloader.placeAtomic(partial: partial, destination: dest,
                                    fileManager: .default, log: logger)
    XCTAssertEqual(try Data(contentsOf: dest), Data("payload".utf8))
    XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
  }

  func test_placeAtomic_overwrites_existing_destination() throws {
    let temp = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: temp) }
    let partial = temp.appendingPathComponent("b.partial")
    let dest = temp.appendingPathComponent("b")
    try Data("OLD".utf8).write(to: dest)
    try Data("NEW".utf8).write(to: partial)
    let logger = Logger(subsystem: "test", category: "placeAtomic")
    try ModelDownloader.placeAtomic(partial: partial, destination: dest,
                                    fileManager: .default, log: logger)
    XCTAssertEqual(try Data(contentsOf: dest), Data("NEW".utf8))
  }

  // MARK: - Review v9 F3 / v10 F3: ErrorCause walk + hop bound

  /// The hop bound is the sole termination guarantee for the walk;
  /// exceeding the cap must return cleanly with `posixErrno=nil`
  /// rather than loop or crash. Review v10 F3 raised the bound to
  /// 6 — verify a chain LONGER than that still terminates safely.
  func test_errorCause_terminates_by_hop_bound_alone() {
    var deepest = NSError(domain: "test", code: 0)
    for hop in 1...10 {
      deepest = NSError(domain: "test", code: hop,
                        userInfo: [NSUnderlyingErrorKey: deepest])
    }
    let cause = ErrorCause.from(deepest)
    XCTAssertNil(cause.posixErrno,
                 "10-hop chain with no POSIX domain must terminate by hop bound")
  }

  /// Real field chains stack `NSURLErrorDomain` wrappers around
  /// Foundation file-IO chains that already nest 2-3 deep, pushing
  /// the POSIX bottom to hop 4-5. The v10 F3 hop-bound raise
  /// (4 → 6) must reach a POSIX leaf at hop 5.
  func test_errorCause_walks_five_hop_chain_to_posix() {
    let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(EROFS))
    let h4 = NSError(domain: NSCocoaErrorDomain,
                     code: NSFileWriteVolumeReadOnlyError,
                     userInfo: [NSUnderlyingErrorKey: posix])
    let h3 = NSError(domain: NSCocoaErrorDomain,
                     code: NSFileWriteUnknownError,
                     userInfo: [NSUnderlyingErrorKey: h4])
    let h2 = NSError(domain: NSCocoaErrorDomain,
                     code: NSFileWriteFileExistsError,
                     userInfo: [NSUnderlyingErrorKey: h3])
    let top = NSError(domain: NSURLErrorDomain,
                      code: NSURLErrorCannotWriteToFile,
                      userInfo: [NSUnderlyingErrorKey: h2])
    let cause = ErrorCause.from(top)
    XCTAssertEqual(cause.posixErrno, Int32(EROFS),
                   "5-hop chain (URL → Cocoa × 3 → POSIX) must reach the POSIX leaf within the v10 hop bound")
  }

  /// rename(2) failure (e.g., EACCES) surfaces as `POSIXError`
  /// with the captured errno. `placeAtomic` has no fallback path —
  /// any non-zero result throws.
  func test_placeAtomic_rename_failure_propagates_posix() throws {
    let temp = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: temp) }
    let partial = temp.appendingPathComponent("e.partial")
    let dest = temp.appendingPathComponent("e")
    try Data("X".utf8).write(to: partial)
    let logger = Logger(subsystem: "test", category: "placeAtomic")
    let alwaysEACCES: @Sendable (UnsafePointer<CChar>, UnsafePointer<CChar>) -> ModelDownloader.RenameResult = { _, _ in
      ModelDownloader.RenameResult(result: -1, posixErrno: EACCES)
    }
    XCTAssertThrowsError(
      try ModelDownloader.placeAtomic(partial: partial, destination: dest,
                                      fileManager: .default, log: logger,
                                      renameSyscall: alwaysEACCES)
    ) { error in
      guard let posix = error as? POSIXError else {
        XCTFail("expected POSIXError, got \(error)")
        return
      }
      XCTAssertEqual(posix.code, .EACCES)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path),
                   "rename failure must not place destination")
  }

  // MARK: - Review v6 F3: orphan-sidecar log at start

  /// `start(repo:file:)` defensive purge of a sidecar next to an
  /// already-placed destination represents the cancel-vs-placement
  /// race losing condition. The purge is silent in `log stream`
  /// today only when sidecar is ABSENT; when sidecar is present the
  /// `.error` log line "ORPHAN SIDECAR DETECTED" must fire so an
  /// operator can correlate the orphan with a prior cancel race.
  ///
  /// Without an os_log capture seam, we can't assert the exact log
  /// line — verify the operational outcome instead: a sidecar
  /// adjacent to an existing destination IS removed by start, AND
  /// the fresh download succeeds. The log message itself is
  /// straight-line code on the same branch.
  func test_start_purges_orphan_sidecar_next_to_existing_destination() async throws {
    let temp = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: temp) }
    let destinationDir = temp.appendingPathComponent("orph/repo", isDirectory: true)
    try FileManager.default.createDirectory(at: destinationDir,
                                            withIntermediateDirectories: true)
    let destination = destinationDir.appendingPathComponent("m.gguf")
    let resumeFile = destinationDir.appendingPathComponent("m.gguf.resume")
    try Data("prior".utf8).write(to: destination)
    // Plant a structurally-valid resume blob (with required keys)
    // so `loadResumeBlobOrPurge` would have accepted it absent the
    // destination-exists short-circuit.
    let resumeBlob = try PropertyListSerialization.data(
      fromPropertyList: [
        "NSURLSessionResumeInfoVersion": 2,
        "NSURLSessionDownloadURL": "https://huggingface.co/orph/resolve/main/m.gguf",
      ] as [String: Any],
      format: .binary, options: 0)
    try resumeBlob.write(to: resumeFile)

    let payload = Data("fresh-orphan".utf8)
    MockURLProtocol.handler = { _ in
      let response = HTTPURLResponse(
        url: URL(string: "https://huggingface.co/orph/resolve/main/m.gguf")!,
        statusCode: 200, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Length": "\(payload.count)"])!
      return (response, payload)
    }
    let downloader = makeDownloader(modelsRoot: temp)
    defer { downloader.invalidate() }
    let handle = try downloader.start(repo: "orph/repo", file: "m.gguf").get()
    XCTAssertFalse(FileManager.default.fileExists(atPath: resumeFile.path),
                   "orphan sidecar next to existing destination must be purged at start (F3 operational outcome)")
    try await awaitTerminalProgress(for: handle, in: downloader,
                                    expected: .completed)
  }

  // MARK: - Review v7 F5: typed ErrorCause on writeFailed

  /// `ErrorCause.from(_:)` must extract a POSIX errno from
  /// `NSPOSIXErrorDomain` errors and from NSError chains where the
  /// underlying cause is POSIX (the common Foundation file-IO
  /// shape). Without this the GUI / log scraper cannot branch on
  /// EBUSY vs EPERM vs EROFS for retry policy.
  func test_errorCause_extracts_posix_errno_from_nserror_chain() {
    let posixErr = POSIXError(.EBUSY)
    let direct = ErrorCause.from(posixErr)
    XCTAssertEqual(direct.posixErrno, Int32(EBUSY),
                   "POSIXError must surface its rawValue as posixErrno")

    let nsPosix = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
    let fromPosixDomain = ErrorCause.from(nsPosix)
    XCTAssertEqual(fromPosixDomain.posixErrno, Int32(EPERM),
                   "NSError in NSPOSIXErrorDomain must surface its code as posixErrno")

    let wrapped = NSError(domain: NSCocoaErrorDomain,
                          code: NSFileWriteNoPermissionError,
                          userInfo: [NSUnderlyingErrorKey: nsPosix])
    let unwrapped = ErrorCause.from(wrapped)
    XCTAssertEqual(unwrapped.domain, NSCocoaErrorDomain)
    XCTAssertEqual(unwrapped.posixErrno, Int32(EPERM),
                   "ErrorCause must walk NSUnderlyingErrorKey to surface POSIX cause")

    let nonPosix = NSError(domain: "test.domain", code: 42)
    let unknown = ErrorCause.from(nonPosix)
    XCTAssertNil(unknown.posixErrno,
                 "ErrorCause.posixErrno must be nil when no POSIX errno can be extracted")
    XCTAssertEqual(unknown.domain, "test.domain")
    XCTAssertEqual(unknown.code, 42)
  }

  /// `HelperExportedAPI.engineError` must embed the structured cause
  /// tokens (`domain=` `code=` `errno=`) in the surfaced
  /// `EngineError.message` so a downstream log scraper can extract
  /// them without parsing the free-form prefix (review v7 F5).
  func test_writeFailed_wire_message_carries_structured_cause_tokens() {
    let cause = ErrorCause(domain: NSCocoaErrorDomain,
                           code: NSFileWriteNoPermissionError,
                           posixErrno: Int32(EPERM))
    let mapped = HelperExportedAPI.engineError(
      forDownload: .writeFailed(message: "rename failed", cause: cause))
    XCTAssertTrue(mapped.message.contains("domain=\(NSCocoaErrorDomain)"),
                  "message must carry domain= token (F5)")
    XCTAssertTrue(mapped.message.contains("code=\(NSFileWriteNoPermissionError)"),
                  "message must carry code= token (F5)")
    XCTAssertTrue(mapped.message.contains("errno=\(EPERM)"),
                  "message must carry errno= token (F5)")
  }

  // MARK: - Review v8 F1: multi-hop NSUnderlyingErrorKey walk

  /// Foundation file-IO errors usually wrap POSIX one hop deep, but
  /// structurally-legal multi-hop chains exist
  /// (`NSFileWriteUnknownError → NSFileWriteVolumeReadOnlyError →
  /// NSPOSIXErrorDomain/EROFS`). The walk must surface the POSIX
  /// errno regardless of nesting depth (bounded at 4 hops to guard
  /// against pathological cycles).
  func test_errorCause_walks_multi_hop_chain_to_posix() {
    let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(EROFS))
    let mid = NSError(domain: NSCocoaErrorDomain,
                      code: NSFileWriteVolumeReadOnlyError,
                      userInfo: [NSUnderlyingErrorKey: posix])
    let top = NSError(domain: NSCocoaErrorDomain,
                      code: NSFileWriteUnknownError,
                      userInfo: [NSUnderlyingErrorKey: mid])
    let cause = ErrorCause.from(top)
    XCTAssertEqual(cause.domain, NSCocoaErrorDomain,
                   "top-level domain preserved")
    XCTAssertEqual(cause.code, NSFileWriteUnknownError,
                   "top-level code preserved")
    XCTAssertEqual(cause.posixErrno, Int32(EROFS),
                   "POSIX errno must surface from 2-hop NSUnderlyingErrorKey chain (F1)")
  }

  /// Cycles in `NSUnderlyingErrorKey` are not supposed to exist but
  /// can be hand-constructed; the walk must terminate without
  /// infinite-looping. Cap at 4 hops + identity seen-set.
  func test_errorCause_terminates_on_cycle() {
    // Hand-build a 2-cycle. NSError userInfo is read-only after init,
    // so we use NSMutableDictionary's reference semantics via
    // `setValue(_:forKey:)` through the mutableUserInfo seam — Swift
    // bridge doesn't expose mutation, so simulate via two pre-built
    // NSError chains that self-reference at the leaf is impossible.
    // Instead build a 5-hop linear chain that EXCEEDS the depth cap;
    // walk must return nil rather than crash.
    var deepest = NSError(domain: "test", code: 0)
    for hop in 1...5 {
      deepest = NSError(domain: "test", code: hop,
                        userInfo: [NSUnderlyingErrorKey: deepest])
    }
    let cause = ErrorCause.from(deepest)
    // 5 hops > 4-hop cap; POSIX (which isn't in the chain anyway)
    // returns nil rather than walking forever or crashing.
    XCTAssertNil(cause.posixErrno,
                 "walk must cap at bounded depth without infinite loop")
  }

  // MARK: - Review v8 F2: domain percent-encoding round-trip

  /// Free-form `NSError.domain` may contain whitespace, `=`, or `]`
  /// (third-party domains). The cause-token packing must escape
  /// these so a scraper splitting on `[domain=… code=… errno=…]`
  /// doesn't misread.
  func test_writeFailed_wire_message_escapes_problematic_domain_chars() {
    let cause = ErrorCause(domain: "Pie Helper=test]Domain",
                           code: 42,
                           posixErrno: Int32(EPERM))
    let mapped = HelperExportedAPI.engineError(
      forDownload: .writeFailed(message: "stuff", cause: cause))
    // The literal bad characters must NOT appear inside the
    // [domain=… …] token — they'd break the parser. Verify by
    // checking the token bracket structure is preserved and the
    // domain percent-decodes back to the original.
    XCTAssertTrue(mapped.message.contains("domain="))
    XCTAssertTrue(mapped.message.contains("code=42"))
    XCTAssertTrue(mapped.message.contains("errno=\(EPERM)"))
    // Extract the domain value between `domain=` and the next ` `
    // (now safe because spaces in the domain are %20-encoded).
    let msg = mapped.message
    guard let domainRange = msg.range(of: "domain=") else {
      XCTFail("token absent"); return
    }
    let afterDomain = msg[domainRange.upperBound...]
    let domainValue = String(afterDomain.prefix { $0 != " " })
    XCTAssertEqual(domainValue.removingPercentEncoding,
                   "Pie Helper=test]Domain",
                   "scraper must recover the original domain via removingPercentEncoding (F2)")
  }

  func test_writeFailed_wire_message_omits_tokens_when_cause_is_nil() {
    let mapped = HelperExportedAPI.engineError(
      forDownload: .writeFailed(message: "synth failure", cause: nil))
    XCTAssertFalse(mapped.message.contains("domain="),
                   "no cause → no structured tokens; the message stays clean")
    XCTAssertFalse(mapped.message.contains("errno="))
    XCTAssertTrue(mapped.message.contains("synth failure"))
  }

  // MARK: - Review v5 F3: posixRenameSyscall captures errno correctly

  /// Regression guard for the bare `Darwin.errno` snapshot in the
  /// production rename closure. Drive a real rename failure
  /// (non-existent source → ENOENT) through `posixRenameSyscall`
  /// and assert the captured `posixErrno` matches. Without this
  /// test, a future maintainer inserting a `log.debug(...)` between
  /// `rename(2)` and the snapshot — which would call malloc and
  /// clobber TLS errno — would silently corrupt the surfaced errno.
  func test_posixRenameSyscall_captures_ENOENT_for_missing_source() throws {
    let temp = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: temp) }
    let missing = temp.appendingPathComponent("does-not-exist")
    let dest = temp.appendingPathComponent("any-dest")
    let result = missing.withUnsafeFileSystemRepresentation { src -> ModelDownloader.RenameResult in
      dest.withUnsafeFileSystemRepresentation { dst -> ModelDownloader.RenameResult in
        ModelDownloader.posixRenameSyscall(src!, dst!)
      }
    }
    XCTAssertEqual(result.result, -1,
                   "rename(2) on missing source must fail")
    XCTAssertEqual(result.posixErrno, ENOENT,
                   "captured posixErrno must reflect the syscall (F3 — guards against TLS errno clobbering by an inadvertent allocation between rename and snapshot)")
  }

  // MARK: - Review v15 F1: path traversal at XPC boundary

  /// `appendingPathComponent` does NOT normalize `..` segments, so a
  /// malicious XPC client could escape `modelsRoot` with a crafted
  /// `repo` and have the privileged helper create dirs / atomic-rename
  /// files anywhere reachable under the helper UID. `start()` MUST
  /// reject `..`, leading `/`, NUL bytes, and empty segments BEFORE
  /// any filesystem operation.
  func test_start_rejects_repo_with_parent_dir_traversal() throws {
    let temp = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: temp) }
    let downloader = makeDownloader(modelsRoot: temp)
    defer { downloader.invalidate() }
    switch downloader.start(repo: "../escape", file: "x") {
    case .failure(.invalidArguments):
      break
    default:
      XCTFail("expected invalidArguments for '..' segment in repo")
    }
    // No filesystem side effect should have landed under modelsRoot.
    let contents = try FileManager.default.contentsOfDirectory(atPath: temp.path)
    XCTAssertTrue(contents.isEmpty,
                  "rejection must precede mkdir — modelsRoot must remain empty")
  }

  func test_start_rejects_absolute_path_repo() throws {
    let temp = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: temp) }
    let downloader = makeDownloader(modelsRoot: temp)
    defer { downloader.invalidate() }
    switch downloader.start(repo: "/Users/attacker/Library/LaunchAgents", file: "evil.plist") {
    case .failure(.invalidArguments):
      break
    default:
      XCTFail("expected invalidArguments for absolute-path repo")
    }
  }

  func test_start_rejects_file_with_parent_dir_traversal() throws {
    let temp = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: temp) }
    let downloader = makeDownloader(modelsRoot: temp)
    defer { downloader.invalidate() }
    switch downloader.start(repo: "org/name", file: "../../etc/passwd") {
    case .failure(.invalidArguments):
      break
    default:
      XCTFail("expected invalidArguments for '..' segment in file")
    }
  }

  func test_start_rejects_repo_with_nul_byte() throws {
    let temp = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: temp) }
    let downloader = makeDownloader(modelsRoot: temp)
    defer { downloader.invalidate() }
    switch downloader.start(repo: "org\u{0}name", file: "x") {
    case .failure(.invalidArguments):
      break
    default:
      XCTFail("expected invalidArguments for NUL byte in repo")
    }
  }

  func test_rejectionForUnsafePathComponent_accepts_valid_repo_and_file() {
    XCTAssertNil(ModelDownloader.rejectionForUnsafePathComponent("TheBloke/Llama-2-7B-GGUF", role: "repo"))
    XCTAssertNil(ModelDownloader.rejectionForUnsafePathComponent("model-Q4_K_M.gguf", role: "file"))
    XCTAssertNil(ModelDownloader.rejectionForUnsafePathComponent("quantized/Q4_K_M.gguf", role: "file"))
  }

  // MARK: - Review v16 F1: symlink-resolution defends descendant check

  /// A symlink planted inside modelsRoot pointing outside lets the
  /// post-composition descendant check pass lexically but the kernel
  /// follows the link on `createDirectory` + `placeAtomic`. v15 used
  /// `standardizedFileURL` which does NOT resolve symlinks. v16
  /// switches to `resolvingSymlinksInPath()` (`realpath(3)`). Plant
  /// `<modelsRoot>/evil → <escapeTarget>` and assert
  /// `start(repo: "evil", ...)` is rejected before any FS write at
  /// the escape target.
  func test_start_rejects_symlink_escape_via_repo() throws {
    let modelsRoot = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: modelsRoot) }
    let escapeTarget = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: escapeTarget) }
    let evilLink = modelsRoot.appendingPathComponent("evil")
    try FileManager.default.createSymbolicLink(at: evilLink,
                                               withDestinationURL: escapeTarget)
    let downloader = makeDownloader(modelsRoot: modelsRoot)
    defer { downloader.invalidate() }
    switch downloader.start(repo: "evil", file: "payload.gguf") {
    case .failure(.invalidArguments):
      break
    default:
      XCTFail("symlink-escape repo must surface as invalidArguments (v16 F1)")
    }
    let escapeContents = try FileManager.default.contentsOfDirectory(atPath: escapeTarget.path)
    XCTAssertTrue(escapeContents.isEmpty,
                  "rejection must precede any FS write at the symlink target")
  }

  // MARK: - Review v16 F2 / v17 F5: invalidArguments distinct + invalidInput wire code

  /// Path-traversal rejection and modelsRoot unavailability must
  /// surface as DIFFERENT EngineErrorCodes. v17 F5 reroutes
  /// `.invalidArguments` from `.wireContractViolation` (reserved for
  /// RatioThink-internal plumbing bugs) to `.invalidInput` so the GUI
  /// renders "please correct repo/file" instead of "RatioThink internal bug
  /// — please file a bug report."
  func test_engineError_invalidArguments_maps_to_invalidInput() {
    let invalid = HelperExportedAPI.engineError(
      forDownload: .invalidArguments(message: "repo contains '..' segment"))
    XCTAssertEqual(invalid.code, .invalidInput,
                   "invalidArguments must map to .invalidInput (caller-input class, v17 F5)")
    XCTAssertNotEqual(invalid.code, .wireContractViolation,
                      ".wireContractViolation is reserved for XPC plumbing bugs per its doc-comment (v17 F5)")
    XCTAssertTrue(invalid.message.contains("invalid arguments"),
                  "wire message must carry the invalid-arguments token for log scrapers")

    let modelsDown = HelperExportedAPI.engineError(
      forDownload: .modelsRootUnavailable(message: "FileVault locked"))
    XCTAssertEqual(modelsDown.code, .degraded,
                   "modelsRootUnavailable must remain on .degraded (transient)")
    XCTAssertNotEqual(invalid.code, modelsDown.code,
                      "the two failure classes MUST surface distinct codes (F2)")
  }

  // MARK: - Review v16 F3 / v17 F6: PathUnrepresentable typing + discriminator

  /// `PathUnrepresentable` is a distinct Swift type so callers can
  /// branch on the throw type rather than overloading errno=22 with
  /// real `rename(2)` EINVAL returns (v16 F3). v17 F6 adds
  /// `Equatable`/`Sendable` conformance + `which` discriminator so
  /// the failure class survives both Swift 6 actor crossings and
  /// the `.invalidArguments` stringification path.
  func test_placeAtomic_pathUnrepresentable_is_distinct_throw_type() {
    let err = ModelDownloader.PathUnrepresentable(which: .destination,
                                                  partialPath: "/tmp/a.partial",
                                                  destinationPath: "/tmp/a")
    XCTAssertTrue(err.description.contains("filesystem representation unavailable"),
                  "description must signal the failure class so log scrapers can grep it")
    XCTAssertTrue(err.description.contains("which=destination"),
                  "description must surface the discriminator so the .invalidArguments stringification preserves the failure class (v17 F6)")
    func thrower() throws { throw err }
    do {
      try thrower()
      XCTFail("must throw")
    } catch let caught as ModelDownloader.PathUnrepresentable {
      XCTAssertEqual(caught.which, .destination)
      XCTAssertEqual(caught.partialPath, "/tmp/a.partial")
      XCTAssertEqual(caught.destinationPath, "/tmp/a")
    } catch {
      XCTFail("caught wrong type: \(error) — must be PathUnrepresentable, not \(type(of: error))")
    }
  }

  /// v17 F6: `Equatable` conformance lets call sites pattern-match
  /// on full identity rather than parsing `description`.
  func test_pathUnrepresentable_equatable_compares_all_fields() {
    let a1 = ModelDownloader.PathUnrepresentable(which: .partial,
                                                 partialPath: "/x.partial",
                                                 destinationPath: "/x")
    let a2 = ModelDownloader.PathUnrepresentable(which: .partial,
                                                 partialPath: "/x.partial",
                                                 destinationPath: "/x")
    XCTAssertEqual(a1, a2)
    let differentWhich = ModelDownloader.PathUnrepresentable(which: .destination,
                                                             partialPath: "/x.partial",
                                                             destinationPath: "/x")
    XCTAssertNotEqual(a1, differentWhich,
                      "discriminator must participate in equality (v17 F6)")
  }

  // MARK: - Review v16 F4: unsafe-sentinel forces fresh restart

  func test_unsafeSentinelURL_appends_unsafe_suffix_in_same_directory() {
    let resumeFile = URL(fileURLWithPath: "/tmp/models/repo/file.gguf.resume")
    let sentinel = ModelDownloader.unsafeSentinelURL(forResumeFile: resumeFile)
    XCTAssertEqual(sentinel.lastPathComponent, "file.gguf.resume-unsafe")
    XCTAssertEqual(sentinel.deletingLastPathComponent().path,
                   resumeFile.deletingLastPathComponent().path)
  }

  // MARK: - Review v18: corrupt-resume restart surfaces distinct startReason

  /// Sidecar present but corrupt (non-plist bytes) must purge AND
  /// surface `.restartedAfterCorruptResume` so the GUI distinguishes
  /// "had resume data, was bad" from a clean first start (v18).
  func test_start_corrupt_resume_blob_surfaces_restartedAfterCorruptResume_reason() async throws {
    let temp = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: temp) }
    let destinationDir = temp.appendingPathComponent("n/n", isDirectory: true)
    try FileManager.default.createDirectory(at: destinationDir,
                                            withIntermediateDirectories: true)
    let resumeFile = destinationDir.appendingPathComponent("m.gguf.resume")
    // Non-plist bytes — read succeeds, plist parse fails, purge.
    try Data("not a plist".utf8).write(to: resumeFile)

    let payload = Data("fresh-after-corrupt".utf8)
    MockURLProtocol.handler = { _ in
      let response = HTTPURLResponse(
        url: URL(string: "https://huggingface.co/n/n/resolve/main/m.gguf")!,
        statusCode: 200, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Length": "\(payload.count)"])!
      return (response, payload)
    }
    let downloader = makeDownloader(modelsRoot: temp)
    defer { downloader.invalidate() }
    let handle = try downloader.start(repo: "n/n", file: "m.gguf").get()
    let firstEvent = try await collectFirstEvent(for: handle, in: downloader)
    XCTAssertEqual(firstEvent.startReason, .restartedAfterCorruptResume,
                   "corrupt resume blob purge must surface .restartedAfterCorruptResume (v18)")
    XCTAssertFalse(FileManager.default.fileExists(atPath: resumeFile.path),
                   "corrupt sidecar must be purged during loadResumeBlobOrPurge")
  }

  /// Sidecar present + missing required URLSession resume keys must
  /// also surface `.restartedAfterCorruptResume`.
  func test_start_resume_blob_missing_keys_surfaces_restartedAfterCorruptResume_reason() async throws {
    let temp = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: temp) }
    let destinationDir = temp.appendingPathComponent("n/n", isDirectory: true)
    try FileManager.default.createDirectory(at: destinationDir,
                                            withIntermediateDirectories: true)
    let resumeFile = destinationDir.appendingPathComponent("m.gguf.resume")
    // Valid plist dict but missing the required URLSession keys.
    let bogus: [String: Any] = ["unrelated": "value"]
    let bogusData = try PropertyListSerialization.data(fromPropertyList: bogus,
                                                       format: .binary, options: 0)
    try bogusData.write(to: resumeFile)

    let payload = Data("missing-keys".utf8)
    MockURLProtocol.handler = { _ in
      let response = HTTPURLResponse(
        url: URL(string: "https://huggingface.co/n/n/resolve/main/m.gguf")!,
        statusCode: 200, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Length": "\(payload.count)"])!
      return (response, payload)
    }
    let downloader = makeDownloader(modelsRoot: temp)
    defer { downloader.invalidate() }
    let handle = try downloader.start(repo: "n/n", file: "m.gguf").get()
    let firstEvent = try await collectFirstEvent(for: handle, in: downloader)
    XCTAssertEqual(firstEvent.startReason, .restartedAfterCorruptResume,
                   "missing-keys sidecar purge must surface .restartedAfterCorruptResume (v18)")
  }

  /// Unsafe-sentinel path also funnels into `.restartedAfterCorruptResume`
  /// since the operational meaning ("we had resume data but couldn't
  /// trust it") is identical from the GUI's perspective.
  func test_start_unsafe_sentinel_surfaces_restartedAfterCorruptResume_reason() async throws {
    let modelsRoot = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: modelsRoot) }
    let destinationDir = modelsRoot.appendingPathComponent("repo", isDirectory: true)
    try FileManager.default.createDirectory(at: destinationDir,
                                            withIntermediateDirectories: true)
    let resumeFile = destinationDir.appendingPathComponent("m.gguf.resume")
    let sentinel = ModelDownloader.unsafeSentinelURL(forResumeFile: resumeFile)
    let blob: [String: Any] = [
      "NSURLSessionResumeInfoVersion": 1,
      "NSURLSessionDownloadURL": "https://huggingface.co/repo/resolve/main/m.gguf",
    ]
    let blobData = try PropertyListSerialization.data(fromPropertyList: blob,
                                                      format: .binary, options: 0)
    try blobData.write(to: resumeFile)
    try Data().write(to: sentinel)

    let payload = Data("sentinel-restart".utf8)
    MockURLProtocol.handler = { _ in
      let response = HTTPURLResponse(
        url: URL(string: "https://huggingface.co/repo/resolve/main/m.gguf")!,
        statusCode: 200, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Length": "\(payload.count)"])!
      return (response, payload)
    }
    let downloader = makeDownloader(modelsRoot: modelsRoot)
    defer { downloader.invalidate() }
    let handle = try downloader.start(repo: "repo", file: "m.gguf").get()
    let firstEvent = try await collectFirstEvent(for: handle, in: downloader)
    XCTAssertEqual(firstEvent.startReason, .restartedAfterCorruptResume,
                   "unsafe-sentinel path must also surface .restartedAfterCorruptResume (v18)")
  }

  /// A pre-existing `-unsafe` sentinel at `start()` must cause both
  /// the sentinel AND the resume sidecar to be purged before the
  /// fresh download begins (v16 F4 recovery semantics).
  func test_start_purges_resume_and_sentinel_when_unsafe_sentinel_present() async throws {
    let modelsRoot = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: modelsRoot) }
    let destinationDir = modelsRoot.appendingPathComponent("repo", isDirectory: true)
    try FileManager.default.createDirectory(at: destinationDir,
                                            withIntermediateDirectories: true)
    let resumeFile = destinationDir.appendingPathComponent("m.gguf.resume")
    let sentinel = ModelDownloader.unsafeSentinelURL(forResumeFile: resumeFile)
    let fakeResumeBlob: [String: Any] = [
      "NSURLSessionResumeInfoVersion": 1,
      "NSURLSessionDownloadURL": "https://huggingface.co/repo/resolve/main/m.gguf",
    ]
    let blobData = try PropertyListSerialization.data(fromPropertyList: fakeResumeBlob,
                                                      format: .binary, options: 0)
    try blobData.write(to: resumeFile)
    try Data().write(to: sentinel)

    let payload = Data("fresh-after-unsafe".utf8)
    MockURLProtocol.handler = { _ in
      let response = HTTPURLResponse(
        url: URL(string: "https://huggingface.co/repo/resolve/main/m.gguf")!,
        statusCode: 200, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Length": "\(payload.count)"])!
      return (response, payload)
    }
    let downloader = makeDownloader(modelsRoot: modelsRoot)
    defer { downloader.invalidate() }
    let handle: DownloadHandle
    switch downloader.start(repo: "repo", file: "m.gguf") {
    case .success(let h): handle = h
    case .failure(let e): XCTFail("start failed: \(e)"); return
    }
    try await awaitTerminalProgress(for: handle, in: downloader,
                                    expected: .completed)
    XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path),
                   "unsafe sentinel must be removed by loadResumeBlobOrPurge (F4)")
    let destination = destinationDir.appendingPathComponent("m.gguf")
    XCTAssertEqual(try Data(contentsOf: destination), payload,
                   "fresh download must produce canonical destination after unsafe-sentinel purge")
  }

  /// Review v17 F4: if sidecar purge fails (read-only dir / EBUSY)
  /// the sentinel MUST be kept in place so the next start retries
  /// the purge. Dropping the sentinel unconditionally would leave
  /// sidecar-present + sentinel-absent, restoring trust in a
  /// possibly-lost-dir-entry sidecar — the exact case F4 was
  /// designed to prevent.
  func test_start_retains_sentinel_when_sidecar_purge_fails() async throws {
    let modelsRoot = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: modelsRoot) }
    let destinationDir = modelsRoot.appendingPathComponent("repo", isDirectory: true)
    try FileManager.default.createDirectory(at: destinationDir,
                                            withIntermediateDirectories: true)
    let resumeFile = destinationDir.appendingPathComponent("m.gguf.resume")
    let sentinel = ModelDownloader.unsafeSentinelURL(forResumeFile: resumeFile)
    let fakeResumeBlob: [String: Any] = [
      "NSURLSessionResumeInfoVersion": 1,
      "NSURLSessionDownloadURL": "https://huggingface.co/repo/resolve/main/m.gguf",
    ]
    let blobData = try PropertyListSerialization.data(fromPropertyList: fakeResumeBlob,
                                                      format: .binary, options: 0)
    try blobData.write(to: resumeFile)
    try Data().write(to: sentinel)

    // Make the dir read-only so `removeItem(at: resumeFile)` returns
    // EACCES — `purgeResumeSidecar` swallows the error as a logged
    // warning, leaving the sidecar on disk. The sentinel-removal
    // ordering guard must NOT drop the sentinel under that condition.
    let originalMode = (try FileManager.default.attributesOfItem(atPath: destinationDir.path)[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o755
    try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: UInt16(0o555))],
                                          ofItemAtPath: destinationDir.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: originalMode)],
                                             ofItemAtPath: destinationDir.path)
    }

    let payload = Data("fresh".utf8)
    MockURLProtocol.handler = { _ in
      let response = HTTPURLResponse(
        url: URL(string: "https://huggingface.co/repo/resolve/main/m.gguf")!,
        statusCode: 200, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Length": "\(payload.count)"])!
      return (response, payload)
    }
    let downloader = makeDownloader(modelsRoot: modelsRoot)
    defer { downloader.invalidate() }
    // The download itself will fail to land (dir is read-only) but
    // that's fine — we're only verifying sentinel retention through
    // `loadResumeBlobOrPurge`'s ordering guard.
    _ = downloader.start(repo: "repo", file: "m.gguf")

    // Critical assertion: sentinel must NOT have been removed when
    // the sidecar purge failed. Both files survive.
    XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path),
                  "sentinel must remain on disk when sidecar purge failed (v17 F4)")
    XCTAssertTrue(FileManager.default.fileExists(atPath: resumeFile.path),
                  "sidecar survives the failed purge (test precondition)")
  }

  // MARK: - Review v15 F2: safe URL builder

  /// The HF URL builder must percent-encode path segments so XPC-
  /// supplied repo/file with URL-significant characters can't break
  /// parsing or smuggle query/fragment delimiters into the path.
  func test_huggingFaceURLBuilder_percent_encodes_problematic_chars() {
    // `+` in upstream literal becomes ` ` after URL decoding; encode.
    // `#` would terminate the path early and turn the suffix into a
    // fragment. `?` would smuggle an unintended query. Space must
    // not appear raw in URLs.
    let cases: [(String, String, [String])] = [
      ("org+plus", "file space.gguf", ["org%2Bplus", "%20"]),
      ("org#frag", "f.gguf", ["org%23frag"]),
      ("org?q=1", "f.gguf", ["org%3Fq%3D1"]),
    ]
    for (repo, file, expectedSubstrings) in cases {
      guard let url = ModelDownloader.huggingFaceURLBuilder(repo, file) else {
        XCTFail("builder must not crash or return nil for repo=\(repo) file=\(file)")
        continue
      }
      let s = url.absoluteString
      XCTAssertTrue(s.hasPrefix("https://huggingface.co/"),
                    "url must remain anchored at huggingface.co (got \(s))")
      XCTAssertTrue(s.contains("download=true"),
                    "download flag must survive percent-encoding (got \(s))")
      for needle in expectedSubstrings {
        XCTAssertTrue(s.contains(needle),
                      "expected percent-encoded marker \(needle) in \(s)")
      }
    }
  }

  /// Builder is fallible-by-type so any future input that fails
  /// percent-encoding surfaces as nil instead of crashing the helper.
  func test_huggingFaceURLBuilder_returns_non_nil_for_normal_inputs() {
    let url = ModelDownloader.huggingFaceURLBuilder("TheBloke/Llama-2-7B-GGUF",
                                                    "llama-2-7b.Q4_K_M.gguf")
    XCTAssertNotNil(url, "happy-path builder result must be non-nil")
    XCTAssertEqual(url?.host, "huggingface.co")
    XCTAssertEqual(url?.path, "/TheBloke/Llama-2-7B-GGUF/resolve/main/llama-2-7b.Q4_K_M.gguf")
    XCTAssertEqual(url?.query, "download=true")
  }

  // MARK: - helpers

  private func drainToTerminal(_ stream: AsyncStream<DownloadProgress>) async -> DownloadProgress.Phase? {
    for await event in stream {
      switch event.phase {
      case .completed, .failed, .cancelled:
        return event.phase
      default:
        continue
      }
    }
    return nil
  }

  /// Collect the first event from `progress(for:)`, then drop the
  /// subscription. Used by tests that only care about the
  /// `.starting` snapshot.
  private func collectFirstEvent(for handle: DownloadHandle,
                                 in downloader: ModelDownloader,
                                 timeout: TimeInterval = 5) async throws -> DownloadProgress {
    let stream = downloader.progress(for: handle)
    let deadline = Date().addingTimeInterval(timeout)
    for await event in stream {
      return event
    }
    _ = deadline
    throw NSError(domain: "test", code: 0,
                  userInfo: [NSLocalizedDescriptionKey: "no events"])
  }

  private func collectTerminalEvent(for handle: DownloadHandle,
                                    in downloader: ModelDownloader,
                                    timeout: TimeInterval = 5) async throws -> DownloadProgress {
    let stream = downloader.progress(for: handle)
    let deadline = Date().addingTimeInterval(timeout)
    var last: DownloadProgress?
    for await event in stream {
      last = event
      if [.completed, .failed, .cancelled].contains(event.phase) {
        return event
      }
      if Date() > deadline { break }
    }
    if let last { return last }
    throw NSError(domain: "test", code: 0, userInfo: [NSLocalizedDescriptionKey: "no terminal event"])
  }

  private func makeDownloader(modelsRoot: URL) -> ModelDownloader {
    ModelDownloader(
      sessionConfiguration: Self.protocolStubConfiguration(),
      modelsRoot: { modelsRoot },
      urlBuilder: ModelDownloader.huggingFaceURLBuilder)
  }

  private static func protocolStubConfiguration() -> URLSessionConfiguration {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [MockURLProtocol.self]
    cfg.timeoutIntervalForRequest = 5
    cfg.timeoutIntervalForResource = 5
    return cfg
  }

  /// Drain progress events until a terminal phase appears or the
  /// stream finishes. Times out at 5s so a deadlocked test fails red.
  private func awaitTerminalProgress(for handle: DownloadHandle,
                                     in downloader: ModelDownloader,
                                     expected: DownloadProgress.Phase,
                                     timeout: TimeInterval = 5) async throws {
    let stream = downloader.progress(for: handle)
    let deadline = Date().addingTimeInterval(timeout)
    var lastPhase: DownloadProgress.Phase?
    for await event in stream {
      lastPhase = event.phase
      switch event.phase {
      case .completed, .failed, .cancelled:
        XCTAssertEqual(event.phase, expected,
                       "terminal phase mismatch — last=\(event.phase)")
        return
      default:
        if Date() > deadline {
          XCTFail("timed out waiting for terminal phase; lastPhase=\(String(describing: lastPhase))")
          return
        }
        continue
      }
    }
    XCTAssertEqual(lastPhase, expected,
                   "stream ended without terminal event; lastPhase=\(String(describing: lastPhase))")
  }

  private func makeTempRoot() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("pie-dl-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  // MARK: - #720: user-facing failure copy (raw error stays in logs)

  /// A connection timeout must surface friendly, actionable copy — NOT
  /// the raw `Error Domain=NSURLErrorDomain Code=-1001 …` NSError dump.
  func test_userFacingMessage_timeout_is_friendly_and_actionable() {
    let msg = DownloadError.transportFailed(
      message: "Error Domain=NSURLErrorDomain Code=-1001 \"The request timed out.\"",
      resumeAvailable: false,
      urlErrorCode: NSURLErrorTimedOut).userFacingMessage
    XCTAssertTrue(msg.lowercased().contains("timed out"), "must name the timeout: \(msg)")
    XCTAssertFalse(msg.contains("NSURLErrorDomain"), "must not leak the raw NSError: \(msg)")
    XCTAssertFalse(msg.contains("-1001"), "must not leak the raw code: \(msg)")
  }

  /// Offline / unreachable-host transport errors map to a connection-
  /// check message rather than the raw transport string.
  func test_userFacingMessage_offline_points_at_connection() {
    for code in [NSURLErrorNotConnectedToInternet,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorCannotFindHost,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorDNSLookupFailed] {
      let msg = DownloadError.transportFailed(message: "raw \(code)",
                                              resumeAvailable: false,
                                              urlErrorCode: code).userFacingMessage
      XCTAssertTrue(msg.lowercased().contains("connection"),
                    "code \(code) must mention the connection: \(msg)")
      XCTAssertFalse(msg.contains("raw \(code)"), "must not leak the raw string: \(msg)")
    }
  }

  /// A transport error with no/unknown URL code still gets friendly
  /// copy, never the raw producer string.
  func test_userFacingMessage_generic_transport_is_friendly() {
    let msg = DownloadError.transportFailed(message: "ECONNRESET",
                                            resumeAvailable: false,
                                            urlErrorCode: nil).userFacingMessage
    XCTAssertFalse(msg.contains("ECONNRESET"), "must not leak the raw string: \(msg)")
    XCTAssertFalse(msg.isEmpty)
  }

  /// Non-transport failures are gated too: each maps to a distinct,
  /// raw-free, human caption.
  func test_userFacingMessage_other_cases_are_gated() {
    XCTAssertFalse(DownloadError.sha256Mismatch(expected: "abc", actual: "def")
      .userFacingMessage.contains("abc"))
    XCTAssertFalse(DownloadError.writeFailed(message: "rename ENOSPC", cause: nil)
      .userFacingMessage.contains("ENOSPC"))
    XCTAssertTrue(DownloadError.httpStatus(code: 404)
      .userFacingMessage.contains("404"))
    XCTAssertFalse(DownloadError.modelsRootUnavailable(message: "/secret/path")
      .userFacingMessage.contains("/secret/path"))
    XCTAssertFalse(DownloadError.invalidArguments(message: "../escape")
      .userFacingMessage.contains("../escape"))
  }
}

/// In-process URLProtocol stub. Tests assign `handler` per-test;
/// `reset()` clears it between tests so a leaked handler from a prior
/// test can't poison a later one.
///
/// `final class` because URLProtocol's lifecycle (instantiated by
/// URLSession on demand) doesn't tolerate subclassing the stub.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
  typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

  /// Returns a `(redirectResponse, newRequest)` pair when `request`
  /// should redirect (e.g. HF's `huggingface.co/resolve` → CDN), or
  /// nil to fall through to `handler`. Lets a test reproduce HF's
  /// real two-hop flow where `X-Linked-Etag` rides only the 3xx
  /// response and URLSession discards it before `task.response`
  /// populates.
  typealias RedirectHandler = @Sendable (URLRequest) -> (HTTPURLResponse, URLRequest)?

  /// Set per-test. Synchronized via the underlying URLSession queue —
  /// URLProtocol callbacks run serially on the session delegate queue,
  /// and tests assign `handler` strictly *before* kicking off a task.
  static nonisolated(unsafe) var handler: Handler?
  static nonisolated(unsafe) var redirectHandler: RedirectHandler?

  static func reset() {
    handler = nil
    redirectHandler = nil
  }

  override class func canInit(with request: URLRequest) -> Bool { true }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    if let redirectHandler = MockURLProtocol.redirectHandler,
       let (redirectResponse, newRequest) = redirectHandler(request) {
      // Emitting a redirect drives URLSession to invoke the task
      // delegate's `willPerformHTTPRedirection`, then re-issue the
      // request to `newRequest` (a fresh URLProtocol instance) —
      // mirroring HF's huggingface.co → CDN hop.
      client?.urlProtocol(self, wasRedirectedTo: newRequest, redirectResponse: redirectResponse)
      return
    }
    guard let handler = MockURLProtocol.handler else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    do {
      let (response, data) = try handler(request)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}
