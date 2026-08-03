import Foundation
import SwiftData
import RatioThinkCore

// Emits the EXACT bytes `ChatSendController.prepareBestOfNCommit` produces, so
// a gate can POST Swift's own output instead of a hand-written approximation.
//
// WHY THIS EXISTS. Every dev gate builds its own request, which means it can
// only test the half it models — a lesson learned twice here, expensively:
// a think-more that 400'd on every attempt, and a total ToT/Best-of-N outage,
// both invisible because the gates constructed inputs the client never would.
// The view-commit gate had the same shape: its Python body and this encoder
// were pinned to each other only by someone having read both.
//
// The two values a commit cannot know ahead of time — the round scope and the
// candidate's digest-addressed name — are passed in, so the gate runs a REAL
// round first and hands back what the guest actually minted. Everything else,
// including the message shaping that decides which boundary gets named, is
// produced here by the same code path the app runs.
//
// Usage (all required):
//   bon-commit-body --round-id R --snapshot NAME --answer TEXT
//                   --user TEXT [--system TEXT] [--turn N]
// Writes the encoded `input` object to stdout.

@MainActor
func emit() throws {
    var args: [String: String] = [:]
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let key = it.next() {
        guard key.hasPrefix("--"), let value = it.next() else {
            throw Failure("expected --flag value pairs, got \(key)")
        }
        args[String(key.dropFirst(2))] = value
    }
    func need(_ k: String) throws -> String {
        guard let v = args[k], !v.isEmpty else { throw Failure("missing --\(k)") }
        return v
    }

    // A real Chat graph, shaped the way the app's is at commit time: the user
    // turn, then the assistant row still EMPTY. That emptiness is load-bearing
    // — an empty-content assistant is excluded from request history, which is
    // why the commit is prepared before the answer is written and why its
    // `messages` must not contain the accepted answer.
    let container = try RatioThinkModelContainer.makeInMemory()
    let context = ModelContext(container)
    let chat = Chat()
    context.insert(chat)
    chat.messages.append(
        Message(role: "user", content: try need("user"),
                ts: Date(timeIntervalSinceReferenceDate: 1)))
    let assistant = Message(role: "assistant", content: "",
                            ts: Date(timeIntervalSinceReferenceDate: 2))

    let snapshot = try need("snapshot")
    let round = BestOfNRound(
        level: 2,
        candidates: [ToTSelectionCandidate(id: "bon-n1", branchIndex: 0, snapshotName: snapshot)],
        chosenID: "bon-n1",
        roundID: try need("round-id"))
    assistant.bestOfN = try JSONEncoder().encode(round)
    chat.messages.append(assistant)
    try context.save()

    let options = ChatSendRequestOptions(
        modelID: args["model"] ?? "qwen",
        sampling: ChatSampling(temperature: 0.7, topP: 0.95, maxTokens: 256),
        systemPromptOverride: args["system"])

    guard let prepared = ChatSendController.prepareBestOfNCommit(
        chat: chat, options: options, round: round, answer: try need("answer"))
    else { throw Failure("prepareBestOfNCommit returned nil") }

    // The COMPLETE dispatch envelope, encoded the way `dispatchInferlet` does
    // — so the gate posts the whole HTTP body Swift would send, not just the
    // inner object. Only the URL is the gate's, and endpoint parity covers that.
    FileHandle.standardOutput.write(try JSONEncoder().encode(prepared.dispatchRequest))
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

do {
    if #available(macOS 14, *) {
        try MainActor.assumeIsolated { try emit() }
    } else {
        throw Failure("requires macOS 14")
    }
} catch {
    FileHandle.standardError.write(Data("bon-commit-body: \(error)\n".utf8))
    exit(1)
}
