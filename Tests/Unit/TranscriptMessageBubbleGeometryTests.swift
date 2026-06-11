import AppKit
import SwiftUI
import XCTest
@testable import RatioThink

/// Offscreen AppKit-hosted transcript geometry guard for #526's generation
/// metrics row. This deliberately uses an `NSHostingView` rather than
/// hand-rolled layout math: SwiftUI/AppKit bridging details are part of the
/// regression surface for row overlap and height compounding bugs.
@MainActor
final class TranscriptMessageBubbleGeometryTests: XCTestCase {
  private let widths: [CGFloat] = [800, 1100, 1440, 1920]

  func test_messageBubblesWithGenerationMetrics_fitAndDoNotOverlapAcrossWidthSweep() throws {
    for width in widths {
      let snapshot = try layoutTranscript(width: width)

      XCTAssertEqual(snapshot.firstPass.rowFrames.count, Self.messages.count,
                     "[\(width)] expected one measured frame per transcript row")
      XCTAssertEqual(snapshot.secondPass.rowFrames.count, Self.messages.count,
                     "[\(width)] repeated layout should preserve measured row count")

      assertRowsFitWithinProposedWidth(snapshot.firstPass.rowFrames, width: width)
      assertSiblingRowsDoNotIntersect(snapshot.firstPass.rowFrames, width: width)
      assertHeightsStable(first: snapshot.firstPass.rowFrames,
                          second: snapshot.secondPass.rowFrames,
                          width: width)
      try assertMetricsLineSitsBelowAnswerContent(in: snapshot, width: width)
    }
  }

  private func layoutTranscript(width: CGFloat) throws -> LayoutSnapshot {
    let store = FrameStore()
    let host = NSHostingView(rootView: TranscriptGeometryHarness(messages: Self.messages, store: store))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: width, height: 2_000),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.contentView = host
    host.frame = NSRect(x: 0, y: 0, width: width, height: 2_000)

    pumpLayout(host)
    let firstPass = try LayoutPass(
      rowFrames: store.rowFrames(expectedCount: Self.messages.count),
      messageFrames: store.messageFrames
    )

    pumpLayout(host)
    let secondPass = try LayoutPass(
      rowFrames: store.rowFrames(expectedCount: Self.messages.count),
      messageFrames: store.messageFrames
    )

