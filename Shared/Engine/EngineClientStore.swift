import Combine

/// SwiftUI environment wrapper for the app-wide `EngineClient`.
///
/// `EngineClient` itself is a protocol existential, so it cannot be
/// injected with `environmentObject` directly. This tiny reference
/// type lets unrelated view subsystems share the same concrete
/// `HTTPEngineClient` instance that `RatioThinkApp` wires to
/// `EngineStatusStore.requireBaseURL()`.
@MainActor
public final class EngineClientStore: ObservableObject {
  public let client: EngineClient

  /// True when `client` is hardwired to a fixed base URL (the DEBUG/test-mode
  /// `PIE_TEST_ENGINE_BASE_URL` seam) and never resolves through the Helper's
  /// `EngineStatusStore.requireBaseURL()`. Captured at the wiring site
  /// (`RatioThinkApp`), where the seam decision is made, so consumers like the
  /// helper-recovery overlay gate can key on whether the Helper is actually
  /// load-bearing for chat. Constant `false` in Release (the seam is refused
  /// by `HelperConfig.testEngineBaseURLOverride`).
  public let chatBypassesHelper: Bool

  public init(client: EngineClient, chatBypassesHelper: Bool = false) {
    self.client = client
    self.chatBypassesHelper = chatBypassesHelper
  }
}
