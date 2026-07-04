import Foundation

enum LocalAPIAutoStartResult: Equatable {
  case skipped
  case started
  case failed(message: String)
}

enum LocalAPIAutoStartLauncher {
  @MainActor
  static func run(
    enabled: Bool,
    status: EngineStatus,
    activeProfileID: String?,
    startEngine: () async throws -> Void,
    errorMessage: (Error) -> String
  ) async -> LocalAPIAutoStartResult {
    guard LocalAPIAutoStartPolicy.shouldStartOnLaunch(
      enabled: enabled,
      status: status,
      activeProfileID: activeProfileID
    ), activeProfileID != nil else {
      return .skipped
    }

    do {
      try await startEngine()
      return .started
    } catch {
      return .failed(message: errorMessage(error))
    }
  }
}
