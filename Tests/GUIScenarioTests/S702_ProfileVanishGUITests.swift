import XCTest

/// #702/#856 regression guard: a stale, OLD-VERSION retired built-in profile on
/// disk must not surface in the chat toolbar profile picker; retirement moves it
/// aside while the remaining shipped built-ins still render.
///
/// The bug (pre-#702): an install predating the current `Profile` schema left a
/// `repeat-boost.toml` carrying only `id` + `model` (no `name`, no `inferlet`).
/// `Profile.parse` REQUIRES `id`/`name`/`inferlet`, so the file failed to parse;
/// `ProfileStore` kept it as a load result whose `profile == nil`, the picker
/// `compactMap { $0.profile?.id }`'d it away (no badge, no trace), and the
/// existence-gated seeders never healed it (they early-returned the moment the
/// file existed, broken or not).
///
/// The #856 retirement behavior: on launch `migrateBuiltinProvenance` recognizes
/// the stale unparseable `repeat-boost.toml` as a retired built-in, moves it
/// aside to `repeat-boost.toml.bak`, and does NOT serve a base `repeat-boost`
/// entry. A sibling valid built-in (`chat`) present is the control proving the
/// picker renders profiles at all.
///
/// Engine-free, mirroring S286/S669: the picker renders from the on-disk
/// profiles directory before any engine contact, so no model fixture is needed.
/// The runner SEEDS the fixture (it is non-sandboxed for file writes into its
/// own temp container, which the non-sandboxed app then reads via `PIE_HOME`),
/// the same seam S279 uses.
final class S702_ProfileVanishGUITests: XCTestCase {
  override func setUp() async throws {
    try guardSeatedGUI()
  }

  /// A valid sibling built-in — the control that proves the picker renders
  /// profiles at all, so the broken one's absence is the parse-drop and not an
  /// empty/broken menu. Byte-faithful to `ProfileStore.defaultChatTOML`.
  private static let validChatTOML = """
  id = "chat"
  name = "Chat"
  icon = "bubble.left.and.bubble.right"
  model = "Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf"
  inferlet = "chat-apc"
  system_prompt = "You are a helpful assistant."

  [sampling]
  temperature = 0.7
  top_p = 0.9
  max_tokens = 2048

  """

  /// The exact shape the operator's pre-upgrade install left behind: `id` +
  /// `model` only. Missing the now-required `name` and `inferlet`, so
  /// `Profile.parse` throws `.missingField` and the entry's `profile` is nil.
  private static let brokenRepeatBoostTOML = """
  id = "repeat-boost"
  model = "bartowski/Meta-Llama-3.1-8B-Instruct-GGUF/Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf"

  """

  @MainActor
  func test_stale_builtin_profile_vanishes_from_toolbar_picker() async throws {
    // Runner-side temp PIE_HOME (its sandbox container, an absolute path the
    // non-sandboxed app can read) — same seam as S279.
    let pieHome = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("pie-s702-profile-vanish-\(UUID().uuidString)", isDirectory: true)
    let profilesDir = pieHome.appendingPathComponent("profiles", isDirectory: true)
    try FileManager.default.createDirectory(at: profilesDir, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: pieHome) }

    // Seed BEFORE launch the exact fixture the operator hit: a valid built-in
    // next to the stale, unparseable retired one. Post-#856, launch moves the
    // broken `repeat-boost.toml` aside to `repeat-boost.toml.bak` and hides it.
    try Self.validChatTOML.write(
      to: profilesDir.appendingPathComponent("chat.toml"), atomically: true, encoding: .utf8)
    try Self.brokenRepeatBoostTOML.write(
      to: profilesDir.appendingPathComponent("repeat-boost.toml"), atomically: true, encoding: .utf8)

    let app = XCUIApplication(bundleIdentifier: "com.ratiothink.app")
    app.launchArguments.append(contentsOf: [
      "-NSQuitAlwaysKeepsWindows", "NO",
      "-ApplePersistenceIgnoreState", "YES",
    ])
    app.launchEnvironment["PIE_HOME"] = pieHome.path
    configureCompletedFirstLaunch(app, suiteName: stablePreferenceSuiteName(pieHome.path))
    app.launch()
    defer { app.terminate() }

    XCTAssert(app.wait(for: .runningForeground, timeout: 10),
              "Rational.app did not reach runningForeground")
    app.activate()

    let newChat = app.buttons["chats.newButton"]
    XCTAssertTrue(newChat.waitForExistence(timeout: 10),
                  "New Chat button missing; app tree: \(app.debugDescription)")
    newChat.click()

    // Open the toolbar profile picker and wait for the VALID `chat` row, which
    // both proves the menu opened AND that the picker renders parseable
    // profiles. `openMenuAndWaitForItem` survives the not-key multilaunch race.
    let profileMenu = app.menuButtons["toolbar.profile"]
    XCTAssertTrue(profileMenu.waitForExistence(timeout: 10),
                  "profile switcher (toolbar.profile) missing; app tree: \(app.debugDescription)")
    let chatItem = app.menuItems["chat"]
    openMenuAndWaitForItem(profileMenu, item: chatItem, in: app)
    XCTAssertTrue(chatItem.exists,
                  "valid built-in 'chat' must render in the picker (the control that " +
                  "isolates the broken profile's absence to the parse-drop); app tree: \(app.debugDescription)")

    // Capture the healed state — picker open without the retired built-in — for
    // the operator. The menu is its own window, so grab the whole screen.
    Self.settle()
    let att = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    att.name = "profile-vanish"
    att.lifetime = .keepAlways
    add(att)

    // THE GUARD: the stale `repeat-boost` built-in is retired. It must be backed
    // up/hidden, while the remaining built-ins continue to render.
    let repeatBoostItem = app.menuItems["repeat-boost"]
    XCTAssertFalse(repeatBoostItem.exists,
                   "retired Repeat Boost must not render in the toolbar picker; app tree: \(app.debugDescription)")
    XCTAssertTrue(FileManager.default.fileExists(atPath: profilesDir.appendingPathComponent("repeat-boost.toml.bak").path),
                  "retired unparseable repeat-boost.toml should be moved aside to .bak")

    // Leave the menu closed so teardown doesn't trip over a stray popover.
    app.typeKey(.escape, modifierFlags: [])
  }

  /// Let the open menu paint before the screenshot.
  private static func settle() {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.6))
  }
}
