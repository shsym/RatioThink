import Foundation
import SwiftData

/// DEBUG-only deterministic transcript seeder for the rapid-chat-switching GUI
/// stress guard (#530).
///
/// When `PIE_TEST_SEED_TRANSCRIPTS=<N>` is set, inserts `N` persisted chats —
/// each with a long, mixed-role transcript (alternating user/assistant turns,
/// every assistant turn carrying a multi-paragraph answer plus a reasoning
/// section) — into an **otherwise empty** store. The transcripts are large on
/// purpose: the guard switches between them in a storm and watches the main
/// thread, and a long transcript is what makes the pre-#521 sort-and-@Model
/// layout pattern stall measurably while it lays out on each switch.
///
/// Determinism: content is generated from a fixed corpus with no randomness, no
/// wall-clock dependence beyond a single anchor `Date`, and stable per-chat
/// identifiers, so every run produces byte-identical transcripts. Each chat's
/// final assistant turn embeds a unique needle (`Self.needle(forChat:)`) the
/// test waits on to confirm the right transcript actually rendered after a
/// switch.
///
/// Safety: the seed runs only when the store currently holds zero chats, so it
/// can never clobber or duplicate real history; combined with the `#if DEBUG`
/// gate at the call site and the isolated `PIE_HOME` every GUI suite uses, a
/// shipped app never seeds.
@available(macOS 14, *)
enum TranscriptStressSeed {
  static let envVar = "PIE_TEST_SEED_TRANSCRIPTS"
  /// Messages per seeded chat (even → equal user/assistant split). Long on
  /// purpose: the #521 hang was reported on real, long conversations, so the
  /// guard switches between transcripts whose per-switch layout is non-trivial
  /// rather than a couple of rows.
  static let messagesPerChat = 200

  /// Stable title for chat index `i` (1-based), e.g. "Stress Chat 03". Seeded
  /// `userTitled` so #512 pruning/auto-titling never rewrites or removes it and
  /// the test can click rows by a fixed, unique title.
  static func title(forChat i: Int) -> String {
    String(format: "Stress Chat %02d", i)
  }

  /// Per-chat marker embedded in **every** turn of chat `i` so the switch guard
  /// finds it regardless of which rows the lazy transcript has realized (the
  /// scroll position after a switch is not fixed). Zero-padded so it is
  /// collision-free across chats (`chatTAG01` is not a substring of `chatTAG10`)
  /// and free of Markdown-significant characters so it survives rendering into
  /// the message body verbatim.
  static func needle(forChat i: Int) -> String {
    String(format: "chatTAG%02d", i)
  }

  /// Insert `N` seeded chats when requested and the store is empty. No-op when
  /// the env var is unset, non-positive, or the store already has chats.
  @MainActor
  static func seedIfRequested(into context: ModelContext) {
    guard let raw = ProcessInfo.processInfo.environment[envVar],
          let count = Int(raw), count > 0 else { return }

    let existing = (try? context.fetchCount(FetchDescriptor<Chat>())) ?? 0
    guard existing == 0 else {
      NSLog("TranscriptStressSeed: store already has \(existing) chats — skipping seed")
      return
    }

    // A fixed anchor so timestamps (and thus transcript order + sidebar order)
    // are fully deterministic across runs. Wall-clock is never read.
    let anchor = Date(timeIntervalSince1970: 1_700_000_000)
    for i in 1...count {
      // Newer chats first in the sidebar (sorted on createdAt/updatedAt desc):
      // chat 1 is the most recent so the test's first row is predictable.
      let createdAt = anchor.addingTimeInterval(TimeInterval(-(i - 1)) * 3600)
      let chat = Chat(
        title: title(forChat: i),
        profileID: "chat",
        createdAt: createdAt,
        userTitled: true
      )
      context.insert(chat)
      appendTranscript(to: chat, chatIndex: i, baseTimestamp: createdAt)
    }

    do {
      try context.save()
    } catch {
      NSLog("TranscriptStressSeed: save failed: \(error)")
    }
  }

  // MARK: - transcript generation

  @MainActor
  private static func appendTranscript(to chat: Chat, chatIndex: Int, baseTimestamp: Date) {
    let turns = messagesPerChat / 2
    for turn in 0..<turns {
      let userTs = baseTimestamp.addingTimeInterval(TimeInterval(turn * 2) + 1)
      let assistantTs = baseTimestamp.addingTimeInterval(TimeInterval(turn * 2) + 2)

      let user = Message(
        role: "user",
        content: userPrompt(chatIndex: chatIndex, turn: turn),
        ts: userTs
      )
      // Append through the relationship so SwiftData sets the inverse and
      // cascades the insert from the already-inserted parent chat (the
      // canonical path Chat.messages documents).
      chat.messages.append(user)

      let answer = assistantAnswer(chatIndex: chatIndex, turn: turn)
      let assistant = Message(
        role: "assistant",
        content: answer,
        reasoning: assistantReasoning(chatIndex: chatIndex, turn: turn),
        tokens: 128,
        ts: assistantTs
      )
      chat.messages.append(assistant)
    }
    // Mirror real history: the most recent turn drives sidebar recency.
    chat.updatedAt = baseTimestamp.addingTimeInterval(TimeInterval(turns * 2))
  }

  private static func userPrompt(chatIndex: Int, turn: Int) -> String {
    // Lead every user turn with the per-chat tag so the switch guard finds it
    // wherever the lazy transcript happens to be scrolled.
    "\(needle(forChat: chatIndex)) Chat \(chatIndex), question \(turn + 1): "
      + paragraph(seed: chatIndex * 31 + turn, sentences: 2)
  }

  private static func assistantAnswer(chatIndex: Int, turn: Int) -> String {
    // 3 paragraphs of generated prose — enough rendered text that laying the
    // bubble out is non-trivial, so a storm of switches over the buggy path
    // accumulates real main-thread time.
    (0..<3)
      .map { paragraph(seed: chatIndex * 97 + turn * 7 + $0, sentences: 4) }
      .joined(separator: "\n\n")
  }

  private static func assistantReasoning(chatIndex: Int, turn: Int) -> String {
    "Thinking through chat \(chatIndex), turn \(turn + 1).\n\n"
      + (0..<2)
        .map { paragraph(seed: chatIndex * 53 + turn * 11 + $0 + 1000, sentences: 3) }
        .joined(separator: "\n\n")
  }

  /// Deterministic pseudo-prose: a fixed corpus cycled by a simple counter so
  /// the same `seed` always yields the same text (no `Math.random`-style
  /// nondeterminism). Not meaningful language — only stable bulk.
  private static func paragraph(seed: Int, sentences: Int) -> String {
    (0..<sentences)
      .map { sentence(seed: seed &* 7 &+ $0) }
      .joined(separator: " ")
  }

  private static func sentence(seed: Int) -> String {
    let length = 8 + (abs(seed) % 7) // 8–14 words
    let words = (0..<length).map { Self.corpus[abs(seed &+ $0 &* 13) % Self.corpus.count] }
    return words.joined(separator: " ").capitalizedFirst + "."
  }

  private static let corpus: [String] = [
    "transcript", "render", "switch", "snapshot", "identity", "layout",
    "thread", "responsive", "stream", "token", "reasoning", "scroll",
    "sidebar", "message", "bubble", "deterministic", "budget", "latency",
    "model", "context", "persist", "session", "regression", "guard",
    "stability", "throughput", "pipeline", "cancel", "resume", "history",
  ]
}

private extension String {
  var capitalizedFirst: String {
    guard let first else { return self }
    return first.uppercased() + dropFirst()
  }
}
