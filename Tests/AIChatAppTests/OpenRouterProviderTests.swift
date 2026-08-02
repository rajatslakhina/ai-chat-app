import Foundation
import ProviderGatewayKit
import Testing
@testable import AIChatApp

private func makeProvider(
    apiKey: String = "sk-or-v1-test",
    model: String = "openai/gpt-4o",
    usageObserver: any UsageObserving = NullUsageObserver()
) -> OpenRouterProvider {
    OpenRouterProvider(
        configuration: OpenRouterConfiguration(
            apiKey: apiKey,
            model: model,
            siteURL: "https://example.test/app",
            appName: "AI Chat",
            // These suites cover the buffered transport specifically. The SSE transport has its
            // own suite in SSEStreamingTests; sharing one default here would mean neither
            // transport was fully covered while both appeared to be.
            streaming: false
        ),
        session: StubURLProtocol.makeSession(),
        usageObserver: usageObserver
    )
}

private func makeRequest(
    _ text: String = "What is the capital of France?",
    tools: [LLMToolDefinition] = []
) -> LLMRequest {
    LLMRequest(
        messages: [
            LLMMessage(role: .system, content: "You are terse."),
            LLMMessage(role: .user, content: text)
        ],
        tools: tools,
        maxOutputTokens: 256,
        temperature: 0.4
    )
}

/// Drains the provider's stream into an array so a whole turn can be asserted at once.
private func collect(
    _ stream: AsyncThrowingStream<LLMStreamEvent, Error>
) async throws -> [LLMStreamEvent] {
    var events: [LLMStreamEvent] = []
    for try await event in stream { events.append(event) }
    return events
}

@Suite("OpenRouter request construction")
struct OpenRouterRequestTests {
    @Test("sends the documented headers")
    func headers() async throws {
        StubURLProtocol.respond(json: OpenRouterTestFixtures.textResponse)
        _ = try await collect(makeProvider().stream(request: makeRequest()))

        let request = try #require(StubURLProtocol.lastRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-or-v1-test")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "HTTP-Referer") == "https://example.test/app")
        #expect(request.value(forHTTPHeaderField: "X-Title") == "AI Chat")
    }

    @Test("omits HTTP-Referer and X-Title rather than sending them empty")
    func optionalHeadersOmitted() async throws {
        StubURLProtocol.respond(json: OpenRouterTestFixtures.textResponse)
        let provider = OpenRouterProvider(
            configuration: OpenRouterConfiguration(apiKey: "sk-or-v1-test", streaming: false),
            session: StubURLProtocol.makeSession()
        )
        _ = try await collect(provider.stream(request: makeRequest()))

        let request = try #require(StubURLProtocol.lastRequest)
        #expect(request.value(forHTTPHeaderField: "HTTP-Referer") == nil)
        #expect(request.value(forHTTPHeaderField: "X-Title") == nil)
    }

    @Test("encodes the gateway request onto OpenRouter's schema")
    func bodyShape() async throws {
        StubURLProtocol.respond(json: OpenRouterTestFixtures.textResponse)
        _ = try await collect(makeProvider().stream(request: makeRequest()))

        let body = try #require(StubURLProtocol.lastBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "openai/gpt-4o")
        #expect(json["max_tokens"] as? Int == 256)
        #expect(json["temperature"] as? Double == 0.4)
        #expect(json["stream"] as? Bool == false)
        #expect(json["tools"] == nil, "a request with no tools must omit the key entirely")

        let usage = try #require(json["usage"] as? [String: Any])
        #expect(usage["include"] as? Bool == true, "cost is only reported when asked for")

        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.count == 2)
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[1]["content"] as? String == "What is the capital of France?")
        #expect(
            messages[1]["tool_call_id"] == nil,
            "tool_call_id on a non-tool message is a 400 from several upstreams"
        )
    }

    @Test("renders tool definitions as function schemas with a parameters object")
    func toolSchema() async throws {
        StubURLProtocol.respond(json: OpenRouterTestFixtures.textResponse)
        let tool = LLMToolDefinition(
            name: "get_weather",
            toolDescription: "Look up a forecast",
            parameterSchema: ["city": .string("string")]
        )
        _ = try await collect(makeProvider().stream(request: makeRequest(tools: [tool])))

        let body = try #require(StubURLProtocol.lastBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let tools = try #require(json["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        #expect(tools[0]["type"] as? String == "function")

        let function = try #require(tools[0]["function"] as? [String: Any])
        #expect(function["name"] as? String == "get_weather")
        let parameters = try #require(function["parameters"] as? [String: Any])
        #expect(parameters["type"] as? String == "object")
        #expect(parameters["properties"] != nil, "a null parameters object is rejected upstream")
    }
}

