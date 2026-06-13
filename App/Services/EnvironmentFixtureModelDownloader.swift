import Foundation

/// App-side deterministic downloader used only by package-backed GUI
/// E2E. Unlike `EnvironmentFakeModelDownloader`, this writes the
/// requested curated file to Rational's canonical model cache path so the
/// first-launch wizard exercises a real downloaded-model state under
/// the isolated `PIE_HOME`.
final class EnvironmentFixtureModelDownloader: ModelDownloading, @unchecked Sendable {
  private let environment: [String: String]

  init(environment: [String: String] = ProcessInfo.processInfo.environment) {
    self.environment = environment
  }

  func start(repo: String, file: String) -> Result<DownloadHandle, DownloadError> {
    let handle = DownloadHandle(repo: repo, file: file)
    do {
      let destination = try destinationURL(repo: repo, file: file)
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let payload = "pie fixture gguf\nrepo=\(repo)\nfile=\(file)\n"
      try payload.write(to: destination, atomically: true, encoding: .utf8)
      try writeProbeIfRequested(repo: repo, file: file, destination: destination, byteCount: payload.utf8.count)
      return .success(handle)
    } catch let error as DownloadError {
      return .failure(error)
    } catch {
      return .failure(.writeFailed(
        message: "fixture downloader could not write \(repo)/\(file): \(error)",
        cause: ErrorCause.from(error)
      ))
    }
  }

  func cancel(handle: DownloadHandle) -> DownloadError? {
    nil
  }

  func progress(for handle: DownloadHandle) -> AsyncStream<DownloadProgress> {
    AsyncStream { continuation in
      Task {
        let total: Int64 = 48
        continuation.yield(DownloadProgress(
          handleID: handle.id,
          phase: .starting,
          bytesReceived: 0,
          bytesExpected: total,
          etaSeconds: 1,
          startReason: .fresh
        ))
        try? await Task.sleep(nanoseconds: 75_000_000)
        continuation.yield(DownloadProgress(
          handleID: handle.id,
          phase: .downloading,
          bytesReceived: total,
          bytesExpected: total,
          etaSeconds: 0
        ))
        try? await Task.sleep(nanoseconds: 75_000_000)
        continuation.yield(DownloadProgress(
          handleID: handle.id,
          phase: .verifying,
          bytesReceived: total,
          bytesExpected: total,
          etaSeconds: 0
        ))
        try? await Task.sleep(nanoseconds: 75_000_000)
        continuation.yield(DownloadProgress(
          handleID: handle.id,
          phase: .completed,
          bytesReceived: total,
          bytesExpected: total,
          etaSeconds: 0,
          verification: .notAdvertised
        ))
        continuation.finish()
      }
    }
  }

  private func destinationURL(repo: String, file: String) throws -> URL {
    let root = try PieDirs.models()
    let destination = root.appendingPathComponent(repo).appendingPathComponent(file)
    let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath().path
    let resolvedDestination = destination
      .standardizedFileURL
      .deletingLastPathComponent()
      .resolvingSymlinksInPath()
      .path
    guard resolvedDestination == resolvedRoot || resolvedDestination.hasPrefix(resolvedRoot + "/") else {
      throw DownloadError.invalidArguments(message: "fixture downloader destination escaped models root")
    }
    return destination
  }

  private func writeProbeIfRequested(
    repo: String,
    file: String,
    destination: URL,
    byteCount: Int
  ) throws {
    guard let probePath = environment["PIE_TEST_MODEL_DOWNLOAD_PROBE_FILE"],
          !probePath.isEmpty else { return }
    let probeURL = URL(fileURLWithPath: probePath)
    try FileManager.default.createDirectory(
      at: probeURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let payload: [String: Any] = [
      "schema_version": 1,
      "kind": "_fixture_model_download",
      "model_id": environment["PIE_TEST_MODEL_DOWNLOAD_EXPECTED_MODEL_ID"] ?? "",
      "repo": repo,
      "file": file,
      "destination": destination.path,
      "bytes": byteCount,
    ]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: probeURL, options: .atomic)
  }
}
