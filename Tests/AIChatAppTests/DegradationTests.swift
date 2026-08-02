import AgentMemoryKit
import ContextCompactionKit
import CostEstimatorKit
import Foundation
import GroundingKit
import GuardrailKit
import IdempotencyKit
import PromptTemplateKit
import ProviderGatewayKit
import QuotaGovernorKit
import ResponseCacheKit
import RetrievalKit
import RetryPolicyKit
import SemanticRouterKit
import Testing
import TokenMeterKit
import ToolRegistryKit
import WorkloadProfilerKit
@testable import AIChatApp

// MARK: - A transport this file owns outright

/// A stubbed transport that is not shared with any other suite.
///
/// `StubURLProtocol` is process-global, and the suites that use it take turns by being
/// `.serialized`. These tests need a response — sometimes a slow one — to stay in place for the
/// whole of a turn, so they bring their own protocol class rather than joining that queue.
final class LocalStubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Script: Sendable {
        var statusCode = 200
        var headers = ["Content-Type": "text/event-stream"]
        var body = Data()
        var error: URLError?
        /// Seconds to wait before answering, so a test can look at the screen mid-send.
        var delay: TimeInterval = 0
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var queued: [Script] = [Script()]

    /// Serves each script once, then repeats the last — a tool round trip is two requests.
    static func serve(_ scripts: [Script]) {
        lock.lock()
        defer { lock.unlock() }
        queued = scripts.isEmpty ? [Script()] : scripts
    }

