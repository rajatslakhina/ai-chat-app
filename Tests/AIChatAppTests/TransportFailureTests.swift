import Foundation
import ProviderGatewayKit
import Security
import Testing
@testable import AIChatApp

/// Serves a non-HTTP response, which `URLSession` allows for non-HTTP schemes.
///
/// The provider guards on the cast to `HTTPURLResponse`. That guard is not paranoia — a redirect
/// to a `file://` or `data:` URL produces exactly this — but it is unreachable through the normal
/// HTTP stub, so it needs a protocol that deliberately produces one.
final class NonHTTPURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url ?? OpenRouterTestFixtures.fallbackURL
        let response = URLResponse(
            url: url,
            mimeType: "application/json",
            expectedContentLength: 2,
            textEncodingName: "utf-8"
        )
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NonHTTPURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private func provider(streaming: Bool, session: URLSession) -> OpenRouterProvider {
    OpenRouterProvider(
        configuration: OpenRouterConfiguration(apiKey: "sk-or-v1-test", streaming: streaming),
        session: session
    )
}

private func drain(_ provider: OpenRouterProvider) async -> Error? {
    do {
        let request = LLMRequest(messages: [LLMMessage(role: .user, content: "hi")])
        for try await _ in provider.stream(request: request) {}
        return nil
    } catch {
        return error
    }
}

@Suite("Transport failures on both paths")
struct TransportFailureTests {
    @Test("a non-HTTP response is refused on the buffered path")
    func bufferedNonHTTP() async throws {
        let session = NonHTTPURLProtocol.makeSession()
        let error = await drain(provider(streaming: false, session: session))
        guard case let .connectionFailed(message) = error as? ProviderError else {
            Issue.record("expected .connectionFailed, got \(String(describing: error))")
            return
        }
        #expect(message.contains("not HTTP"))
    }

    @Test("a non-HTTP response is refused on the streaming path too")
    func streamingNonHTTP() async throws {
        let session = NonHTTPURLProtocol.makeSession()
        let error = await drain(provider(streaming: true, session: session))
        guard case let .connectionFailed(message) = error as? ProviderError else {
            Issue.record("expected .connectionFailed, got \(String(describing: error))")
            return
        }
        #expect(message.contains("not HTTP"))
    }

    @Test("a URLError on the streaming path maps the same way as on the buffered one")
    func streamingURLError() async throws {
        StubURLProtocol.fail(with: URLError(.timedOut))
        let error = await drain(provider(streaming: true, session: StubURLProtocol.makeSession()))
        #expect(error as? ProviderError == .timeout)
    }

    @Test("a cancelled request is reported as cancelled, not as a dead host")
    func cancelledRequest() async throws {
        StubURLProtocol.fail(with: URLError(.cancelled))
        let error = await drain(provider(streaming: false, session: StubURLProtocol.makeSession()))
        guard case let .connectionFailed(message) = error as? ProviderError else {
            Issue.record("expected .connectionFailed, got \(String(describing: error))")
            return
        }
        #expect(message.contains("cancelled"))
    }

