import Foundation
import ProviderGatewayKit
import StreamAggregatorKit

extension ProviderIdentifier {
    static let openRouter = ProviderIdentifier("openrouter")
}

/// Everything needed to reach OpenRouter, separated from the provider so a model switch does
/// not rebuild the transport.
struct OpenRouterConfiguration: Sendable, Equatable {
    var baseURL: URL
    var apiKey: String
    var model: String
    var siteURL: String?
    var appName: String?
    var timeout: TimeInterval

    /// Whether to request `text/event-stream`.
    ///
    /// Kept configurable rather than assumed: the buffered path is the fallback when a chosen
    /// model's upstream does not stream, and it is what the integration tests use when the
    /// assertion is about request shape rather than about incremental delivery.
    var streaming: Bool

    /// The documented production host.
    ///
    /// A malformed literal here is a programmer error, not a runtime condition, so it traps with a
    /// message that names the cause rather than force-unwrapping into an anonymous crash.
    static let productionBaseURL: URL = {
        guard let url = URL(string: "https://openrouter.ai/api/v1") else {
            preconditionFailure("the OpenRouter base URL literal is malformed")
        }
        return url
    }()

    init(
        baseURL: URL = OpenRouterConfiguration.productionBaseURL,
        apiKey: String,
        model: String = "openai/gpt-4o",
        siteURL: String? = nil,
        appName: String? = nil,
        timeout: TimeInterval = 60,
        streaming: Bool = true
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.siteURL = siteURL
        self.appName = appName
        self.timeout = timeout
        self.streaming = streaming
    }
}

/// A real `LLMProvider` backed by OpenRouter.
///
/// The gateway protocol is streaming-only — there is no non-streaming entry point to conform to
/// — so this emits a well-formed event sequence regardless of transport. In this step the
/// transport is a single buffered POST and the stream yields one `.textDelta` followed by
/// `.completed`; the SSE transport replaces the body of `send` without changing this contract,
/// which is the whole reason the seam is drawn here.
struct OpenRouterProvider: LLMProvider {
    let identifier: ProviderIdentifier
    let capabilities: ProviderCapabilities

    private let configuration: OpenRouterConfiguration
    private let session: URLSession
    private let usageObserver: any UsageObserving
    /// Read at request-build time rather than captured, so the conversation the user is actually
    /// in decides the effort. See `ReasoningEffortBox` for why this is a reference.
    private let effort: ReasoningEffortBox

    init(
        configuration: OpenRouterConfiguration,
        session: URLSession = .shared,
        usageObserver: any UsageObserving = NullUsageObserver(),
        effort: ReasoningEffortBox = ReasoningEffortBox(),
        identifier: ProviderIdentifier = .openRouter,
        capabilities: ProviderCapabilities = .openRouterDefault
    ) {
        self.configuration = configuration
        self.session = session
        self.usageObserver = usageObserver
        self.effort = effort
        self.identifier = identifier
        self.capabilities = capabilities
    }

