import Combine
import Foundation

/// App-scoped registry of per-chat send pipelines (#507).
///
/// `ChatSendController` used to live as a `@StateObject` inside the chat
/// detail view, whose `.onDisappear` cancelled the stream — so switching
/// chats killed the in-flight turn. The coordinator owns one controller
/// per `Chat.id` at app scope instead, which makes chat generation
/// lifetime independent of which detail view is mounted:
///
/// - a stream keeps writing deltas through SwiftData after the user
///   navigates away (returning shows the live transcript),
/// - different chats can stream concurrently, each with its own
///   controller (same-chat supersede semantics are unchanged — they live
///   inside `ChatSendController.send`),
/// - `inFlightChatIDs` exposes per-chat in-flight state to the sidebar
///   (row spinners) and the composer of the selected chat.
///
/// Cancellation is explicit only — never view teardown: the composer's
/// stop button (`cancel(chatID:)`), chat deletion (`forget(chatID:)`),
/// or the same-chat supersede inside the controller when a new turn is
/// sent to a chat whose previous turn is still streaming.
@available(macOS 14, *)
@MainActor
public final class ChatSendCoordinator: ObservableObject {
  /// Chat ids with a stream currently in flight. Drives the sidebar
  /// row indicators and the composer's disabled state.
  @Published public private(set) var inFlightChatIDs: Set<UUID> = []

  /// Edge-fired when the ANY-chat-in-flight aggregate flips. Wired to
  /// `HelperHealthController.setGenerating` at app scope — the #413
  /// generation gate (hold failed helper polls while a stream saturates
  /// the MainActor) now keys on "any stream in flight", since streams
  /// outlive the chat view that used to forward its own controller's
  /// `isInFlight`.
  public var onAnyInFlightChange: ((Bool) -> Void)?

  private var controllers: [UUID: ChatSendController] = [:]
  private var subscriptions: [UUID: AnyCancellable] = [:]

  public init() {}

  /// The chat's send controller, created lazily on first use. Stable per
  /// `chatID` for the coordinator's lifetime so generation/supersede
  /// state survives view rebuilds.
  public func controller(for chatID: UUID) -> ChatSendController {
    if let existing = controllers[chatID] { return existing }
    let controller = ChatSendController()
    controllers[chatID] = controller
    subscriptions[chatID] = controller.$isInFlight.sink { [weak self] inFlight in
      self?.setInFlight(chatID, inFlight)
    }
    return controller
  }

  public func isInFlight(_ chatID: UUID) -> Bool {
    inFlightChatIDs.contains(chatID)
  }

  /// Explicit user-intent cancel of one chat's in-flight turn — wired to
  /// the composer's stop button. A non-empty partial bubble is kept as a
  /// cancelled turn (`ChatSendController.cancel` semantics).
  public func cancel(chatID: UUID) {
    controllers[chatID]?.cancel()
  }

  /// Cancel and drop the chat's controller — for chat deletion, so the
  /// stream writer can never write onto a deleted `Message` row and the
  /// registry does not grow with dead entries.
  public func forget(chatID: UUID) {
    controllers[chatID]?.cancel()
    controllers[chatID] = nil
    subscriptions[chatID] = nil
    inFlightChatIDs.remove(chatID)
  }

  private func setInFlight(_ chatID: UUID, _ inFlight: Bool) {
    let wasAny = !inFlightChatIDs.isEmpty
    if inFlight {
      inFlightChatIDs.insert(chatID)
    } else {
      inFlightChatIDs.remove(chatID)
    }
    let isAny = !inFlightChatIDs.isEmpty
    if wasAny != isAny { onAnyInFlightChange?(isAny) }
  }
}