@Suite("OpenRouter response mapping")
struct OpenRouterResponseTests {
    @Test("a text answer becomes a delta followed by a terminal completion")
    func textTurn() async throws {
        StubURLProtocol.respond(json: OpenRouterTestFixtures.textResponse)
        let events = try await collect(makeProvider().stream(request: makeRequest()))

        #expect(events.count == 2)
        #expect(events.first == .textDelta("Paris is the capital of France."))
        guard case let .completed(response) = events.last else {
            Issue.record("expected a terminal .completed, got \(String(describing: events.last))")
            return
        }
        #expect(response.text == "Paris is the capital of France.")
        #expect(response.finishReason == .stop)
        #expect(response.providerID == .openRouter)
    }

    @Test("finish_reason length maps to maxTokens, not stop")
    func lengthFinish() async throws {
        StubURLProtocol.respond(json: OpenRouterTestFixtures.responseWithoutUsage)
        let events = try await collect(makeProvider().stream(request: makeRequest()))
        guard case let .completed(response) = events.last else {
            Issue.record("expected .completed")
            return
        }
        #expect(response.finishReason == .maxTokens)
    }

    @Test("a tool call is terminal and its JSON-string arguments are parsed")
    func toolCallTurn() async throws {
        StubURLProtocol.respond(json: OpenRouterTestFixtures.toolCallResponse)
        let events = try await collect(makeProvider().stream(request: makeRequest()))

        #expect(events.count == 1, "a tool call ends the stream; no completion follows")
        guard case let .toolCallRequested(call) = events.first else {
            Issue.record("expected .toolCallRequested, got \(String(describing: events.first))")
            return
        }
        #expect(call.id == "call_9x")
        #expect(call.toolName == "get_weather")
        #expect(call.arguments["city"] == .string("Gurugram"))
        #expect(call.arguments["days"] == .int(3))
        #expect(call.arguments["metric"] == .bool(true))
    }

    @Test("malformed tool arguments yield empty arguments rather than failing the request")
    func malformedToolArguments() {
        #expect(OpenRouterProvider.decodeArguments("{not json") == [:])
        #expect(OpenRouterProvider.decodeArguments(nil) == [:])
        #expect(OpenRouterProvider.decodeArguments("[1,2]") == [:], "a non-object is not arguments")
    }
}

@Suite("OpenRouter usage reporting")
struct OpenRouterUsageTests {
    @Test("token counts and reported cost reach the observer")
    func recordsUsage() async throws {
        StubURLProtocol.respond(json: OpenRouterTestFixtures.textResponse)
        let recorder = UsageRecorder()
        _ = try await collect(makeProvider(usageObserver: recorder).stream(request: makeRequest()))

        let usage = try #require(await recorder.mostRecent)
        #expect(usage.requestID == "gen-abc123")
        #expect(usage.model == "openai/gpt-4o")
        #expect(usage.promptTokens == 18)
        #expect(usage.completionTokens == 7)
        #expect(usage.cachedPromptTokens == 12)
        #expect(usage.totalTokens == 25)
        #expect(usage.reportedCostUSD == 0.000104)
        let total = await recorder.reportedCostUSD
        #expect(total == 0.000104)
    }

    @Test("a response with no usage envelope records nothing rather than recording zeroes")
    func absentUsageIsNotZero() async throws {
        StubURLProtocol.respond(json: OpenRouterTestFixtures.responseWithoutUsage)
        let recorder = UsageRecorder()
        _ = try await collect(makeProvider(usageObserver: recorder).stream(request: makeRequest()))

        let records = await recorder.records
        #expect(records.isEmpty)
        let cost = await recorder.reportedCostUSD
        #expect(cost == nil, "no reported cost is a different fact from a cost of zero")
    }
}

