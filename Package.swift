// swift-tools-version:5.10
import PackageDescription

// SPM package exposes:
//   - RatioThinkCore   — pure-Swift domain library (no AppKit)
//   - Scenarios — scenario definitions shared by CLI + GUI runners
//   - pie-verify — minimal CLI assertion harness (no XCTest)
//   - pie-resolve-probe — tiny binary tests spawn under a constructed
//     env to exercise the prod env-fallback path (RatioThinkCoreTests cannot
//     mutate process env safely, so the env path is covered by
//     subprocess-spawn). Imports RatioThinkCore so any drift in
//     `HelperConfig.xpcServiceName` or `PieDirs.applicationSupport`
//     surfaces in the test bundle.
//
// Test targets:
//   - RatioThinkCoreTests       — unit tests for RatioThinkCore (XCTest)
//   - CLIScenarioTests   — headless scenarios (S1, S2, S3) via CLIRunner;
//                          owns IsolatedTestCase shared by
//                          all scenario tests that touch real RatioThink state.
//
// GUI scenarios (S4, S5) live in the Xcode-only RatioThinkGUITests target defined
// in project.yml; they need an active console session.

let package = Package(
  name: "RatioThinkCore",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "RatioThinkCore", targets: ["RatioThinkCore"]),
    .library(name: "Scenarios", targets: ["Scenarios"]),
    .executable(name: "pie-verify", targets: ["pie-verify"]),
    .executable(name: "pie-resolve-probe", targets: ["pie-resolve-probe"]),
    .executable(name: "chat-engine-harness", targets: ["chat-engine-harness"]),
    .executable(name: "api-probe", targets: ["api-probe"]),
    .executable(name: "bon-commit-body", targets: ["bon-commit-body"]),
  ],
  dependencies: [
    .package(url: "https://github.com/LebJe/TOMLKit", from: "0.6.0"),
  ],
  targets: [
    .target(
      name: "RatioThinkCore",
      dependencies: [.product(name: "TOMLKit", package: "TOMLKit")],
      path: "Shared"
    ),
    .target(
      name: "Scenarios",
      dependencies: ["RatioThinkCore"],
      path: "Tests/Scenarios"
    ),
    .executableTarget(
      name: "pie-verify",
      dependencies: [
        "RatioThinkCore",
        .product(name: "TOMLKit", package: "TOMLKit"),
      ],
      path: "Sources/pie-verify"
    ),
    .executableTarget(
      name: "pie-resolve-probe",
      dependencies: ["RatioThinkCore"],
      path: "Sources/pie-resolve-probe"
    ),
    .executableTarget(
      name: "chat-engine-harness",
      dependencies: ["RatioThinkCore"],
      path: "Sources/chat-engine-harness"
    ),
    .executableTarget(
      name: "api-probe",
      dependencies: ["RatioThinkCore"],
      path: "Sources/api-probe"
    ),
    // Emits the real encoded Best-of-N commit body so a gate can POST Swift's
    // own bytes rather than a hand-written approximation of them.
    .executableTarget(
      name: "bon-commit-body",
      dependencies: ["RatioThinkCore"],
      path: "Sources/bon-commit-body"
    ),
    .testTarget(
      name: "RatioThinkCoreTests",
      dependencies: ["RatioThinkCore"],
      path: "Tests/RatioThinkCoreTests"
    ),
    .testTarget(
      name: "CLIScenarioTests",
      dependencies: ["RatioThinkCore", "Scenarios"],
      path: "Tests/CLIScenarioTests"
    ),
  ]
)