    func stream(request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if configuration.streaming {
                        try await streamSSE(request, into: continuation)
                    } else {
                        try await sendBuffered(request, into: continuation)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Emits the terminal event for an assembled turn, shared by both transports.
    private func emitTerminal(
        _ outcome: Outcome,
        into continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation
    ) {
        switch outcome {
        case let .text(text, finishReason):
            continuation.yield(
                .completed(
                    LLMResponse(text: text, finishReason: finishReason, providerID: identifier)
                )
            )
        case let .toolCall(call):
            // Terminal for this stream. The router runs the tool and re-invokes.
            continuation.yield(.toolCallRequested(call))
        }
    }

    // MARK: - Streaming transport

    /// Consumes `text/event-stream` and republishes it as gateway events.
    ///
    /// Two things here are load-bearing and were both derived from a captured live stream rather
    /// than from documentation.
    ///
    /// **It does not stop at the first `finish_reason`.** OpenRouter sends a chunk carrying
    /// `finish_reason: "stop"`, and then *another* chunk — same finish reason — carrying `usage`.
    /// Breaking out of the loop when a finish reason first appears loses the token counts and the
    /// reported cost entirely, and the symptom is a chat that works perfectly while every cost
    /// readout silently shows zero. The loop runs until `[DONE]` or end of bytes.
    ///
    /// **Content is yielded as it arrives.** Each `.content` fragment becomes a `.textDelta`
    /// immediately, so the UI renders progressively; the folder accumulates in parallel so the
    /// terminal `.completed` carries the whole message.
    private func streamSSE(
        _ request: LLMRequest,
        into continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation
    ) async throws {
        let urlRequest = try makeURLRequest(request, stream: true)

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: urlRequest)
        } catch let error as URLError {
            throw Self.providerError(for: error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.connectionFailed("response was not HTTP")
        }
        guard (200..<300).contains(http.statusCode) else {
            // The error body is small; draining it gives a real message instead of a bare status.
            var body = Data()
            for try await byte in bytes { body.append(byte) }
            throw Self.providerError(status: http.statusCode, headers: http, body: body)
        }

        var state = StreamState()
        var lines = SSELineAccumulator()
        var finished = false

        /// Returns true when the stream is over.
        func handle(_ line: String) -> Bool {
            state.consume(line, model: configuration.model, continuation: continuation)
        }

        for try await byte in bytes {
            guard let line = lines.feed(byte) else { continue }
            if handle(line) {
                finished = true
                break
            }
        }
        // A stream that ended without a trailing blank line still has an event pending; without
        // these drains the final chunk — the one carrying usage — is silently discarded.
        if !finished {
            if let trailing = lines.drain() {
                _ = handle(trailing)
            }
            // A blank line flushes whatever the parser still holds, which is how the final
            // usage-bearing chunk gets delivered when the server closed without one.
            _ = handle("")
        }

        if let usage = state.usage {
            await usageObserver.record(usage)
        }
        emitTerminal(Self.outcome(from: state.folder.snapshot), into: continuation)
    }

    /// The mutable state one SSE stream accumulates, lifted out of `streamSSE` so that function
    /// stays readable and each concern can be reasoned about on its own.
    private struct StreamState {
        var parser = SSEParser()
        var folder = DeltaFolder()
        var usage: OpenRouterUsage?
        private let decoder = JSONDecoder()

        /// Feeds one line. Returns true when the stream has terminated.
        mutating func consume(
            _ line: String,
            model: String,
            continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation
        ) -> Bool {
            guard let frame = parser.feed(line) else { return false }
            guard case let .data(payload) = frame else { return true }  // `.done` ends it.
            guard let chunk = try? decoder.decode(
                OpenRouterStreamChunk.self,
                from: Data(payload.utf8)
            ) else {
                // A frame that is not a chunk is not fatal — OpenRouter has added envelope fields
                // before. Dropping one unknown frame beats failing a turn that is otherwise fine.
                return false
            }
            if let chunkUsage = chunk.openRouterUsage(fallbackModel: model) {
                usage = chunkUsage
            }
            for delta in chunk.streamDeltas {
                if case let .content(fragment) = delta {
                    continuation.yield(.textDelta(fragment))
                }
                _ = folder.fold(delta)
            }
            return false
        }
    }

    /// Turns an assembled streamed message into the gateway's terminal event.
    ///
    /// Tool-call arguments arrive as a JSON *string* built from many fragments, so this is where
    /// the reassembled string is finally parsed — not per fragment, which would parse incomplete
    /// JSON on every chunk.
    static func outcome(from message: AssembledMessage) -> Outcome {
        if let call = message.toolCalls.first(where: { !$0.name.isEmpty }) {
            return .toolCall(
                ToolCallRequest(
                    id: call.id ?? UUID().uuidString,
                    toolName: call.name,
                    arguments: decodeArguments(call.arguments)
                )
            )
        }
        return .text(message.content, finishReason(for: message.finishReason))
    }

    /// Maps StreamAggregatorKit's finish reason onto the gateway's smaller one.
    static func finishReason(for reason: StreamAggregatorKit.FinishReason?) -> LLMResponse.FinishReason {
        switch reason {
        case .length: return .maxTokens
        default: return .stop
        }
    }

    // MARK: - Transport

    enum Outcome: Equatable {
        case text(String, LLMResponse.FinishReason)
        case toolCall(ToolCallRequest)
    }

    /// Builds the POST both transports send. Identical apart from the `stream` flag and the
    /// `Accept` header, which is why it is one function — a drift between the two request shapes
    /// would mean the streaming path was never really testing what the buffered path sends.
    private func makeURLRequest(_ request: LLMRequest, stream: Bool) throws -> URLRequest {
        guard !configuration.apiKey.isEmpty else {
            throw ProviderError.capabilityMismatch("no OpenRouter API key is configured")
        }

        let body = OpenRouterChatRequest(
            model: configuration.model,
            messages: request.messages.map(OpenRouterChatRequest.Message.init),
            temperature: request.temperature,
            maxTokens: request.maxOutputTokens,
            stream: stream,
            tools: request.tools.isEmpty ? nil : request.tools.map(OpenRouterChatRequest.Tool.init),
            usage: .init(include: true),
            reasoning: effort.current.map { .init(effort: $0.wireValue) }
        )

        var urlRequest = URLRequest(
            url: configuration.baseURL.appendingPathComponent("chat/completions")
        )
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = configuration.timeout
        urlRequest.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(
            stream ? "text/event-stream" : "application/json",
            forHTTPHeaderField: "Accept"
        )
        // Both are optional to OpenRouter and are omitted rather than sent empty.
        if let siteURL = configuration.siteURL {
            urlRequest.setValue(siteURL, forHTTPHeaderField: "HTTP-Referer")
        }
        if let appName = configuration.appName {
            urlRequest.setValue(appName, forHTTPHeaderField: "X-Title")
        }
        urlRequest.httpBody = try JSONEncoder().encode(body)
        return urlRequest
    }

    private func sendBuffered(
        _ request: LLMRequest,
        into continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation
    ) async throws {
        let outcome = try await send(request)
        if case let .text(text, _) = outcome, !text.isEmpty {
            continuation.yield(.textDelta(text))
        }
        emitTerminal(outcome, into: continuation)
    }

    private func send(_ request: LLMRequest) async throws -> Outcome {
        let urlRequest = try makeURLRequest(request, stream: false)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let error as URLError {
            throw Self.providerError(for: error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.connectionFailed("response was not HTTP")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.providerError(status: http.statusCode, headers: http, body: data)
        }

        let decoded: OpenRouterChatResponse
        do {
            decoded = try JSONDecoder().decode(OpenRouterChatResponse.self, from: data)
        } catch {
            throw ProviderError.connectionFailed("could not decode response: \(error)")
        }

        await reportUsage(decoded)
        return try Self.outcome(from: decoded)
    }

    private func reportUsage(_ response: OpenRouterChatResponse) async {
        guard let usage = response.usage else { return }
        await usageObserver.record(
            OpenRouterUsage(
                requestID: response.id,
                model: response.model ?? configuration.model,
                promptTokens: usage.promptTokens ?? 0,
                completionTokens: usage.completionTokens ?? 0,
                cachedPromptTokens: usage.promptTokensDetails?.cachedTokens ?? 0,
                reportedCostUSD: usage.cost
            )
        )
    }
}

extension ProviderCapabilities {
    /// What OpenRouter can do as a routing target.
    ///
    /// `maxContextTokens` is deliberately conservative: OpenRouter fronts models from 8K to over
    /// a million, and the router uses this to decide whether a request can be served at all.
    /// Claiming the largest window would let it route a request that the *selected* model then
    /// rejects. The model picker narrows this per model once the catalog is loaded.
    static let openRouterDefault = ProviderCapabilities(
        supportsToolCalling: true,
        supportsStreaming: true,
        maxContextTokens: 128_000,
        costTier: .medium,
        locality: .network
    )
}
