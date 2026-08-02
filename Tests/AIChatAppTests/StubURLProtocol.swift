import Foundation

/// Serves canned HTTP responses so the provider can be tested against real wire bytes without
/// reaching OpenRouter.
///
/// This is deliberately a `URLProtocol` rather than a hand-rolled `URLSession` protocol seam.
/// Stubbing at the protocol layer means the code under test builds a genuine `URLRequest`, and
/// the assertions can inspect the exact headers and JSON body that would have gone out. A
/// hand-rolled seam would let a malformed request pass unnoticed, which is precisely the class
/// of bug that only shows up against the live API.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub: Sendable {
        var statusCode: Int = 200
        var headers: [String: String] = ["Content-Type": "application/json"]
        var body: Data = Data()
        var error: URLError?
    }

    /// Guarded because URLSession invokes protocol instances off the test's thread.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var queued: [Stub] = [Stub()]
    nonisolated(unsafe) private static var captured: [URLRequest] = []
    nonisolated(unsafe) private static var capturedBodies: [Data] = []

    static func setStub(_ newValue: Stub) {
        setStubs([newValue])
    }

    /// Serves each stub to one request, in order, and keeps serving the last one afterwards.
    ///
    /// A tool round trip is two requests with two different answers — the model asking for a tool,
    /// then the model reading the tool's result — so a single canned response cannot express it.
    /// Repeating the last stub rather than running out means a test that makes an extra call fails
    /// on its assertion rather than on an opaque transport error.
    static func setStubs(_ values: [Stub]) {
        lock.lock()
        defer { lock.unlock() }
        queued = values.isEmpty ? [Stub()] : values
        captured = []
        capturedBodies = []
    }

    static func respond(statusCode: Int = 200, json: String, headers: [String: String] = [:]) {
        var merged = ["Content-Type": "application/json"]
        for (key, value) in headers { merged[key] = value }
        setStub(Stub(statusCode: statusCode, headers: merged, body: Data(json.utf8)))
    }

    static func fail(with error: URLError) {
        setStub(Stub(error: error))
    }

    static var lastRequest: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return captured.last
    }

    /// The body actually sent. `URLRequest.httpBody` is nil by the time a request reaches a
    /// `URLProtocol` — URLSession moves it to a stream — so it is captured on the way in.
    static var lastBody: Data? {
        lock.lock()
        defer { lock.unlock() }
        return capturedBodies.last
    }

    /// Every body sent, in order, so a two-hop turn can be asserted on both halves.
    static var allBodies: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return capturedBodies
    }

    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return captured.count
    }

    /// A session wired to this protocol and nothing else.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.captured.append(request)
        if let body = request.httpBody {
            Self.capturedBodies.append(body)
        } else if let stream = request.httpBodyStream {
            Self.capturedBodies.append(Data(reading: stream))
        }
        let current = Self.queued.count > 1 ? Self.queued.removeFirst() : (Self.queued.first ?? Stub())
        Self.lock.unlock()

        if let error = current.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        let url = request.url ?? OpenRouterTestFixtures.fallbackURL
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: current.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: current.headers
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: current.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension Data {
    /// Drains an `InputStream` into `Data`, which is how a POST body arrives at a URLProtocol.
    init(reading stream: InputStream) {
        self.init()
        stream.open()
        defer { stream.close() }
        let size = 4096
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            if read <= 0 { break }
            append(contentsOf: buffer[0..<read])
        }
    }
}

enum OpenRouterTestFixtures {
    static let fallbackURL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    static let textResponse = """
    {
      "id": "gen-abc123",
      "model": "openai/gpt-4o",
      "choices": [
        {
          "finish_reason": "stop",
          "native_finish_reason": "stop",
          "message": { "role": "assistant", "content": "Paris is the capital of France." }
        }
      ],
      "usage": {
        "prompt_tokens": 18,
        "completion_tokens": 7,
        "total_tokens": 25,
        "cost": 0.000104,
        "prompt_tokens_details": { "cached_tokens": 12 }
      }
    }
    """

    static let toolCallResponse = """
    {
      "id": "gen-tool-1",
      "model": "openai/gpt-4o",
      "choices": [
        {
          "finish_reason": "tool_calls",
          "message": {
            "role": "assistant",
            "content": null,
            "tool_calls": [
              {
                "id": "call_9x",
                "type": "function",
                "function": {
                  "name": "get_weather",
                  "arguments": "{\\"city\\":\\"Gurugram\\",\\"days\\":3,\\"metric\\":true}"
                }
              }
            ]
          }
        }
      ],
      "usage": { "prompt_tokens": 40, "completion_tokens": 22, "total_tokens": 62 }
    }
    """

    /// A response whose envelope omits `usage` entirely, which several upstream providers do.
    static let responseWithoutUsage = """
    {
      "choices": [ { "finish_reason": "length", "message": { "content": "truncated…" } } ]
    }
    """

    static let rateLimitedBody = """
    { "error": { "code": 429, "message": "Rate limit exceeded: free-models-per-day" } }
    """

    static let unauthorizedBody = """
    { "error": { "code": 401, "message": "No auth credentials found" } }
    """
}