    static func serve(sse: String, delay: TimeInterval = 0) {
        serve([Script(body: Data(sse.utf8), delay: delay)])
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let script = Self.queued.count > 1 ? Self.queued.removeFirst() : (Self.queued.first ?? Script())
        Self.lock.unlock()

        if script.delay > 0 {
            Thread.sleep(forTimeInterval: script.delay)
        }
        if let error = script.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: script.statusCode,
                  httpVersion: "HTTP/1.1",
                  headerFields: script.headers
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: script.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// A transport that never reaches anything. No state at all, so nothing can race it.
final class OfflineURLProtocol: URLProtocol, @unchecked Sendable {
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}

// MARK: - Embedders that fail

private struct EmbedderFailure: Error, CustomStringConvertible {
    var description: String { "the embedding model is unavailable" }
}

/// Embeds anything except a marked query.
///
/// Marked rather than always-failing because indexing and recall use the same embedder: a provider
/// that failed on every call could never get a document in to fail on the way out.
private struct FlakyEmbedder: EmbeddingProvider, MemoryEmbedder, RouteEmbedder {
    static let poison = "detonate"
    let dimension = 8

    private func vector(_ text: String) throws -> [Double] {
        guard !text.contains(Self.poison) else { throw EmbedderFailure() }
        return (0..<dimension).map { Double(text.count + $0) }
    }

    func embed(_ text: String) async throws -> RetrievalKit.Embedding {
        RetrievalKit.Embedding(vector: try vector(text))
    }

    func embed(_ text: String) async throws -> MemoryVector {
        MemoryVector(values: try vector(text))
    }

    func embed(_ text: String) async throws -> RouteVector {
        RouteVector(values: try vector(text))
    }
}

/// A compaction strategy that always refuses to run.
private struct BrokenCompaction: CompactionStrategy {
    let name = "broken"

    func compact(
        _ messages: [CompactableMessage],
        budget: Int,
        estimator: any TokenEstimating
    ) async throws -> [CompactableMessage] {
        throw EmbedderFailure()
    }
}

// MARK: - Pre-model degradation

/// Every pre-model stage answers a question the turn can survive without. A stage that broke must
/// therefore degrade — record the failure, contribute nothing, and let the turn continue — rather
/// than refuse. A refusal here would tell the user their message was rejected when what actually
/// happened is that an embedding model was down.
@Suite("Pre-model — a stage that breaks degrades rather than refusing")
struct PreModelDegradationTests {
    private func pipeline(
        settings: PipelineSettings = PipelineSettings(),
        compactor: ContextCompactor? = nil,
        router: SemanticRouter? = nil
    ) async -> PreModelPipeline {
        let prompts = PromptRegistry()
        _ = try? await prompts.register(name: "chat.system", template: "You are terse.")
        let embedder = FlakyEmbedder()
        return PreModelPipeline(
            prompts: prompts,
            guardrail: GuardrailPipeline(policy: GuardrailPolicy()),
            router: router ?? SemanticRouter(embedder: embedder),
            cache: ResponseCache(capacity: 4),
            memory: MemoryStore(embedder: embedder),
            retriever: Retriever(embedder: embedder),
            compactor: compactor ?? ContextCompactor(strategies: [SlidingWindowCompactionStrategy()]),
            settings: settings
        )
    }

    private func prepare(
        _ pipeline: PreModelPipeline,
        text: String
    ) async -> (TurnPreparation, PipelineTrace) {
        var trace = PipelineTrace()
        let result = await pipeline.prepare(userText: text, history: [], trace: &trace)
        return (result, trace)
    }

    /// A router that cannot embed the question must not decide the model anyway. Falling back to
    /// the default is the honest answer; a route chosen from a failed comparison would send the
    /// turn to a model nobody picked.
    @Test("a router whose embedder fails falls back to the default model")
    func routerFailure() async throws {
        let router = SemanticRouter(embedder: FlakyEmbedder())
        _ = try? await router.register(
            SemanticRouterKit.Route(
                name: "code",
                utterances: ["write a function"],
                metadata: ["model": "openai/gpt-4o"]
            )
        )
        let subject = await pipeline(router: router)
        let (result, trace) = await prepare(subject, text: "please \(FlakyEmbedder.poison) now")

        guard case let .ready(turn) = result else {
            Issue.record("a broken router must not stop the turn, got \(result)")
            return
        }
        #expect(turn.modelID == PipelineSettings().defaultModelID)
        #expect(trace.outcome(for: .semanticRoute)?.isFailure == true)
    }

    /// Recall is an enhancement. A memory store that cannot answer contributes nothing, and the
    /// model gets the conversation without it rather than an apology instead of an answer.
    @Test("a memory store that cannot recall contributes nothing and says so")
    func memoryFailure() async throws {
        let embedder = FlakyEmbedder()
        let memory = MemoryStore(embedder: embedder)
        try await memory.write(content: "the user prefers Swift", kind: .preference)

        let prompts = PromptRegistry()
        _ = try? await prompts.register(name: "chat.system", template: "You are terse.")
        let subject = PreModelPipeline(
            prompts: prompts,
            guardrail: GuardrailPipeline(policy: GuardrailPolicy()),
            router: SemanticRouter(),
            cache: ResponseCache(capacity: 4),
            memory: memory,
            retriever: Retriever(embedder: embedder),
            compactor: ContextCompactor(strategies: [SlidingWindowCompactionStrategy()])
        )
        let (result, trace) = await prepare(subject, text: "please \(FlakyEmbedder.poison) now")

        guard case .ready = result else {
            Issue.record("a broken memory store must not stop the turn, got \(result)")
            return
        }
        #expect(trace.outcome(for: .memoryRecall)?.isFailure == true)
    }

    @Test("a retriever that cannot embed the query injects no passages and says so")
    func retrievalFailure() async {
        let subject = await pipeline()
        let (result, trace) = await prepare(subject, text: "please \(FlakyEmbedder.poison) now")

        guard case let .ready(turn) = result else {
            Issue.record("a broken retriever must not stop the turn, got \(result)")
            return
        }
        #expect(turn.sources.isEmpty)
        #expect(trace.outcome(for: .retrieval)?.isFailure == true)
    }

    /// The one stage whose failure could change what the model is sent. Returning the uncompacted
    /// messages is deliberate: an over-long prompt gets truncated upstream, which is visible, while
    /// a silently emptied one is not.
    @Test("a compactor that throws leaves the conversation intact and records the failure")
    func compactionFailure() async {
        let subject = await pipeline(
            settings: PipelineSettings(contextWindowTokens: 8, reservedResponseTokens: 1),
            compactor: ContextCompactor(strategies: [BrokenCompaction()])
        )
        let (result, trace) = await prepare(subject, text: "a question long enough to need folding")

        guard case let .ready(turn) = result else {
            Issue.record("a broken compactor must not stop the turn, got \(result)")
            return
        }
        #expect(!turn.didCompact, "nothing was compacted, so the divider must not be shown")
        #expect(trace.outcome(for: .contextCompaction)?.isFailure == true)
    }
}

// MARK: - Post-model degradation

@Suite("Post-model — a verifier that cannot run says so")
struct GroundingFailureTests {
    /// Two chunks that carry the same id are rejected by `EvidenceSet`, and the app must not
    /// silently drop one — an answer checked against half its sources would still report a
    /// grounding percentage, and the percentage would be wrong.
    @Test("evidence the verifier rejects records a failure rather than a score")
    func duplicateSourcesFailVerification() async {
        let review = PostModelPipeline(guardrail: GuardrailPipeline(policy: GuardrailPolicy()))
        let duplicated = [
            RetrievedSource(id: "same", title: "a.md", snippet: "Paris.", relevancePercent: 90),
            RetrievedSource(id: "same", title: "b.md", snippet: "Paris.", relevancePercent: 80)
        ]
        var trace = PipelineTrace()
        let result = await review.review(
            answer: "Paris is the capital of France.",
            sources: duplicated,
            trace: &trace
        )

        #expect(trace.outcome(for: .grounding)?.isFailure == true)
        #expect(result.groundedFraction == nil, "an unrun check must not report a score")
        #expect(result.claimCount == 0)
        #expect(result.publishableText == "Paris is the capital of France.")
        #expect(result.refusal == nil, "a broken verifier is not grounds for withholding an answer")
    }
}

// MARK: - Streaming and effect edges

@Suite("Provider streaming edges", .serialized)
struct StreamTerminationTests {
    private func provider() -> OpenRouterProvider {
        OpenRouterProvider(
            configuration: OpenRouterConfiguration(apiKey: "sk-or-v1-test", streaming: true),
            session: LocalStubURLProtocol.session(),
            usageObserver: UsageRecorder()
        )
    }

    /// `[DONE]` terminates the stream where it stands. Without the early exit the loop would keep
    /// reading bytes the server has already said are the last ones.
    @Test("an explicit [DONE] frame ends the stream rather than falling out of the byte loop")
    func doneEndsTheStream() async throws {
        let stream = "data: {\"choices\":[{\"delta\":{\"content\":\"Hi\"}}]}\n\n"
            + "data: [DONE]\n\n"
            + "data: {\"choices\":[{\"delta\":{\"content\":\" ignored\"}}]}\n\n"
        LocalStubURLProtocol.serve(sse: stream)

        var text = ""
        for try await event in provider().stream(
            request: LLMRequest(messages: [LLMMessage(role: .user, content: "hi")])
        ) {
            if case let .textDelta(fragment) = event { text += fragment }
        }
        #expect(text == "Hi", "anything after [DONE] must not reach the UI")
    }
}

@Suite("Effect executor — tool calls with nothing to dispatch to", .serialized)
struct UnwiredToolTests {
    private static let toolCallStream = """
    data: {"id":"gen-1","model":"openai/gpt-4o","choices":[{"delta":{"tool_calls":[\
    {"index":0,"id":"call_1","function":{"name":"calculator","arguments":"{\\"expression\\":\\"1+1\\"}"}}]},\
    "finish_reason":"tool_calls"}]}

    data: [DONE]

    """

    private func executor(tools: ToolRoundTrip?) -> ProviderEffectExecutor {
        ProviderEffectExecutor(
            provider: OpenRouterProvider(
                configuration: OpenRouterConfiguration(apiKey: "sk-or-v1-test", streaming: true),
                session: LocalStubURLProtocol.session(),
                usageObserver: UsageRecorder()
            ),
            request: LLMRequest(
                messages: [LLMMessage(role: .user, content: "what is 1+1")],
                tools: [
                    LLMToolDefinition(
                        name: "calculator",
                        toolDescription: "evaluates arithmetic",
                        parameterSchema: ["type": .string("object")]
                    )
                ]
            ),
            retryPolicy: ExponentialBackoffRetryPolicy(maxAttempts: 1),
            onDelta: { _ in },
            tools: tools
        )
    }

    /// A model that asks for a tool when no registry is configured is not an error — it is a
    /// turn that stops where it is, with two stages recorded as skipped. Recording nothing would
    /// make an unwired package look identical to one that ran and declined.
    @Test("a tool call with no registry records both dispatch stages as skipped")
    func unwiredToolCall() async throws {
        LocalStubURLProtocol.serve(sse: Self.toolCallStream + "\n")
        let subject = executor(tools: nil)

        _ = try await subject.perform(EffectPayload(action: "chat.completion", fields: [:]))
        let records = await subject.toolRecords()

        let authority = records.first { $0.stage == .toolAuthority }
        let dispatch = records.first { $0.stage == .toolDispatch }
        #expect(authority?.outcome.summary.contains("no tool registry is configured") == true)
        #expect(dispatch?.outcome.summary.contains("no tool registry is configured") == true)
        #expect(records.contains { $0.stage == .agentLoop })
    }

    /// The chip sink has a default because most callers do not want one. It still has to be
    /// callable — a default that traps or is never invoked is a signature nobody has run.
    @Test("a dispatched tool call works with no activity sink attached")
    func defaultActivitySink() async throws {
        LocalStubURLProtocol.serve([
            .init(body: Data((Self.toolCallStream + "\n").utf8)),
            .init(
                body: Data(
                    "data: {\"choices\":[{\"delta\":{\"content\":\"That is 2.\"},\"finish_reason\":\"stop\"}]}\n\n".utf8
                )
            )
        ])
        let registry = ToolRegistryKit.ToolRegistry()
        await registry.register(DemoTools.calculator, handler: DemoTools.calculatorHandler())
        let round = ToolRoundTrip(
            registry: registry,
            gate: ToolAuthorityGate(
                capabilities: ToolAuthorityGate.readOnly(tools: [DemoTools.calculatorName])
            )
        )
        let subject = executor(tools: round)

        let result = try await subject.perform(EffectPayload(action: "chat.completion", fields: [:]))
        #expect(result.body.contains("That is 2."))
        #expect(await round.statistics().totalCalls == 1)
    }
}

// MARK: - Executor accounting edges

@Suite("Turn executor — accounting that has to survive a hostile response", .serialized)
struct ExecutorAccountingTests {
    private struct Harness {
        let usage = UsageRecorder()
        let governor = QuotaGovernor()
        let registry = PricingRegistry()
        let scopes = BudgetScopes(
            account: ScopeID("account"),
            conversation: ScopeID("conversation")
        )

        func register() async throws {
            try await governor.register(scopes.account, at: 0)
            try await governor.register(scopes.conversation, under: scopes.account, at: 0)
        }

        func executor(tools: ToolRoundTrip? = nil) -> TurnExecutor {
            TurnExecutor(
                provider: OpenRouterProvider(
                    configuration: OpenRouterConfiguration(
                        apiKey: "sk-or-v1-test",
                        streaming: true
                    ),
                    session: LocalStubURLProtocol.session(),
                    usageObserver: usage
                ),
                idempotency: IdempotencyGuard(),
                profiler: WorkloadProfiler(),
                estimator: CostEstimator(priceBook: Self.pricedBook()),
                governor: governor,
                retryPolicy: ExponentialBackoffRetryPolicy(maxAttempts: 1),
                meter: TokenMeter(registry: registry),
                usage: usage,
                scopes: scopes,
                tools: tools
            )
        }

        static func pricedBook() -> PriceBook {
            guard let price = try? ModelPrice(
                model: CostEstimatorKit.ModelID("openai/gpt-4o"),
                inputPerMillion: 250_000_000,
                outputPerMillion: 1_000_000_000
            ), let book = try? PriceBook([(CostEstimatorKit.ModelID("openai/gpt-4o"), price)]) else {
                preconditionFailure("the harness price book is a literal and must build")
            }
            return book
        }
    }

    private func turn(_ text: String = "hello") -> PreparedTurn {
        PreparedTurn(
            modelID: "openai/gpt-4o",
            messages: [LLMMessage(role: .user, content: text)],
            outboundUserText: text,
            displayUserText: text,
            sources: [],
            didCompact: false,
            estimatedInputTokens: 20
        )
    }

    /// A provider that reports a negative charge cannot be settled against — `Cost` rejects it, and
    /// rightly, because a negative settlement would hand the account budget back that it never
    /// spent. The turn still completes; the settle stage records what happened.
    @Test("a negative reported cost fails the settlement rather than crediting the ledger")
    func negativeCostFailsSettlement() async throws {
        let harness = Harness()
        try await harness.register()
        LocalStubURLProtocol.serve(
            sse: "data: {\"id\":\"g\",\"model\":\"openai/gpt-4o\",\"choices\":"
                + "[{\"delta\":{\"content\":\"Hi\"},\"finish_reason\":\"stop\"}],"
                + "\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":5,\"cost\":-0.5}}\n\n"
                + "data: [DONE]\n\n"
        )

        var trace = PipelineTrace()
        let result = await harness.executor().execute(
            turn(),
            conversationID: "conv-negative",
            trace: &trace,
            onDelta: { _ in }
        )

        guard case .completed = result else {
            Issue.record("the answer was already paid for and must still be shown, got \(result)")
            return
        }
        #expect(trace.outcome(for: .budgetReserve)?.summary.contains("held") == true)
        #expect(trace.outcome(for: .budgetSettle)?.isFailure == true)
    }

    /// A double-tapped Send while the first is still open is the case `IdempotencyGuard` exists
    /// for. The second must refuse rather than being charged, and the refusal carries no action —
    /// there is nothing for the user to do but wait.
    @Test("a second send of the same message while the first is open refuses rather than billing")
    func concurrentDuplicateRefuses() async throws {
        let harness = Harness()
        try await harness.register()
        LocalStubURLProtocol.serve(
            sse: "data: {\"id\":\"g\",\"model\":\"openai/gpt-4o\",\"choices\":"
                + "[{\"delta\":{\"content\":\"Hi\"},\"finish_reason\":\"stop\"}],"
                + "\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":5}}\n\n"
                + "data: [DONE]\n\n",
            delay: 0.4
        )
        let executor = harness.executor()

        async let first = withTrace { trace in
            await executor.execute(
                turn("duplicate"),
                conversationID: "conv-dup",
                trace: &trace,
                onDelta: { _ in }
            )
        }
        try await Task.sleep(nanoseconds: 120_000_000)
        async let second = withTrace { trace in
            await executor.execute(
                turn("duplicate"),
                conversationID: "conv-dup",
                trace: &trace,
                onDelta: { _ in }
            )
        }

        let (firstOutcome, secondOutcome) = await (first, second)
        guard case .completed = firstOutcome.0 else {
            Issue.record("the first send must land, got \(firstOutcome.0)")
            return
        }
        guard case let .refused(refusal) = secondOutcome.0 else {
            Issue.record("the duplicate must refuse, got \(secondOutcome.0)")
            return
        }
        #expect(refusal.stage == .idempotencyGuard)
        #expect(refusal.recovery == nil, "there is nothing to press while a send is in flight")
        #expect(secondOutcome.1.outcome(for: .idempotencyGuard)?.isRefusal == true)
    }

