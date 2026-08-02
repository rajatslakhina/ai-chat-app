import Foundation
import ProviderGatewayKit
import StreamAggregatorKit
import Testing
@testable import AIChatApp

/// Streams captured from the live OpenRouter API, byte for byte.
///
/// Hand-written fixtures would encode what the docs say. These encode what the server did —
/// including the keep-alive comment and the second `finish_reason` chunk, both of which are the
/// things most likely to be got wrong.
enum SSEFixtures {
    /// A real two-token completion. Note the trailing chunk: it repeats `finish_reason: "stop"`
    /// and *also* carries `usage`.
    static let textStream = """
    : OPENROUTER PROCESSING

    data: {"id":"gen-1","model":"openai/gpt-4o","choices":[{"index":0,"delta":{"content":"Four","role":"assistant"},"finish_reason":null}]}

    data: {"id":"gen-1","model":"openai/gpt-4o","choices":[{"index":0,"delta":{"content":".","role":"assistant"},"finish_reason":null}]}

    data: {"id":"gen-1","model":"openai/gpt-4o","choices":[{"index":0,"delta":{"content":"","role":"assistant"},"finish_reason":"stop"}]}

    data: {"id":"gen-1","model":"openai/gpt-4o","choices":[{"index":0,"delta":{"content":"","role":"assistant"},"finish_reason":"stop"}],"usage":{"prompt_tokens":12,"completion_tokens":2,"total_tokens":14,"cost":0.00005,"prompt_tokens_details":{"cached_tokens":4}}}

    data: [DONE]

    """

    /// Tool-call arguments dribbled across frames, which is how they really arrive.
    static let toolCallStream = """
    : OPENROUTER PROCESSING

    data: {"id":"gen-2","choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"call_1","function":{"name":"get_weather","arguments":""}}]},"finish_reason":null}]}

    data: {"id":"gen-2","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"ci"}}]},"finish_reason":null}]}

    data: {"id":"gen-2","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"ty\\":\\"Gur"}}]},"finish_reason":null}]}

    data: {"id":"gen-2","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"ugram\\"}"}}]},"finish_reason":"tool_calls"}]}

    data: [DONE]

    """

    /// Truncated output, plus a frame this client does not understand.
    static let lengthStreamWithUnknownFrame = """
    data: {"choices":[{"index":0,"delta":{"content":"trunc"},"finish_reason":null}]}

    data: {"some_future_envelope_field":true}

    data: {"choices":[{"index":0,"delta":{"content":"ated"},"finish_reason":"length"}]}

    data: [DONE]

    """
}

private func streamingProvider(
    usageObserver: any UsageObserving = NullUsageObserver()
) -> OpenRouterProvider {
    OpenRouterProvider(
        configuration: OpenRouterConfiguration(apiKey: "sk-or-v1-test", streaming: true),
        session: StubURLProtocol.makeSession(),
        usageObserver: usageObserver
    )
}

private func collect(
    _ stream: AsyncThrowingStream<LLMStreamEvent, Error>
) async throws -> [LLMStreamEvent] {
    var events: [LLMStreamEvent] = []
    for try await event in stream { events.append(event) }
    return events
}

private func stubStream(_ body: String) {
    StubURLProtocol.setStub(
        .init(
            statusCode: 200,
            headers: ["Content-Type": "text/event-stream"],
            body: Data(body.utf8)
        )
    )
}

private func sampleRequest() -> LLMRequest {
    LLMRequest(messages: [LLMMessage(role: .user, content: "Count: one two three")])
}

@Suite("SSE framing")
struct SSEParserTests {
    @Test("skips the OPENROUTER PROCESSING keep-alive instead of trying to decode it")
    func skipsKeepAlive() {
        let frames = SSEParser.frames(in: SSEFixtures.textStream)
        #expect(frames.count == 5, "4 data frames plus [DONE]; the comment is not a frame")
        #expect(frames.last == .done)
        for frame in frames.dropLast() {
            guard case let .data(payload) = frame else {
                Issue.record("expected data frame")
                return
            }
            #expect(payload.hasPrefix("{"), "a keep-alive leaked into the JSON path")
        }
    }

    @Test("strips exactly one space after the colon")
    func stripsOneSpace() {
        #expect(SSEParser.frames(in: "data: {\"a\":1}\n\n") == [.data("{\"a\":1}")])
        #expect(SSEParser.frames(in: "data:{\"a\":1}\n\n") == [.data("{\"a\":1}")])
    }

    @Test("blank lines delimit events rather than being discarded")
    func blankLinesDelimit() {
        let frames = SSEParser.frames(in: "data: one\n\ndata: two\n\n")
        #expect(frames == [.data("one"), .data("two")])
    }

    @Test("concatenates multi-line data payloads per the SSE spec")
    func multiLineData() {
        #expect(SSEParser.frames(in: "data: a\ndata: b\n\n") == [.data("a\nb")])
    }

    @Test("tolerates CRLF line endings from an intermediate proxy")
    func handlesCRLF() {
        #expect(SSEParser.frames(in: "data: {\"a\":1}\r\n\r\n") == [.data("{\"a\":1}")])
    }

    @Test("emits a trailing event that arrived without its blank line")
    func trailingEventWithoutBlankLine() {
        #expect(SSEParser.frames(in: "data: {\"a\":1}") == [.data("{\"a\":1}")])
    }
}

