import SwiftUI

/// First-launch wizard.  reduced this to the two things a
/// fresh install genuinely requires before the main shell is useful:
/// a short orientation on the menu-bar helper, and registering that
/// helper as a login item. Model choice and download moved to
/// *Settings → Models* — the wizard no longer forces a multi-GB
/// download in front of the first chat.
struct FirstLaunchWizardView: View {
  private enum Step: Int {
    case helperPurpose
    case loginItem
  }

  @EnvironmentObject private var appPreferences: AppPreferences

  private let registrar: LoginItemRegistering

  @State private var step: Step = .helperPurpose
  @State private var loginStatus: LoginItemRegistrationStatus
  @State private var registrationError: String?

  init(registrar: LoginItemRegistering = LoginItemRegistrarFactory.make()) {
    self.registrar = registrar
    _loginStatus = State(initialValue: registrar.status)
  }

  var body: some View {
    VStack(spacing: 0) {
      Spacer(minLength: 24)
      VStack(alignment: .leading, spacing: 22) {
        progressHeader
        switch step {
        case .helperPurpose:
          helperPurposeStep
        case .loginItem:
          loginItemStep
        }
      }
      .frame(maxWidth: 760)
      .padding(32)
      .background(
        RoundedRectangle(cornerRadius: 18)
          .fill(Color(nsColor: .controlBackgroundColor))
          .shadow(color: .black.opacity(0.12), radius: 24, y: 10)
      )
      Spacer(minLength: 24)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private var progressHeader: some View {
    HStack(spacing: 8) {
      ForEach([Step.helperPurpose, .loginItem], id: \.rawValue) { item in
        Capsule()
          .fill(item.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.25))
          .frame(width: 46, height: 5)
      }
      Spacer()
      Text("Step \(step.rawValue + 1) of 2")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var helperPurposeStep: some View {
    VStack(alignment: .leading, spacing: 16) {
      Label("Welcome to Rational", systemImage: "sparkles")
        .font(.largeTitle.bold())
      Text("Run AI models locally on your Mac — private and offline.")
        .font(.title3)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      bullet("Chat with your models in Rational, or serve them to other apps over an OpenAI-compatible endpoint.")
      bullet("Download and manage models anytime in Settings → Models.")

      HStack {
        Spacer()
        Button("Continue") { step = .loginItem }
          .buttonStyle(.borderedProminent)
      }
    }
  }

  private var loginItemStep: some View {
    VStack(alignment: .leading, spacing: 16) {
      Label("Keep Rational ready in the menu bar", systemImage: "menubar.rectangle")
        .font(.largeTitle.bold())
      Text("Rational Helper must run in the menu bar for Rational to work. Register it as a login item so macOS can launch the helper.")
        .font(.title3)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: 10) {
        loginStatusIndicator
        Text(loginStatus.userVisibleText)
          .accessibilityIdentifier("FirstLaunchLoginStatus")
      }

      if loginStatus == .requiresApproval {
        Text("Open System Settings → General → Login Items and approve Rational Helper, then return here.")
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      if let registrationError {
        Text(registrationError)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack {
        Button("Back") { step = .helperPurpose }
        Spacer()
        Button("Register Rational Helper") { registerLoginItem() }
          .buttonStyle(.bordered)
          .disabled(loginStatus == .enabled)
        if loginStatus == .requiresApproval {
          Button("Refresh status") { loginStatus = registrar.status }
            .buttonStyle(.bordered)
        }
        Button("Open Rational") {
          appPreferences.completeFirstLaunch()
        }
        .buttonStyle(.borderedProminent)
        .disabled(!loginStatus.canContinue)
      }
    }
  }

  private func bullet(_ text: String) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: "checkmark.circle")
        .foregroundStyle(.green)
      Text(text)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var loginStatusIndicator: some View {
    Image(systemName: loginStatus.canContinue ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
      .symbolRenderingMode(.hierarchical)
      .foregroundStyle(loginStatus.canContinue ? .green : .red)
      .accessibilityIdentifier("FirstLaunchLoginStatusIndicator")
      .accessibilityLabel(loginStatus.canContinue ? "Helper registered" : "Helper registration required")
  }

  private func registerLoginItem() {
    do {
      loginStatus = try registrar.register()
      registrationError = nil
    } catch {
      registrationError = "Registration failed: \(error)"
      loginStatus = registrar.status
    }
  }
}