    /// The tool-activity sink has a default so that callers with no chip to draw — every test in
    /// this file, and any future headless caller — do not have to supply one.
    @Test("a tool round trip runs with no activity sink supplied")
    func toolTurnWithoutActivitySink() async throws {
        let harness = Harness()
        try await harness.register()
        LocalStubURLProtocol.serve([
            .init(
                body: Data(
                    ("data: {\"id\":\"g\",\"model\":\"openai/gpt-4o\",\"choices\":[{\"delta\":"
                        + "{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"function\":"
                        + "{\"name\":\"calculator\",\"arguments\":\"{\\\"expression\\\":\\\"6*7\\\"}\"}}]},"
                        + "\"finish_reason\":\"tool_calls\"}]}\n\ndata: [DONE]\n\n").utf8
                )
            ),
            .init(
                body: Data(
                    ("data: {\"id\":\"g\",\"model\":\"openai/gpt-4o\",\"choices\":[{\"delta\":"
                        + "{\"content\":\"42.\"},\"finish_reason\":\"stop\"}],\"usage\":"
                        + "{\"prompt_tokens\":9,\"completion_tokens\":3}}\n\ndata: [DONE]\n\n").utf8
                )
            )
        ])
        let registry = ToolRegistryKit.ToolRegistry()
        await registry.register(DemoTools.calculator, handler: DemoTools.calculatorHandler())
        let round = ToolRoundTrip(
            registry: registry,
            gate: ToolAuthorityGate(
                capabilities: ToolAuthorityGate.readOnly(tools: [DemoTools.calculatorName])
            )
        )

        var trace = PipelineTrace()
        let result = await harness.executor(tools: round).execute(
            turn("what is 6*7"),
            conversationID: "conv-tools",
            trace: &trace,
            onDelta: { _ in }
        )

        guard case let .completed(completion) = result else {
            Issue.record("expected a completed turn, got \(result)")
            return
        }
        #expect(completion.text.contains("42."))
        #expect(trace.outcome(for: .toolDispatch)?.summary.contains("ok") == true)
        #expect(await round.statistics().totalCalls == 1)
    }
}

/// Runs a body that needs an `inout` trace and hands back both halves.
///
/// `inout` cannot cross an `async let`, so the trace is created inside and returned alongside the
/// result rather than threaded in from the caller.
private func withTrace(
    _ body: (inout PipelineTrace) async -> TurnResult
) async -> (TurnResult, PipelineTrace) {
    var trace = PipelineTrace()
    let result = await body(&trace)
    return (result, trace)
}
