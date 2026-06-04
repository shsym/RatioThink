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
      // ToT app-path E2E mode (#413 stall repro / regression): when
      // PIE_TEST_TOT_QUESTION is set, drive a real tree-of-thought search
      // through the SAME Swift path the app uses — HTTPEngineClient
      // .dispatchInferlet -> toTEventStream -> ToTTree — and assert it
      // reaches a `tree_complete` terminal. This is the coverage the wire
      // probe (Python, bypasses Swift) and the TCC-blocked GUI tests both
      // missed. Exits non-zero if the stream stalls / ends without a
      // terminal.
      if let question = env["PIE_TEST_TOT_QUESTION"], !question.isEmpty {
        let ok = try await runTreeOfThought(question: question, baseURL: baseURL, env: env)
        await session.shutdown()
        exit(ok ? 0 : 1)
      }
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

  /// Drive a real ToT search through the App's Swift path and report
  /// per-event timing + the terminal. Returns true iff a `tree_complete`
  /// arrived (the live tree would reach a final answer in the UI).
  private static func runTreeOfThought(
    question: String, baseURL: URL, env: [String: String]
  ) async throws -> Bool {
    func intEnv(_ key: String, _ fallback: Int) -> Int { env[key].flatMap { Int($0) } ?? fallback }
    let breadth = intEnv("PIE_TEST_TOT_BREADTH", 3)
    let depth = intEnv("PIE_TEST_TOT_DEPTH", 2)
    let beam = intEnv("PIE_TEST_TOT_BEAM", 2)
    let maxTok = intEnv("PIE_TEST_TOT_MAXTOK", 256)
    let input: [String: Any] = [
      "messages": [["role": "user", "content": question]],
      "breadth": breadth, "depth": depth, "beam_width": beam,
      "max_tokens_per_node": maxTok, "temperature": 0.7, "top_p": 0.9,
    ]
    let inputData = try JSONSerialization.data(withJSONObject: input)
    let req = InferletRequest(inferlet: "tree-of-thought", input: inputData, messages: nil, stream: true)
    let client = HTTPEngineClient(baseURL: baseURL)

    print("chat-engine-harness: ToT drive b\(breadth)/d\(depth)/beam\(beam)/max\(maxTok) q=\(question.debugDescription)")
    var tree = ToTTree()
    let t0 = Date()
    var sawTerminal = false
    for try await event in toTEventStream(from: client.dispatchInferlet(req)) {
      tree.apply(event)
      let dt = Date().timeIntervalSince(t0)
      switch event {
      case let .treeStart(id, model, b, d, w):
        print(String(format: "  +%6.1fs tree_start id=\(id) model=\(model) b\(b)/d\(d)/beam\(w)", dt))
      case let .nodeComplete(node):
        let head = node.content.prefix(40).replacingOccurrences(of: "\n", with: "\\n")
        print(String(format: "  +%6.1fs node_complete depth=\(node.depth) status=\(node.status) score=\(node.score.map(String.init) ?? "nil") len=\(node.content.count) head=\(head.debugDescription)", dt))
      case let .levelPruned(level, kept):
        print(String(format: "  +%6.1fs level_pruned level=\(level) kept=\(kept)", dt))
      case let .treeComplete(sel, ans):
        sawTerminal = true
        print(String(format: "  +%6.1fs tree_complete selected=\(sel ?? "nil") answer_len=\(ans?.count ?? 0)", dt))
      }
    }
    let total = Date().timeIntervalSince(t0)
    print(String(format: "chat-engine-harness: ToT stream ended after %.1fs; status=\(tree.status); nodes=\(tree.nodes.count); terminal=\(sawTerminal)", total))
    if case .complete = tree.status, sawTerminal, tree.selectedNode != nil {
      print("chat-engine-harness: ToT PASS — reached tree_complete with a selected answer")
      return true
    }
    print("chat-engine-harness: ToT FAIL — no tree_complete / no selected answer (status=\(tree.status))")
    return false
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
