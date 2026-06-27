import Foundation
import PDFKit

struct PendingChatAttachment: Identifiable, Equatable {
  let id = UUID()
  let filename: String
  let extractedText: String
  let iconSystemName: String
}

enum ChatAttachmentExtractionError: Error, Equatable {
  case unsupported(filename: String)
  case unreadable(filename: String)
  case emptyPDF(filename: String)

  var userMessage: String {
    switch self {
    case .unsupported(let filename):
      return "\(filename) is not a supported text or PDF attachment."
    case .unreadable(let filename):
      return "Could not read text from \(filename)."
    case .emptyPDF(let filename):
      return "No selectable text was found in \(filename)."
    }
  }
}

enum ChatAttachmentExtractor {
  private static let textExtensions: Set<String> = [
    "txt", "text", "md", "markdown", "json", "jsonl", "csv", "tsv",
    "html", "htm", "xml", "yaml", "yml", "toml", "log",
    "swift", "rs", "py", "js", "ts", "tsx", "jsx", "java", "kt",
    "c", "h", "m", "mm", "cpp", "hpp", "cs", "go", "rb", "php",
    "sh", "bash", "zsh", "sql", "css", "scss"
  ]

  static func extract(url: URL) throws -> PendingChatAttachment {
    let filename = url.lastPathComponent
    let ext = url.pathExtension.lowercased()
    if ext == "pdf" {
      return try extractPDF(url: url, filename: filename)
    }
    guard textExtensions.contains(ext) else {
      throw ChatAttachmentExtractionError.unsupported(filename: filename)
    }
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
      throw ChatAttachmentExtractionError.unreadable(filename: filename)
    }
    return PendingChatAttachment(filename: filename, extractedText: text, iconSystemName: "doc.text")
  }

  static func combinedContext(_ attachments: [PendingChatAttachment]) -> String {
    attachments.map(\.extractedText).joined(separator: "\n\n")
  }

  private static func extractPDF(url: URL, filename: String) throws -> PendingChatAttachment {
    guard let document = PDFDocument(url: url) else {
      throw ChatAttachmentExtractionError.unreadable(filename: filename)
    }
    var pages: [String] = []
    for pageIndex in 0..<document.pageCount {
      guard let text = document.page(at: pageIndex)?.string, !text.isEmpty else { continue }
      pages.append(text)
    }
    let text = pages.joined(separator: "\n\n")
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ChatAttachmentExtractionError.emptyPDF(filename: filename)
    }
    return PendingChatAttachment(filename: filename, extractedText: text, iconSystemName: "doc.richtext")
  }
}

enum ChatAttachmentContextLimiter {
  struct Result: Equatable {
    let text: String
    let notice: String?
    let wasTruncated: Bool
  }

  static let truncationNotice = "Only the front portion of the attached document(s) was added."

  static func budget(engineProvidedMaxTokens: Int, modelConfiguredContextLength: Int) -> Int {
    Int(floor(Double(min(engineProvidedMaxTokens, modelConfiguredContextLength)) * 0.5))
  }

  static func limitedContext(
    attachments: [PendingChatAttachment],
    engineProvidedMaxTokens: Int?,
    modelConfiguredContextLength: Int?,
    logUnavailable: (String) -> Void = { _ in }
  ) -> Result {
    let combined = ChatAttachmentExtractor.combinedContext(attachments)
    guard !combined.isEmpty else {
      return Result(text: "", notice: nil, wasTruncated: false)
    }
    guard let engineProvidedMaxTokens, engineProvidedMaxTokens > 0,
          let modelConfiguredContextLength, modelConfiguredContextLength > 0 else {
      logUnavailable("Attachment context budget unavailable before send; persisting full extracted attachment text.")
      return Result(text: combined, notice: nil, wasTruncated: false)
    }

    let tokenBudget = budget(
      engineProvidedMaxTokens: engineProvidedMaxTokens,
      modelConfiguredContextLength: modelConfiguredContextLength
    )
    let maxCharacters = max(0, tokenBudget * 4)
    guard combined.count > maxCharacters else {
      return Result(text: combined, notice: nil, wasTruncated: false)
    }
    return Result(
      text: String(combined.prefix(maxCharacters)),
      notice: truncationNotice,
      wasTruncated: true
    )
  }
}
