import XCTest
@testable import RatioThinkCore

/// Unit tests for the RAM-aware `ModelMemoryGuardrail.Policy` and
/// the rejection-message contract. Size validation through the resolver
/// is covered in `LaunchSpecResolverTests`; here we pin the policy math,
/// the fail-safe fallback, and the "(N% of <RAM> RAM)" message context.
final class ModelMemoryGuardrailTests: XCTestCase {
  private var tempDir: URL!
  private let gib: Int64 = 1024 * 1024 * 1024

  override func setUpWithError() throws {
    tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("mmg-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: tempDir)
  }

  // MARK: - recommended() — reserve term

  func test_recommended_subtracts_reserve_before_applying_fraction() {
    let physical: Int64 = 64 * gib
    let reserve: Int64 = 6 * gib
    let policy = ModelMemoryGuardrail.Policy.recommended(physicalMemoryBytes: physical,
                                                         fraction: 0.65,
                                                         reserveBytes: reserve)
    XCTAssertEqual(policy.maxResolvedModelBytes,
                   Int64((Double(physical - reserve) * 0.65).rounded()),
                   "ceiling must be (physical - reserve) * fraction, not flat physical * fraction")
    XCTAssertEqual(policy.physicalMemoryBytes, physical)
    XCTAssertEqual(policy.ramFraction, 0.65)
    XCTAssertEqual(policy.reserveBytes, reserve)
  }

  func test_default_fraction_and_reserve() {
    XCTAssertEqual(ModelMemoryGuardrail.Policy.defaultRAMFraction, 0.65)
    XCTAssertEqual(ModelMemoryGuardrail.Policy.defaultReserveBytes, 6 * gib)
    let policy = ModelMemoryGuardrail.Policy.recommended(physicalMemoryBytes: 64 * gib)
    XCTAssertEqual(policy.ramFraction, 0.65)
    XCTAssertEqual(policy.reserveBytes, 6 * gib, "default reserve applied when not injected")
  }

  /// The safety bug the reserve fixes: an 8 GB Mac must NOT greenlight a
  /// ~4.7 GiB model. (8 - 6) * 0.65 = 1.3 GiB ceiling.
  func test_recommended_8gb_blocks_a_4gib_model() {
    let limit = ModelMemoryGuardrail.Policy
      .recommended(physicalMemoryBytes: 8 * gib).maxResolvedModelBytes
    XCTAssertEqual(limit, Int64((Double(2 * gib) * 0.65).rounded()))  // (8-6)*0.65
    XCTAssertLessThan(limit, 4 * gib, "an 8 GB Mac must block a 4 GiB model (no headroom otherwise)")
  }

  func test_recommended_16gb_ceiling() {
    let limit = ModelMemoryGuardrail.Policy
      .recommended(physicalMemoryBytes: 16 * gib).maxResolvedModelBytes
    XCTAssertEqual(limit, Int64((Double(10 * gib) * 0.65).rounded()))  // (16-6)*0.65 = 6.5 GiB
  }

  /// On a 64 GB host: (64 - 6) * 0.65 = 37.7 GiB — clears 8B–30B models
  /// (15–18 GiB) yet still blocks the 56.8 GiB coder.
  func test_recommended_64gb_allows_18gib_blocks_56gib() {
    let limit = ModelMemoryGuardrail.Policy
      .recommended(physicalMemoryBytes: 64 * gib).maxResolvedModelBytes
    XCTAssertEqual(limit, Int64((Double(58 * gib) * 0.65).rounded()))
    XCTAssertGreaterThan(limit, 18 * gib, "Qwen3.5-9B (~18 GiB) must be allowed on 64 GB")
    XCTAssertLessThan(limit, 56 * gib, "Qwen3-Coder-30B (~56.8 GiB) must stay blocked on 64 GB")
  }

  func test_recommended_clamps_usable_to_zero_when_reserve_exceeds_ram() {
    // A 4 GB Mac with a 6 GiB reserve: usable < 0 → ceiling 0 → blocks all.
    let limit = ModelMemoryGuardrail.Policy
      .recommended(physicalMemoryBytes: 4 * gib).maxResolvedModelBytes
    XCTAssertEqual(limit, 0)
  }

  func test_recommended_falls_back_to_fixed_ceiling_when_ram_unknown() {
    let policy = ModelMemoryGuardrail.Policy.recommended(physicalMemoryBytes: nil)
    XCTAssertEqual(policy.maxResolvedModelBytes,
                   ModelMemoryGuardrail.Policy.unknownRAMFallbackBytes)
    XCTAssertNil(policy.physicalMemoryBytes, "fallback carries no RAM context for the message")
    XCTAssertNil(policy.ramFraction)
    XCTAssertNil(policy.reserveBytes)
  }

  func test_recommended_falls_back_when_ram_non_positive() {
    let policy = ModelMemoryGuardrail.Policy.recommended(physicalMemoryBytes: 0)
    XCTAssertEqual(policy.maxResolvedModelBytes,
                   ModelMemoryGuardrail.Policy.unknownRAMFallbackBytes)
  }

  // MARK: - validate() over a real (sparse) file

  func test_validate_8gb_host_blocks_4gib_model_with_terms_in_message() throws {
    let file = tempDir.appendingPathComponent("four.gguf")
    try makeSparseFile(at: file, sizeBytes: 4 * gib)
    let policy = ModelMemoryGuardrail.Policy.recommended(physicalMemoryBytes: 8 * gib)
    let result = ModelMemoryGuardrail.validate(resolvedModelURL: file, modelID: "m", policy: policy)
    guard case .failure(let err) = result else {
      return XCTFail("an 8 GB host must block a 4 GiB model; got \(result)")
    }
    XCTAssertEqual(err.code, .memoryRisk)
    XCTAssertTrue(err.message.contains("exceeds limit"), err.message)
    XCTAssertTrue(err.message.contains("reserve"), "message must show the reserve term; got \(err.message)")
    XCTAssertTrue(err.message.contains("×"), "message must show the fraction × (RAM − reserve) form; got \(err.message)")
  }

  // MARK: - validate()

  func test_validate_succeeds_under_limit() throws {
    let file = tempDir.appendingPathComponent("ok.gguf")
    try Data(count: 100).write(to: file)
    let policy = ModelMemoryGuardrail.Policy(maxResolvedModelBytes: 1024)
    let result = ModelMemoryGuardrail.validate(resolvedModelURL: file, modelID: "m", policy: policy)
    guard case .success = result else {
      return XCTFail("under-limit model must pass; got \(result)")
    }
  }

  func test_validate_rejects_over_limit_with_derivation_terms_in_message() throws {
    let file = tempDir.appendingPathComponent("big.gguf")
    try Data(count: 4096).write(to: file)
    // Toy RAM context so the message must render the full derivation:
    // "0.65 × (<RAM> RAM − <reserve> reserve)".
    let policy = ModelMemoryGuardrail.Policy(maxResolvedModelBytes: 100,
                                             physicalMemoryBytes: 200,
                                             ramFraction: 0.65,
                                             reserveBytes: 46)
    let result = ModelMemoryGuardrail.validate(resolvedModelURL: file, modelID: "m", policy: policy)
    guard case .failure(let err) = result else {
      return XCTFail("over-limit model must fail; got \(result)")
    }
    XCTAssertEqual(err.code, .memoryRisk)
    XCTAssertTrue(err.message.contains("exceeds limit"), err.message)
    XCTAssertTrue(err.message.contains("0.65 ×"), err.message)
    XCTAssertTrue(err.message.contains("reserve"), err.message)
  }

  func test_validate_message_omits_terms_when_policy_has_no_context() throws {
    let file = tempDir.appendingPathComponent("big2.gguf")
    try Data(count: 4096).write(to: file)
    let policy = ModelMemoryGuardrail.Policy(maxResolvedModelBytes: 100)
    let result = ModelMemoryGuardrail.validate(resolvedModelURL: file, modelID: "m", policy: policy)
    guard case .failure(let err) = result else {
      return XCTFail("over-limit model must fail; got \(result)")
    }
    XCTAssertFalse(err.message.contains("reserve"),
                   "an injected fixed ceiling carries no derivation context; got \(err.message)")
  }

  func test_validate_zero_ceiling_reads_as_host_too_small() throws {
    let file = tempDir.appendingPathComponent("tiny.gguf")
    try Data(count: 100).write(to: file)
    // 4 GB host: (4 − 6) clamps to 0 → ceiling 0 → no model fits.
    let policy = ModelMemoryGuardrail.Policy.recommended(physicalMemoryBytes: 4 * gib)
    XCTAssertEqual(policy.maxResolvedModelBytes, 0)
    let result = ModelMemoryGuardrail.validate(resolvedModelURL: file, modelID: "m", policy: policy)
    guard case .failure(let err) = result else {
      return XCTFail("a 0-ceiling host must reject any model; got \(result)")
    }
    XCTAssertEqual(err.code, .memoryRisk)
    XCTAssertTrue(err.message.contains("below the minimum"), err.message)
    XCTAssertTrue(err.message.contains("reserving"), err.message)
    XCTAssertFalse(err.message.contains("exceeds limit"),
                   "0-ceiling must read as too-small-host, not model-too-big; got \(err.message)")
  }

  // MARK: - fixtures

  private func makeSparseFile(at url: URL, sizeBytes: Int64) throws {
    _ = FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: UInt64(sizeBytes))
    try handle.close()
  }
}
