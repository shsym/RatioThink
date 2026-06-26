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

  func test_overflowWarningTriggersOnlyWhenEstimatedPromptExceedsKnownWindow() {
    let attachments = [PendingChatAttachment(filename: "long.txt", extractedText: String(repeating: "x", count: 80), iconSystemName: "doc.text")]

    XCTAssertNil(ComposerView.attachmentOverflowWarning(draft: "hi", attachments: attachments, contextUsage: nil))
    XCTAssertNotNil(ComposerView.attachmentOverflowWarning(
      draft: "hi",
      attachments: attachments,
      contextUsage: ContextUsage(usedTokens: 90, windowTokens: 100)
    ))
  }
}
