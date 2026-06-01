import Darwin
import Foundation
import RatioThinkCore

@main
enum EngineHarness {
  static func main() async throws {
    let env = ProcessInfo.processInfo.environment
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let model = env["PIE_TEST_CHAT_MODEL"].flatMap { $0.isEmpty ? nil : $0 } ?? "Qwen/Qwen3-0.6B"
    let pieBinary = URL(fileURLWithPath: env["PIE_BIN"] ?? cwd.appendingPathComponent("Vendor/pie/target/aarch64-apple-darwin/release/pie").path)
    let urlFile = URL(fileURLWithPath: env["PIE_TEST_ENGINE_URL_FILE"] ?? "/tmp/pie-chat-engine.url")
    let pieHome: URL
    if let configuredHome = env["PIE_TEST_ENGINE_HOME"], !configuredHome.isEmpty {
      pieHome = URL(fileURLWithPath: configuredHome, isDirectory: true)
    } else {
      pieHome = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("p258e-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    }
    let wasm = cwd.appendingPathComponent("Inferlets/chat-apc/prebuilt/chat-apc.wasm", isDirectory: false)
    let manifest = cwd.appendingPathComponent("Inferlets/chat-apc/Pie.toml", isDirectory: false)

    try FileManager.default.createDirectory(at: pieHome, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: urlFile.deletingLastPathComponent(), withIntermediateDirectories: true)

    //  full-chain mode: serve a portable app-staged GGUF (the path
    // the Settings downloader wrote into a shared PIE_HOME/models)
    // instead of resolving an HF-cached model. Slug is `<repo>/<file>`.
    // `.portable` registers the model under the SLUG as its served id
    // (`PieControlLauncher.renderPortableModel` writes `name = modelSlug`),
    // matching production's `.portableResolved(servedModelID: profile.model)`
    // — so both the `/v1/models` id and the load target are the slug, NOT
    // "default" (loading "default" fails `model_not_found`). The App then
    // renders the menu label as `ModelDisplayName.leaf(slug)`. Both env vars
    // unset keeps the original `.metal` behavior (this harness is shared).
    let modelConfig: PieControlLauncher.ModelConfig
    let loadTarget: String
    if let slug = env["PIE_TEST_HARNESS_MODEL_SLUG"], !slug.isEmpty,
       let rootPath = env["PIE_TEST_HARNESS_MODELS_ROOT"], !rootPath.isEmpty {
      modelConfig = .portable(
        modelSlug: slug,
        modelsRoot: URL(fileURLWithPath: rootPath, isDirectory: true))
      loadTarget = slug
      print("chat-engine-harness: portable app-staged model slug=\(slug) modelsRoot=\(rootPath)")
    } else {
      modelConfig = .metal(modelID: model)
      loadTarget = model
    }

    let spec = try PieControlLauncher.LaunchSpec(
      pieBinary: pieBinary,
      wasmURL: wasm,
      manifestURL: manifest,
      subprocessEnvironment: SpawnEnvSanitizer.sanitize(env),
      pieHome: pieHome,
      shmemName: "/pie258_\(ProcessInfo.processInfo.processIdentifier)_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6))",
      handshakeTimeout: 30,
      profileID: "chat",
      modelConfig: modelConfig
    )

    print("chat-engine-harness: launching \(pieBinary.path) with model \(loadTarget)")
    let (port, session) = try await PieControlLauncher.launch(spec: spec)
    let baseURL = URL(string: "http://127.0.0.1:\(port)")!
    print("chat-engine-harness: engine running at \(baseURL.absoluteString)")

    do {
      try await loadModel(loadTarget, baseURL: baseURL)
      try baseURL.absoluteString.write(to: urlFile, atomically: true, encoding: .utf8)
      print("chat-engine-harness: wrote \(urlFile.path)")
      await waitForSIGTERM()
      print("chat-engine-harness: shutting down")
      await session.shutdown()
    } catch {
      await session.shutdown()
      throw error
    }
  }

  private static func loadModel(_ model: String, baseURL: URL) async throws {
    let client = HTTPEngineClient(baseURL: baseURL, unaryTimeout: 15)
    try await withTimeout(seconds: 120, label: "loadModel(\(model))") {
      var ready = false
      for try await event in client.loadModel(model) {
        switch event {
        case .ready:
          ready = true
        case .loading:
          continue
        }
      }
      if !ready {
        throw HarnessError.modelLoadEndedWithoutReady(model)
      }
    }
    print("chat-engine-harness: loaded \(model)")
  }

  private static func waitForSIGTERM() async {
    signal(SIGTERM, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    await withCheckedContinuation { continuation in
      source.setEventHandler {
        source.cancel()
        continuation.resume()
      }
      source.resume()
    }
  }

  private static func withTimeout(
    seconds: TimeInterval,
    label: String,
    body: @Sendable @escaping () async throws -> Void
  ) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { try await body() }
      group.addTask {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        throw HarnessError.timeout(label)
      }
      defer { group.cancelAll() }
      _ = try await group.next()
    }
  }
}

private enum HarnessError: Error, CustomStringConvertible {
  case timeout(String)
  case modelLoadEndedWithoutReady(String)

  var description: String {
    switch self {
    case .timeout(let label):
      return "\(label) timed out"
    case .modelLoadEndedWithoutReady(let model):
      return "loadModel(\(model)) ended without .ready"
    }
  }
}