    return LayoutSnapshot(firstPass: firstPass, secondPass: secondPass)
  }

  private func pumpLayout(_ view: NSView) {
    for _ in 0..<6 {
      view.needsLayout = true
      view.layoutSubtreeIfNeeded()
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
  }

  private func assertRowsFitWithinProposedWidth(_ rows: [CGRect], width: CGFloat) {
    for (index, frame) in rows.enumerated() {
      XCTAssertGreaterThanOrEqual(frame.minX, -1,
                                  "[\(width)] row \(index) overflows left: \(frame)")
      XCTAssertLessThanOrEqual(frame.maxX, width + 1,
                               "[\(width)] row \(index) overflows right: \(frame)")
      XCTAssertGreaterThan(frame.height, 0,
                           "[\(width)] row \(index) should have a nonzero laid-out height")
    }
  }

  private func assertSiblingRowsDoNotIntersect(_ rows: [CGRect], width: CGFloat) {
    for i in rows.indices {
      for j in rows.indices where j > i {
        XCTAssertFalse(rows[i].intersects(rows[j]),
                       "[\(width)] sibling rows \(i) and \(j) intersect: \(rows[i]) vs \(rows[j])")
      }
    }
  }

  private func assertHeightsStable(first: [CGRect], second: [CGRect], width: CGFloat) {
    XCTAssertEqual(first.count, second.count, "[\(width)] row count changed between repeated layout passes")
    for index in first.indices {
      XCTAssertEqual(first[index].height, second[index].height, accuracy: 0.5,
                     "[\(width)] row \(index) height compounded between repeated layout passes: " +
                     "\(first[index].height) -> \(second[index].height)")
    }
  }

  private func assertMetricsLineSitsBelowAnswerContent(in snapshot: LayoutSnapshot, width: CGFloat) throws {
    let contentFrame = try XCTUnwrap(
      snapshot.firstPass.messageFrames[.content(Self.metricMessageID)],
      "[\(width)] expected an answer content frame for the metrics-bearing assistant row; " +
      "frames=\(snapshot.firstPass.messageFrames)"
    )
    let metricFrame = try XCTUnwrap(
      snapshot.firstPass.messageFrames[.generationPerformance(Self.metricMessageID)],
      "[\(width)] expected a generation metrics frame for the metrics-bearing assistant row; " +
      "frames=\(snapshot.firstPass.messageFrames)"
    )

    XCTAssertFalse(metricFrame.intersects(contentFrame),
                   "[\(width)] metrics line intersects answer content: metric=\(metricFrame), content=\(contentFrame)")

    // SwiftUI's global coordinate space in this hosted hierarchy is top-down:
    // a visually lower metrics line has a larger y range than the answer
    // content above it.
    XCTAssertGreaterThanOrEqual(metricFrame.minY, contentFrame.maxY - 1,
                                "[\(width)] metrics line should sit below answer content: " +
                                "metric=\(metricFrame), content=\(contentFrame)")
  }

  private static let metricMessageID = UUID(uuidString: "00000000-0000-0000-0000-000000000526")!

  private static let messages: [ChatMessageItem] = [
    ChatMessageItem(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
      role: .user,
      content: "Please summarize the layout risk in one sentence."
    ),
    ChatMessageItem(
      id: metricMessageID,
      role: .assistant,
      content: "The metrics geometry answer must wrap naturally inside the bubble while the compact throughput row remains visually below the answer content at every tested transcript width.",
      finishReason: "stop",
      generationPerformance: GenerationMetrics(outputTokens: 84, elapsedSeconds: 2.0, tokensPerSecond: 42.0)
    ),
    ChatMessageItem(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
      role: .user,
      content: "Thanks — keep the rows separated."
    ),
  ]
}

private struct TranscriptGeometryHarness: View {
  let messages: [ChatMessageItem]
  let store: FrameStore

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
        MessageBubble(message: message)
          .background(RowFrameProbe(index: index))
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .coordinateSpace(name: Self.coordinateSpace)
    .onPreferenceChange(RowFramePreferenceKey.self) { frames in
      store.rowFrames = frames
    }
    .onPreferenceChange(MessageBubbleLayoutFramePreferenceKey.self) { frames in
      store.messageFrames = frames
    }
  }

  static let coordinateSpace = "transcript-geometry-harness"
}

private struct RowFrameProbe: View {
  let index: Int

  var body: some View {
    GeometryReader { proxy in
      Color.clear.preference(
        key: RowFramePreferenceKey.self,
        value: [index: proxy.frame(in: .named(TranscriptGeometryHarness.coordinateSpace))]
      )
    }
  }
}

private struct RowFramePreferenceKey: PreferenceKey {
  static var defaultValue: [Int: CGRect] = [:]

  static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
    value.merge(nextValue(), uniquingKeysWith: { _, new in new })
  }
}

@MainActor
private final class FrameStore {
  var rowFrames: [Int: CGRect] = [:]
  var messageFrames: [MessageBubbleLayoutFrameID: CGRect] = [:]

  func rowFrames(expectedCount: Int) throws -> [CGRect] {
    try (0..<expectedCount).map { index in
      try XCTUnwrap(rowFrames[index], "missing measured frame for transcript row \(index); frames=\(rowFrames)")
    }
  }
}

private struct LayoutPass {
  let rowFrames: [CGRect]
  let messageFrames: [MessageBubbleLayoutFrameID: CGRect]
}

private struct LayoutSnapshot {
  let firstPass: LayoutPass
  let secondPass: LayoutPass
}
