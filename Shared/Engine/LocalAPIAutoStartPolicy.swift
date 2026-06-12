import Foundation

/// Pure launch-time decision for the Local API startup preference.
///
/// The Local API is the engine's HTTP listener, so "start Local API on launch"
/// means "start the shared engine on the active profile after the initial
/// helper status settles." This keeps the default safe (no surprise model
/// load), while honoring an explicit user opt-in.
public enum LocalAPIAutoStartPolicy {
  public static func shouldStartOnLaunch(
    enabled: Bool,
    status: EngineStatus,
    activeProfileID: String?
  ) -> Bool {
    guard enabled else { return false }
    guard let activeProfileID,
          !activeProfileID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return false
    }
    if case .stopped = status { return true }
    return false
  }
}
