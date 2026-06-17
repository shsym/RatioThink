import SwiftUI
import XCTest
@testable import RatioThink

/// #677 regression guard for the two-column sidebar toggle. `RootView` keeps the
/// system-injected sidebar-toggle control, which writes `.doubleColumn` (not
/// `.all`) back through `columnVisibility` when it shows the sidebar in a
/// two-column split view. The toggle and its menu label therefore must key on
/// the single HIDDEN state (`.detailOnly`) — keying on one visible value
/// (`== .all`) misses `.doubleColumn`/`.automatic`, making the next Hide a
/// no-op and the label mis-read while the sidebar is shown.
@MainActor
final class WindowStateSidebarToggleTests: XCTestCase {
  func test_toggleSidebar_from_any_visible_state_hides() {
    for visible in [NavigationSplitViewVisibility.all, .doubleColumn, .automatic] {
      let state = WindowState()
      state.columnVisibility = visible
      state.toggleSidebar()
      XCTAssertEqual(state.columnVisibility, .detailOnly,
                     "toggleSidebar from \(visible) must hide the sidebar (.detailOnly)")
    }
  }

  func test_toggleSidebar_from_hidden_shows() {
    let state = WindowState()
    state.columnVisibility = .detailOnly
    state.toggleSidebar()
    XCTAssertEqual(state.columnVisibility, .all,
                   "toggleSidebar from .detailOnly must show the sidebar")
  }

  /// The native control writing `.doubleColumn` on show must not strand the
  /// toggle: the very next Hide has to collapse to `.detailOnly`, not no-op.
  func test_show_via_native_control_then_hide_does_not_no_op() {
    let state = WindowState()
    state.columnVisibility = .detailOnly   // app hid it
    state.columnVisibility = .doubleColumn // native control re-showed it (2-col "show")
    state.toggleSidebar()                  // app "Hide Sidebar"
    XCTAssertEqual(state.columnVisibility, .detailOnly,
                   "Hide after a native-control show must actually hide, not no-op")
  }

  /// The menu command at `RatioThinkApp.swift` renders `WindowState`'s own
  /// `sidebarToggleTitle`, so assert on that production property directly. The
  /// expected labels are a hardcoded (visibility, label) table written out
  /// independently — NOT recomputed from the production `== .detailOnly`
  /// predicate — so a future predicate inversion or literal typo must be
  /// reflected deliberately in this table rather than auto-satisfied by shared
  /// logic. The label reads "Show Sidebar" only when hidden (`.detailOnly`) and
  /// "Hide Sidebar" for every visible state — `.all`, `.doubleColumn`,
  /// `.automatic` alike — so it never mis-reads after the native control leaves
  /// the binding at `.doubleColumn`. Reverting the production predicate to
  /// `== .all` flips the label for `.all` and `.detailOnly`, failing this
  /// test (#685).
  func test_sidebarToggleTitle_matches_actual_visibility() {
    let expectations: [(NavigationSplitViewVisibility, String)] = [
      (.detailOnly, "Show Sidebar"),
      (.all, "Hide Sidebar"),
      (.doubleColumn, "Hide Sidebar"),
      (.automatic, "Hide Sidebar"),
    ]
    let state = WindowState()
    for (visibility, expectedLabel) in expectations {
      state.columnVisibility = visibility
      XCTAssertEqual(state.sidebarToggleTitle, expectedLabel,
                     "sidebarToggleTitle must match actual visibility for \(visibility)")
    }
  }
}
