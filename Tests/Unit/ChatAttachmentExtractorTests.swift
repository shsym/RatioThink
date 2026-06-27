import XCTest
@testable import RatioThink

final class ChatAttachmentExtractorTests: XCTestCase {
  func test_extractTextFile_readsUTF8TextAndKeepsFilenameForChip() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("notes.md")
    try "# Notes\nhello".write(to: url, atomically: true, encoding: .utf8)

    let attachment = try ChatAttachmentExtractor.extract(url: url)

    XCTAssertEqual(attachment.filename, "notes.md")
    XCTAssertEqual(attachment.extractedText, "# Notes\nhello")
    XCTAssertEqual(attachment.iconSystemName, "doc.text")
  }

  func test_extractUnsupportedBinary_rejectsWithUserFacingMessage() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("photo.png")
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: url)

    XCTAssertThrowsError(try ChatAttachmentExtractor.extract(url: url)) { error in
      XCTAssertEqual((error as? ChatAttachmentExtractionError)?.userMessage,
                     "photo.png is not a supported text or PDF attachment.")
    }
  }

  func test_combinedContextPreservesEveryAttachmentWithoutTruncating() {
    let first = PendingChatAttachment(filename: "a.txt", extractedText: String(repeating: "a", count: 8), iconSystemName: "doc.text")
    let second = PendingChatAttachment(filename: "b.json", extractedText: String(repeating: "b", count: 8), iconSystemName: "doc.text")

    XCTAssertEqual(ChatAttachmentExtractor.combinedContext([first, second]), "aaaaaaaa\n\nbbbbbbbb")
  }

  func test_contextLimitBudgetUsesHalfOfSmallerEngineAndModelLimit() {
    XCTAssertEqual(
      ChatAttachmentContextLimiter.budget(engineProvidedMaxTokens: 100, modelConfiguredContextLength: 1000),
      50
    )
    XCTAssertEqual(
      ChatAttachmentContextLimiter.budget(engineProvidedMaxTokens: 1000, modelConfiguredContextLength: 120),
      60
    )
  }

  func test_contextUnderBudgetStoresCombinedTextUnchangedWithoutAlert() {
    let attachments = [
      PendingChatAttachment(filename: "a.txt", extractedText: "alpha", iconSystemName: "doc.text"),
      PendingChatAttachment(filename: "b.txt", extractedText: "beta", iconSystemName: "doc.text"),
    ]

    let result = ChatAttachmentContextLimiter.limitedContext(
      attachments: attachments,
      engineProvidedMaxTokens: 100,
      modelConfiguredContextLength: 100
    )

    XCTAssertEqual(result.text, "alpha\n\nbeta")
    XCTAssertNil(result.notice)
    XCTAssertFalse(result.wasTruncated)
  }

  func test_contextOverBudgetStoresFrontTruncatedPrefixAndShowsAlert() {
    let attachments = [
      PendingChatAttachment(filename: "long.txt", extractedText: String(repeating: "a", count: 20), iconSystemName: "doc.text"),
      PendingChatAttachment(filename: "tail.txt", extractedText: String(repeating: "b", count: 20), iconSystemName: "doc.text"),
    ]

    let result = ChatAttachmentContextLimiter.limitedContext(
      attachments: attachments,
      engineProvidedMaxTokens: 4,
      modelConfiguredContextLength: 100
    )

    XCTAssertEqual(result.text, "aaaaaaaa")
    XCTAssertEqual(result.notice, ChatAttachmentContextLimiter.truncationNotice)
    XCTAssertTrue(result.wasTruncated)
  }
}