@Suite("OpenRouter failure mapping")
struct OpenRouterFailureTests {
    /// Runs a turn expected to fail and returns the error, so each case stays one assertion.
    private func failure(of provider: OpenRouterProvider) async -> Error? {
        do {
            _ = try await collect(provider.stream(request: makeRequest()))
            return nil
        } catch {
            return error
        }
    }

    @Test("429 becomes rateLimited carrying Retry-After, so the breaker can back off")
    func rateLimited() async throws {
        StubURLProtocol.respond(
            statusCode: 429,
            json: OpenRouterTestFixtures.rateLimitedBody,
            headers: ["Retry-After": "30"]
        )
        let error = try #require(await failure(of: makeProvider()))
        #expect(error as? ProviderError == .rateLimited(retryAfter: .seconds(30)))
    }

    @Test("a Retry-After date is treated as absent rather than guessed at")
    func retryAfterDateIgnored() async throws {
        StubURLProtocol.respond(
            statusCode: 429,
            json: OpenRouterTestFixtures.rateLimitedBody,
            headers: ["Retry-After": "Wed, 21 Oct 2026 07:28:00 GMT"]
        )
        let error = try #require(await failure(of: makeProvider()))
        #expect(error as? ProviderError == .rateLimited(retryAfter: nil))
    }

    @Test("401 becomes capabilityMismatch, which the router will not retry into")
    func unauthorized() async throws {
        StubURLProtocol.respond(statusCode: 401, json: OpenRouterTestFixtures.unauthorizedBody)
        let error = try #require(await failure(of: makeProvider()))
        guard case let .capabilityMismatch(message) = error as? ProviderError else {
            Issue.record("expected .capabilityMismatch, got \(error)")
            return
        }
        #expect(message.contains("No auth credentials found"))
    }

    @Test("402 out-of-credit is reported as itself, not as a generic connection failure")
    func outOfCredit() async throws {
        StubURLProtocol.respond(
            statusCode: 402,
            json: #"{ "error": { "code": 402, "message": "Insufficient credits" } }"#
        )
        let error = try #require(await failure(of: makeProvider()))
        guard case let .capabilityMismatch(message) = error as? ProviderError else {
            Issue.record("expected .capabilityMismatch, got \(error)")
            return
        }
        #expect(message.contains("out of credit"))
    }

    @Test("a timeout maps to .timeout and a dead host to .connectionFailed")
    func transportFailures() async throws {
        StubURLProtocol.fail(with: URLError(.timedOut))
        let timeout = await failure(of: makeProvider())
        #expect(timeout as? ProviderError == .timeout)

        StubURLProtocol.fail(with: URLError(.cannotConnectToHost))
        let dead = await failure(of: makeProvider())
        guard case .connectionFailed = dead as? ProviderError else {
            Issue.record("a dead host must be distinguishable from a rate limit")
            return
        }
    }

    @Test("500 becomes connectionFailed carrying the status, so the breaker opens")
    func serverError() async throws {
        StubURLProtocol.respond(statusCode: 500, json: #"{"error":{"message":"upstream boom"}}"#)
        let error = try #require(await failure(of: makeProvider()))
        guard case let .connectionFailed(message) = error as? ProviderError else {
            Issue.record("expected .connectionFailed, got \(error)")
            return
        }
        #expect(message.contains("500"))
        #expect(message.contains("upstream boom"))
    }

    @Test("a missing key fails before any request is sent")
    func missingKeyShortCircuits() async throws {
        StubURLProtocol.respond(json: OpenRouterTestFixtures.textResponse)
        let error = try #require(await failure(of: makeProvider(apiKey: "")))
        #expect(
            error as? ProviderError == .capabilityMismatch("no OpenRouter API key is configured")
        )
        #expect(StubURLProtocol.requestCount == 0, "no key must mean no network call at all")
    }
}
