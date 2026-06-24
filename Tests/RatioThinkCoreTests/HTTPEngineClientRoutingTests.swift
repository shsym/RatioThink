import XCTest
@testable import RatioThinkCore

final class HTTPEngineClientRoutingTests: XCTestCase {
  override func setUp() {
    super.setUp()
    RoutingURLProtocol.reset()
  }

  override func tearDown() {
    RoutingURLProtocol.reset()
    super.tearDown()
  }

  func test_bestOfN_release_posts_unary_dispatch_body_to_chatCompletions() async throws {
    let captured = RequestCapture()
    RoutingURLProtocol.handler = { req in
      captured.set(req)
      return (200, #"{"object":"best_of_n.release","requested":1,"released":1,"absent":0}"#)
    }
    let req = InferletRequest(
      inferlet: "best-of-n",
      input: Data(#"{"release":["bon/r/1/0"]}"#.utf8),
      messages: nil,
      stream: false)

    var frames: [Data] = []
    for try await frame in makeClient().dispatchInferlet(req) {
      frames.append(frame)
    }

    XCTAssertEqual(frames.count, 1, "release still returns the unary ack body")
    let url = try XCTUnwrap(captured.url())
    XCTAssertEqual(url.path, "/v1/chat/completions")
    XCTAssertEqual(captured.timeout(), 5, "release remains a short unary control request")
    let bodyData = try XCTUnwrap(captured.body())
    let top = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
    XCTAssertEqual(top["inferlet"] as? String, "best-of-n")
    XCTAssertEqual(top["stream"] as? Bool, false)
    XCTAssertNil(top["messages"], "release carries no chat messages")
  }

  func test_bestOfN_nonRelease_nonStream_dispatch_stays_on_inferlet_route() async throws {
    let captured = RequestCapture()
    RoutingURLProtocol.handler = { req in
      captured.set(req)
      return (200, #"{"object":"ack"}"#)
    }
    let req = InferletRequest(
      inferlet: "best-of-n",
      input: Data(#"{"question":"pick one"}"#.utf8),
      messages: [ChatMessage(role: .user, content: "hi")],
      stream: false)

    for try await _ in makeClient().dispatchInferlet(req) {}

    let url = try XCTUnwrap(captured.url())
    XCTAssertEqual(url.path, "/v1/inferlet")
  }

  private func makeClient() -> HTTPEngineClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [RoutingURLProtocol.self]
    let session = URLSession(configuration: config)
    return HTTPEngineClient(
      baseURL: URL(string: "http://127.0.0.1:54321")!,
      session: session,
      unaryTimeout: 5
    )
  }
}

private final class RoutingURLProtocol: URLProtocol {
  private static let lock = NSLock()
  private static var _handler: ((URLRequest) -> (status: Int, body: String))?

  static var handler: ((URLRequest) -> (status: Int, body: String))? {
    get { lock.lock(); defer { lock.unlock() }; return _handler }
    set { lock.lock(); _handler = newValue; lock.unlock() }
  }

  static func reset() { handler = nil }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let handler = Self.handler else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    let stub = handler(request)
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: stub.status,
      httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/json"]
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(stub.body.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

private final class RequestCapture: @unchecked Sendable {
  private let lock = NSLock()
  private var request: URLRequest?

  func set(_ req: URLRequest) {
    lock.lock(); request = req; lock.unlock()
  }

  func url() -> URL? {
    lock.lock(); defer { lock.unlock() }
    return request?.url
  }

  func timeout() -> TimeInterval? {
    lock.lock(); defer { lock.unlock() }
    return request?.timeoutInterval
  }

  func body() -> Data? {
    lock.lock(); defer { lock.unlock() }
    guard let req = request else { return nil }
    if let body = req.httpBody { return body }
    guard let stream = req.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
      let n = stream.read(&buffer, maxLength: buffer.count)
      if n <= 0 { break }
      data.append(buffer, count: n)
    }
    return data
  }
}