    @Test("gateway-timeout statuses become .timeout so the breaker retries rather than opens")
    func gatewayTimeoutStatuses() async throws {
        for status in [408, 504] {
            StubURLProtocol.respond(statusCode: status, json: #"{"error":{"message":"slow"}}"#)
            let session = StubURLProtocol.makeSession()
            let error = await drain(provider(streaming: false, session: session))
            #expect(error as? ProviderError == .timeout, "HTTP \(status) should read as a timeout")
        }
    }

    @Test("a 2xx body that is not a chat response is a decode failure, not an empty answer")
    func undecodableBufferedBody() async throws {
        StubURLProtocol.respond(json: #"{"unexpected":"shape"}"#)
        let error = await drain(provider(streaming: false, session: StubURLProtocol.makeSession()))
        guard case let .connectionFailed(message) = error as? ProviderError else {
            Issue.record("expected .connectionFailed, got \(String(describing: error))")
            return
        }
        #expect(message.contains("could not decode response"))
    }

    @Test("an error body that is not JSON still yields a message rather than a bare status")
    func nonJSONErrorBody() async throws {
        StubURLProtocol.respond(statusCode: 503, json: "upstream is down")
        let error = await drain(provider(streaming: false, session: StubURLProtocol.makeSession()))
        guard case let .connectionFailed(message) = error as? ProviderError else {
            Issue.record("expected .connectionFailed, got \(String(describing: error))")
            return
        }
        #expect(message.contains("503"))
        #expect(message.contains("upstream is down"))
    }

    @Test("a catalog fetch over a non-HTTP response is refused")
    func catalogNonHTTP() async throws {
        let client = ModelCatalogClient(
            configuration: OpenRouterConfiguration(apiKey: "k"),
            session: NonHTTPURLProtocol.makeSession()
        )
        do {
            _ = try await client.fetchCatalog()
            Issue.record("expected a throw")
        } catch {
            guard case let .connectionFailed(message) = error as? ProviderError else {
                Issue.record("expected .connectionFailed, got \(error)")
                return
            }
            #expect(message.contains("not HTTP"))
        }
    }

    @Test("a catalog fetch that cannot connect maps onto the gateway error model")
    func catalogTransportError() async throws {
        StubURLProtocol.fail(with: URLError(.notConnectedToInternet))
        let client = ModelCatalogClient(
            configuration: OpenRouterConfiguration(apiKey: "k"),
            session: StubURLProtocol.makeSession()
        )
        do {
            _ = try await client.fetchCatalog()
            Issue.record("expected a throw")
        } catch {
            guard case .connectionFailed = error as? ProviderError else {
                Issue.record("expected .connectionFailed, got \(error)")
                return
            }
        }
    }
}

@Suite("Streaming edge paths")
struct StreamingEdgePathTests {
    private func stub(_ body: String) {
        StubURLProtocol.setStub(
            .init(
                statusCode: 200,
                headers: ["Content-Type": "text/event-stream"],
                body: Data(body.utf8)
            )
        )
    }

    private func run(usageObserver: any UsageObserving = NullUsageObserver()) async throws
        -> [LLMStreamEvent] {
        let provider = OpenRouterProvider(
            configuration: OpenRouterConfiguration(apiKey: "k", streaming: true),
            session: StubURLProtocol.makeSession(),
            usageObserver: usageObserver
        )
        var events: [LLMStreamEvent] = []
        let request = LLMRequest(messages: [LLMMessage(role: .user, content: "hi")])
        for try await event in provider.stream(request: request) { events.append(event) }
        return events
    }

    /// A frame that is valid JSON but is not an object cannot decode as a chunk. The earlier
    /// "unknown field" test does not cover this: every chunk field is optional, so an object with
    /// unrecognised keys decodes fine. Only a non-object frame reaches the skip path.
    @Test("a valid-JSON frame that is not a chunk is skipped, not fatal")
    func nonObjectFrameIsSkipped() async throws {
        stub("""
        data: ["not", "a", "chunk"]

        data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}

        data: [DONE]

        """)
        let events = try await run()
        guard case let .completed(response) = events.last else {
            Issue.record("expected .completed")
            return
        }
        #expect(response.text == "ok")
    }

    /// The drain path. A stream that stops without `[DONE]` and without a trailing blank line
    /// leaves its final event buffered — and that final event is the one carrying usage.
    @Test("a stream ending without DONE still delivers its last chunk")
    func streamWithoutTerminator() async throws {
        stub(
            "data: {\"choices\":[{\"delta\":{\"content\":\"partial\"},"
                + "\"finish_reason\":\"stop\"}],"
                + "\"usage\":{\"prompt_tokens\":9,\"completion_tokens\":3,\"cost\":0.00002}}"
        )
        let recorder = UsageRecorder()
        let events = try await run(usageObserver: recorder)

        guard case let .completed(response) = events.last else {
            Issue.record("expected .completed")
            return
        }
        #expect(response.text == "partial")
        let usage = try #require(await recorder.mostRecent)
        #expect(usage.promptTokens == 9)
        #expect(usage.reportedCostUSD == 0.00002, "the drain must not drop the usage chunk")
    }

    @Test("an empty stream body yields an empty completion rather than hanging")
    func emptyStream() async throws {
        stub("")
        let events = try await run()
        guard case let .completed(response) = events.last else {
            Issue.record("expected .completed")
            return
        }
        #expect(response.text.isEmpty)
    }
}

@Suite("Keychain failure paths", .serialized)
struct KeychainFailureTests {
    /// Plants raw non-UTF8 bytes under the account, which only a foreign writer would do.
    @Test("a value that is not UTF-8 is reported as corrupted rather than returned as nil")
    func corruptedValue() throws {
        let service = "com.rajatslakhina.aichatapp.tests.corrupt.\(UUID().uuidString)"
        let store = KeychainStore(service: service)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "k",
            // 0xFF 0xFE is not valid UTF-8.
            kSecValueData as String: Data([0xFF, 0xFE])
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        #expect(status == errSecSuccess)

        #expect(throws: KeychainError.dataCorrupted(account: "k")) {
            _ = try store.string(for: "k")
        }
        try store.remove("k")
    }
}