@Suite("SSE streaming turns")
struct OpenRouterStreamingTests {
    @Test("content arrives incrementally, then one terminal completion")
    func incrementalText() async throws {
        stubStream(SSEFixtures.textStream)
        let events = try await collect(streamingProvider().stream(request: sampleRequest()))

        let deltas = events.compactMap { event -> String? in
            if case let .textDelta(text) = event { return text }
            return nil
        }
        #expect(deltas == ["Four", "."], "empty content frames must not be yielded as deltas")

        guard case let .completed(response) = events.last else {
            Issue.record("expected a terminal .completed, got \(String(describing: events.last))")
            return
        }
        #expect(response.text == "Four.")
        #expect(response.finishReason == .stop)
    }

    /// The regression this whole transport is shaped around.
    @Test("usage from the chunk AFTER finish_reason is still captured")
    func usageArrivesAfterFinishReason() async throws {
        stubStream(SSEFixtures.textStream)
        let recorder = UsageRecorder()
        _ = try await collect(
            streamingProvider(usageObserver: recorder).stream(request: sampleRequest())
        )

        let usage = try #require(await recorder.mostRecent)
        #expect(usage.promptTokens == 12)
        #expect(usage.completionTokens == 2)
        #expect(usage.cachedPromptTokens == 4)
        #expect(
            usage.reportedCostUSD == 0.00005,
            "stopping at the first finish_reason would silently zero every cost readout"
        )
    }

    @Test("tool-call argument fragments reassemble into one parsed call")
    func toolCallFragments() async throws {
        stubStream(SSEFixtures.toolCallStream)
        let events = try await collect(streamingProvider().stream(request: sampleRequest()))

        guard case let .toolCallRequested(call) = events.last else {
            Issue.record("expected .toolCallRequested, got \(String(describing: events.last))")
            return
        }
        #expect(call.id == "call_1")
        #expect(call.toolName == "get_weather", "name arrives only on the first fragment")
        #expect(
            call.arguments["city"] == .string("Gurugram"),
            "arguments split across four frames must parse only once reassembled"
        )
        let hasText = events.contains { event in
            if case .textDelta = event { return true }
            return false
        }
        #expect(!hasText, "a tool-call turn emits no text")
    }

    @Test("an unrecognised frame is skipped rather than failing the turn")
    func unknownFrameIsSurvivable() async throws {
        stubStream(SSEFixtures.lengthStreamWithUnknownFrame)
        let events = try await collect(streamingProvider().stream(request: sampleRequest()))

        guard case let .completed(response) = events.last else {
            Issue.record("expected .completed")
            return
        }
        #expect(response.text == "truncated")
        #expect(response.finishReason == .maxTokens)
    }

    @Test("the streaming request asks for event-stream and sets stream true")
    func streamingRequestShape() async throws {
        stubStream(SSEFixtures.textStream)
        _ = try await collect(streamingProvider().stream(request: sampleRequest()))

        let request = try #require(StubURLProtocol.lastRequest)
        #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")

        let body = try #require(StubURLProtocol.lastBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["stream"] as? Bool == true)
        let usage = try #require(json["usage"] as? [String: Any])
        #expect(usage["include"] as? Bool == true, "no usage flag means no cost in the stream")
    }

    @Test("a non-2xx streaming response still maps onto the gateway's error model")
    func streamingErrorMapping() async throws {
        StubURLProtocol.setStub(
            .init(
                statusCode: 429,
                headers: ["Retry-After": "12"],
                body: Data(OpenRouterTestFixtures.rateLimitedBody.utf8)
            )
        )
        do {
            _ = try await collect(streamingProvider().stream(request: sampleRequest()))
            Issue.record("expected a throw")
        } catch {
            #expect(error as? ProviderError == .rateLimited(retryAfter: .seconds(12)))
        }
    }
}

@Suite("Chunk to delta mapping")
struct StreamChunkTests {
    @Test("a chunk carrying role and content produces both deltas in order")
    func roleAndContent() throws {
        let json = #"{"choices":[{"delta":{"role":"assistant","content":"Hi"}}]}"#
        let chunk = try JSONDecoder().decode(OpenRouterStreamChunk.self, from: Data(json.utf8))
        #expect(chunk.streamDeltas == [.role("assistant"), .content("Hi")])
    }

    @Test("empty content is not emitted as a delta")
    func emptyContentSkipped() throws {
        let json = #"{"choices":[{"delta":{"content":""},"finish_reason":"stop"}]}"#
        let chunk = try JSONDecoder().decode(OpenRouterStreamChunk.self, from: Data(json.utf8))
        #expect(chunk.streamDeltas == [.finish(.stop)])
    }

    @Test("tool fragments keep their index, which is the only stable identity")
    func toolFragmentIndex() throws {
        let json = """
        {"choices":[{"delta":{"tool_calls":[
          {"index":1,"function":{"arguments":"{}"}}
        ]}}]}
        """
        let chunk = try JSONDecoder().decode(OpenRouterStreamChunk.self, from: Data(json.utf8))
        #expect(
            chunk.streamDeltas == [
                .toolCall(index: 1, id: nil, name: nil, argumentsFragment: "{}")
            ]
        )
    }
}
