import XCTest
import CoreGraphics
import CoreText
import PDFKit
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

  func test_extractPDF_readsSelectableTextAndKeepsRichTextIcon() throws {
    let dir = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("selectable.pdf")
    let sentence = "Selectable PDF attachment sentinel alpha bravo charlie."
    try writeSelectableTextPDF(sentence, to: url)

    let extractedByPDFKit = try XCTUnwrap(PDFDocument(url: url)?.page(at: 0)?.string)
    XCTAssertTrue(
      extractedByPDFKit.contains(sentence),
      "Test fixture must contain a selectable PDF text layer before exercising ChatAttachmentExtractor."
    )

    let attachment = try ChatAttachmentExtractor.extract(url: url)

    XCTAssertEqual(attachment.filename, "selectable.pdf")
    XCTAssertTrue(attachment.extractedText.contains(sentence))
    XCTAssertEqual(attachment.iconSystemName, "doc.richtext")
  }

  func test_extractPDFWithoutSelectableTextThrowsEmptyPDF() throws {
    let dir = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("image-only.pdf")
    try writeImageOnlyPDF(to: url)

    let extractedByPDFKit = PDFDocument(url: url)?.page(at: 0)?.string ?? ""
    XCTAssertTrue(
      extractedByPDFKit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      "Test fixture must not contain selectable text before exercising the empty-PDF path."
    )

    XCTAssertThrowsError(try ChatAttachmentExtractor.extract(url: url)) { error in
      XCTAssertEqual(error as? ChatAttachmentExtractionError, .emptyPDF(filename: "image-only.pdf"))
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

  private func makeTemporaryDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func writeSelectableTextPDF(_ text: String, to url: URL) throws {
    try writePDF(to: url) { context in
      let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(
          "Helvetica" as CFString,
          18,
          nil
        ),
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
      ]
      let attributed = NSAttributedString(string: text, attributes: attributes)
      let framesetter = CTFramesetterCreateWithAttributedString(attributed)
      let path = CGMutablePath()
      path.addRect(CGRect(x: 72, y: 680, width: 468, height: 60))
      let frame = CTFramesetterCreateFrame(
        framesetter,
        CFRange(location: 0, length: attributed.length),
        path,
        nil
      )
      CTFrameDraw(frame, context)
    }
  }

  private func writeImageOnlyPDF(to url: URL) throws {
    try writePDF(to: url) { context in
      context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
      context.fill(CGRect(x: 72, y: 640, width: 180, height: 80))
    }
  }

  private func writePDF(to url: URL, draw: (CGContext) -> Void) throws {
    var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let consumer = CGDataConsumer(url: url as CFURL),
          let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
      throw CocoaError(.fileWriteUnknown)
    }
    context.beginPDFPage(nil)
    draw(context)
    context.endPDFPage()
    context.closePDF()
  }
}
