import CostEstimatorKit
import Foundation
import IdempotencyKit
import ProviderGatewayKit
import QuotaGovernorKit
import RetryPolicyKit
import Testing
import TokenMeterKit
import WorkloadProfilerKit
@testable import AIChatApp

/// Collects streamed fragments from a `@Sendable` callback.
private final class FragmentCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var fragments: [String] = []

    func append(_ fragment: String) {
        lock.lock()
        defer { lock.unlock() }
        fragments.append(fragment)
    }

    func joined() -> String {
        lock.lock()
        defer { lock.unlock() }
        return fragments.joined()
    }
}

/// Assembles a `TurnExecutor` from real package instances, with the network stubbed.
///
/// Only the transport is faked. Every governor, guard, meter and estimator here is the real
/// thing, because the question these tests answer is whether the packages compose — not whether
/// my mental model of them is self-consistent.
private struct ExecutorHarness {
    let usage = UsageRecorder()
    let profiler = WorkloadProfiler()
    let governor = QuotaGovernor()
    let idempotency = IdempotencyGuard()
    let registry = PricingRegistry()
    let meter: TokenMeter
    let scopes = BudgetScopes(account: ScopeID("account"), conversation: ScopeID("conversation"))

    init() {
        self.meter = TokenMeter(registry: registry)
    }

    func registerScopes(accountMicrocents: Int? = nil) async throws {
        // A ceiling is a `Quota` on the microcents axis, not a parameter of `ScopeLimits`.
        let limits: ScopeLimits
        if let accountMicrocents {
            limits = try ScopeLimits(quota: try Quota(microcents: accountMicrocents))
        } else {
            limits = .unlimited
        }
        try await governor.register(scopes.account, limits: limits, at: 0)
        try await governor.register(scopes.conversation, under: scopes.account, at: 0)
    }

    func registerPricing() async {
        await registry.register(
            ModelPricing(inputPerMillion: 25, outputPerMillion: 100),
            for: "openai/gpt-4o"
        )
    }

    func executor(streaming: Bool = true, maxAttempts: Int = 3) -> TurnExecutor {
        TurnExecutor(
            provider: OpenRouterProvider(
                configuration: OpenRouterConfiguration(
                    apiKey: "sk-or-v1-test",
                    streaming: streaming
                ),
                session: StubURLProtocol.makeSession(),
                usageObserver: usage
            ),
            idempotency: idempotency,
            profiler: profiler,
            estimator: CostEstimator(priceBook: Self.priceBook()),
            governor: governor,
            retryPolicy: ExponentialBackoffRetryPolicy(maxAttempts: maxAttempts),
            meter: meter,
            usage: usage,
            scopes: scopes
        )
    }

    static func priceBook() -> PriceBook {
        // Force-unwrapped after `try?`: the literal is known-valid, and a price book that fails to
        // build in a harness should fail loudly rather than silently price everything at zero.
        (try? PriceBook([
            (
                CostEstimatorKit.ModelID("openai/gpt-4o"),
                try ModelPrice(
                    model: CostEstimatorKit.ModelID("openai/gpt-4o"),
                    inputPerMillion: 250_000_000,
                    outputPerMillion: 1_000_000_000
                )
            )
        ]))!
    }
}

private func sampleTurn(model: String = "openai/gpt-4o", text: String = "hello") -> PreparedTurn {
    PreparedTurn(
        modelID: model,
        messages: [
            LLMMessage(role: .system, content: "You are terse."),
            LLMMessage(role: .user, content: text)
        ],
        outboundUserText: text,
        displayUserText: text,
        sources: [],
        didCompact: false,
        estimatedInputTokens: 20
    )
}

private let successStream = """
data: {"id":"gen-1","model":"openai/gpt-4o","choices":[{"delta":{"content":"Hi"},"finish_reason":null}]}

data: {"id":"gen-1","model":"openai/gpt-4o","choices":[{"delta":{"content":" there"},"finish_reason":"stop"}],"usage":{"prompt_tokens":18,"completion_tokens":7,"cost":0.000104}}

data: [DONE]

"""

private func stubStream(_ body: String = successStream) {
    StubURLProtocol.setStub(
        .init(
            statusCode: 200,
            headers: ["Content-Type": "text/event-stream"],
            body: Data(body.utf8)
        )
    )
}

private func run(
    _ executor: TurnExecutor,
    turn: PreparedTurn = sampleTurn(),
    conversationID: String = "conv-1"
) async -> (TurnResult, PipelineTrace) {
    var trace = PipelineTrace()
    let result = await executor.execute(
        turn,
        conversationID: conversationID,
        trace: &trace,
        onDelta: { _ in }
    )
    return (result, trace)
}

@Suite("Turn executor — the paid path")
struct TurnExecutorHappyPathTests {
    @Test("a successful turn reports every stage it owns")
    func everyStageReports() async throws {
        let harness = ExecutorHarness()
        try await harness.registerScopes()
        await harness.registerPricing()
        stubStream()

        let (result, trace) = await run(harness.executor())

        guard case let .completed(completion) = result else {
            Issue.record("expected .completed, got \(result)")
            return
        }
        #expect(completion.text == "Hi there")
        #expect(completion.promptTokens == 18)
        #expect(completion.completionTokens == 7)
        #expect(completion.reportedCostUSD == 0.000104)
        #expect(completion.attempts == 1)

        let owned: [PipelineStage] = [
            .workloadProfile, .costForecast, .budgetReserve, .idempotencyGuard,
            .retryPolicy, .hedgedRequest, .modelCascade, .providerRouting, .streamAggregation, .streamRelease,
            .sessionDelivery,
            .metering, .budgetSettle
        ]
        for stage in owned {
            #expect(trace.outcome(for: stage) != nil, "\(stage.rawValue) never reported")
        }
        #expect(trace.refusal == nil)
        #expect(trace.outcome(for: .hedgedRequest) == HedgedRequestSkip.outcome)
        #expect(trace.outcome(for: .modelCascade) == ModelCascadeSkip.outcome)
        #expect(trace.outcome(for: .streamRelease)?.summary.contains("no PII") == true)
    }

    /// The check that subtask 4's pricing work actually pays off end to end.
    @Test("metered cost is non-zero once the model's price is registered")
    func meteredCostIsReal() async throws {
        let harness = ExecutorHarness()
        try await harness.registerScopes()
        await harness.registerPricing()
        stubStream()

        let (result, trace) = await run(harness.executor())
        guard case let .completed(completion) = result else {
            Issue.record("expected .completed")
            return
        }
        #expect(completion.meteredCostUSD > 0, "an unregistered price would silently read $0.00")
        #expect(trace.outcome(for: .metering)?.summary.contains("18 in / 7 out") == true)
    }

    /// What the prompt-cache audit reconciles a layout against, so it has to be the turn's own call
    /// and carry the provider's cached count through untouched.
    @Test("the completion carries the usage the provider reported for the turn's own call")
    func firstCallIsCarried() async throws {
        let harness = ExecutorHarness()
        try await harness.registerScopes()
        stubStream(
            """
            data: {"id":"gen-1","model":"openai/gpt-4o","choices":[{"delta":{"content":"Hi"},"finish_reason":"stop"}],\
            "usage":{"prompt_tokens":1500,"completion_tokens":7,"prompt_tokens_details":{"cached_tokens":1024}}}

            data: [DONE]

            """
        )

        let (result, _) = await run(harness.executor())

        guard case let .completed(completion) = result else {
            Issue.record("expected .completed, got \(result)")
            return
        }
        #expect(completion.firstCall?.promptTokens == 1500)
        #expect(completion.firstCall?.cachedPromptTokens == 1024)
        #expect(completion.firstCall?.model == "openai/gpt-4o")
    }

    @Test("streamed fragments reach the caller as they arrive")
    func deltasStream() async throws {
        let harness = ExecutorHarness()
        try await harness.registerScopes()
        stubStream()

        let collected = FragmentCollector()
        var trace = PipelineTrace()
        _ = await harness.executor().execute(
            sampleTurn(),
            conversationID: "conv-1",
            trace: &trace,
            onDelta: { fragment in collected.append(fragment) }
        )
        #expect(collected.joined() == "Hi there")
        #expect(trace.outcome(for: .streamAggregation)?.summary.contains("2 fragment") == true)
    }

    /// The bug this stage exists for: an address split across two fragments matches in neither,
    /// so screening fragments one at a time would have put it on screen.
    @Test("an email split across fragments never reaches the caller")
    func splitEmailIsHeldBack() async throws {
        let harness = ExecutorHarness()
        try await harness.registerScopes()
        stubStream(
            """
            data: {"id":"gen-1","model":"openai/gpt-4o","choices":[{"delta":{"content":"Mail jane.doe@exa"},"finish_reason":null}]}

            data: {"id":"gen-1","model":"openai/gpt-4o","choices":[{"delta":{"content":"mple.com today."},"finish_reason":"stop"}],"usage":{"prompt_tokens":18,"completion_tokens":7,"cost":0.000104}}

            data: [DONE]

            """
        )

        let collected = FragmentCollector()
        var trace = PipelineTrace()
        let result = await harness.executor().execute(
            sampleTurn(),
            conversationID: "conv-1",
            trace: &trace,
            onDelta: { fragment in collected.append(fragment) }
        )
        #expect(collected.joined() == "Mail [REDACTED:EMAIL_ADDRESS] today.")
        #expect(!collected.joined().contains("jane"))
        #expect(trace.outcome(for: .streamRelease)?.summary.contains("kept 1 PII span") == true)
        guard case let .completed(completion) = result else {
            Issue.record("expected .completed, got \(result)")
            return
        }
        #expect(completion.text.contains("jane.doe@example.com"), "the review still sees the raw answer")
    }

    /// Before three runs are on record the plan is declared, and the trace has to say so — a
    /// forecast built on a guess must never read as one built on measurement.
    @Test("the first turns use a declared plan and label it as such")
    func declaredPlanIsLabelled() async throws {
        let harness = ExecutorHarness()
        try await harness.registerScopes()
        stubStream()

        let (_, trace) = await run(harness.executor())
        #expect(trace.outcome(for: .workloadProfile)?.summary.contains("declared") == true)
    }

    @Test("a completed turn teaches the profiler, so later turns can derive a plan")
    func profilerLearns() async throws {
        let harness = ExecutorHarness()
        try await harness.registerScopes()
        let executor = harness.executor()

        for index in 1...3 {
            stubStream()
            _ = await run(executor, turn: sampleTurn(text: "question \(index)"))
        }
        let key = ProfileKey(model: WorkloadProfilerKit.ModelID("openai/gpt-4o"), taskKind: "chat")
        let count = await harness.profiler.runCount(for: key)
        #expect(count == 3, "each completed turn must be observed")

        stubStream()
        let (_, trace) = await run(executor, turn: sampleTurn(text: "question 4"))
        #expect(
            trace.outcome(for: .workloadProfile)?.summary.contains("derived from") == true,
            "with three runs on record the plan stops being a guess"
        )
    }
}

@Suite("Turn executor — refusals reach the user")
struct TurnExecutorRefusalTests {
    @Test("an exhausted budget refuses before the provider is called")
    func budgetRefusal() async throws {
        let harness = ExecutorHarness()
        try await harness.registerScopes(accountMicrocents: 1)
        stubStream()

        let (result, trace) = await run(harness.executor())

        guard case let .refused(refusal) = result else {
            Issue.record("expected a refusal, got \(result)")
            return
        }
        #expect(refusal.stage == .budgetReserve)
        #expect(refusal.recovery == .addCredit)
        #expect(refusal.recoveryTitle == "Add credit")
        #expect(!refusal.explanation.isEmpty)
        #expect(
            trace.outcome(for: .providerRouting) == nil,
            "a refused budget must not reach the network"
        )
        #expect(trace.outcome(for: .hedgedRequest) == nil, "nothing was sent, so nothing could be hedged")
        #expect(trace.outcome(for: .modelCascade) == nil, "nothing was sent, so nothing could cascade")
        #expect(trace.outcome(for: .streamRelease) == nil, "nothing was sent, so nothing streamed")
        #expect(StubURLProtocol.requestCount == 0)
    }

    @Test("a rate limit becomes a refusal carrying the server's own retry delay")
    func rateLimitRefusal() async throws {
        let harness = ExecutorHarness()
        try await harness.registerScopes()
        StubURLProtocol.respond(
            statusCode: 429,
            json: OpenRouterTestFixtures.rateLimitedBody,
            headers: ["Retry-After": "42"]
        )

        let (result, trace) = await run(harness.executor(maxAttempts: 1))

        guard case let .refused(refusal) = result else {
            Issue.record("expected a refusal, got \(result)")
            return
        }
        #expect(refusal.stage == .providerRouting)
        #expect(refusal.recovery == .retryLater(after: .seconds(42)))
        #expect(refusal.recoveryTitle == "Try again in 42s")
        #expect(trace.refusal != nil)
        #expect(trace.outcome(for: .hedgedRequest) == HedgedRequestSkip.outcome)
        #expect(trace.outcome(for: .modelCascade) == ModelCascadeSkip.outcome)
        #expect(trace.outcome(for: .streamRelease) == LiveStreamRelease.discarded)
    }

    @Test("a rejected key sends the user to Settings rather than telling them to retry")
    func unauthorizedRefusal() async throws {
        let harness = ExecutorHarness()
        try await harness.registerScopes()
        StubURLProtocol.respond(statusCode: 401, json: OpenRouterTestFixtures.unauthorizedBody)

        let (result, _) = await run(harness.executor(maxAttempts: 1))
        guard case let .refused(refusal) = result else {
            Issue.record("expected a refusal, got \(result)")
            return
        }
        #expect(refusal.recovery == .openSettings(field: "apiKey"))
        #expect(refusal.headline == "API key problem")
    }

    @Test("running out of credit is a Settings problem, not a retry problem")
    func outOfCreditRefusal() async throws {
        let harness = ExecutorHarness()
        try await harness.registerScopes()
        StubURLProtocol.respond(
            statusCode: 402,
            json: #"{"error":{"code":402,"message":"Insufficient credits"}}"#
        )

        let (result, _) = await run(harness.executor(maxAttempts: 1))
        guard case let .refused(refusal) = result else {
            Issue.record("expected a refusal")
            return
        }
        #expect(refusal.recovery == .openSettings(field: "apiKey"))
    }

    @Test("every quota error explains itself in words a user can act on")
    func quotaExplanations() {
        let scope = ScopeID("conversation")
        let cases: [QuotaError] = [
            .exhausted(scope: scope, axis: .microcents, remaining: 10, requested: 500),
            .exhausted(scope: scope, axis: .tokens, remaining: -40, requested: 100),
            .quarantined(scope),
            .fairShareExceeded(scope: scope, share: 2),
            .concurrencyExhausted(scope: scope, limit: 4)
        ]
        for error in cases {
            let text = TurnExecutor.explain(error)
            #expect(!text.isEmpty)
            #expect(!text.contains("QuotaError"), "raw case names must not reach a user: \(text)")
        }
        let arrears = TurnExecutor.explain(
            .exhausted(scope: scope, axis: .tokens, remaining: -40, requested: 100)
        )
        #expect(arrears.contains("overspent"), "arrears must read as debt, not an empty balance")
    }
}

@Suite("Turn executor — idempotency and retries")
struct TurnExecutorGuardTests {
    /// The money-losing bug this guards: a double-tapped Send billing twice.
    @Test("an identical message replays instead of being charged again")
    func duplicateReplays() async throws {
        let harness = ExecutorHarness()
        try await harness.registerScopes()
        let executor = harness.executor()

        stubStream()
        let (first, firstTrace) = await run(executor)
        guard case .completed = first else {
            Issue.record("expected the first send to complete")
            return
        }
        #expect(firstTrace.outcome(for: .idempotencyGuard)?.summary.contains("first") == true)
        let callsAfterFirst = StubURLProtocol.requestCount

        let (second, secondTrace) = await run(executor)
        guard case let .completed(completion) = second else {
            Issue.record("expected the replay to complete, got \(second)")
            return
        }
        #expect(completion.text == "Hi there")
        // A replay put no request in front of the provider, so it must not read as one to anything
        // that audits requests: the recorder holds the first turn's call and nothing newer.
        if case let .completed(original) = first {
            #expect(original.firstCall != nil)
        }
        #expect(completion.firstCall == nil)
        #expect(secondTrace.outcome(for: .idempotencyGuard)?.summary.contains("replayed") == true)
        #expect(secondTrace.outcome(for: .hedgedRequest) == HedgedRequestSkip.outcome)
        #expect(secondTrace.outcome(for: .modelCascade) == ModelCascadeSkip.outcome)
        #expect(secondTrace.outcome(for: .streamRelease) == LiveStreamRelease.replayed)
        #expect(
            StubURLProtocol.requestCount == callsAfterFirst,
            "a replay must not hit the network again"
        )
    }

    @Test("a different conversation with the same text is a different effect")
    func keysAreScopedToConversation() async throws {
        let harness = ExecutorHarness()
        try await harness.registerScopes()
        let executor = harness.executor()

        stubStream()
        _ = await run(executor, conversationID: "conv-1")

        // `setStub` clears the captured requests, so the count below is for this send alone.
        stubStream()
        let (result, trace) = await run(executor, conversationID: "conv-2")
        guard case .completed = result else {
            Issue.record("expected .completed")
            return
        }
        #expect(trace.outcome(for: .idempotencyGuard)?.summary.contains("first") == true)
        #expect(StubURLProtocol.requestCount == 1, "a new conversation must really send")
    }

    @Test("a retry hint is taken only from a rate limit, not from every failure")
    func retryHintSource() {
        let limited = ProviderError.rateLimited(retryAfter: .seconds(7))
        #expect(ProviderEffectExecutor.retryHint(for: limited) == 7)
        #expect(
            ProviderEffectExecutor.retryHint(for: ProviderError.rateLimited(retryAfter: nil)) == nil
        )
        #expect(ProviderEffectExecutor.retryHint(for: ProviderError.timeout) == nil)
        #expect(ProviderEffectExecutor.retryHint(for: URLError(.badURL)) == nil)
    }
}

@Suite("Money conversion")
struct MicrocentsTests {
    /// A money value that goes through binary floating point on the way into a ledger is the
    /// failure this ecosystem's integer discipline exists to prevent.
    @Test("USD converts to integer microcents without float drift")
    func conversion() {
        #expect(TurnExecutor.microcents(from: 0) == 0)
        #expect(TurnExecutor.microcents(from: 1) == 100_000_000)
        #expect(TurnExecutor.microcents(from: 0.000104) == 10_400)
        #expect(TurnExecutor.microcents(from: 0.0000325) == 3_250)
    }

    @Test("a fractional microcent rounds rather than truncating toward zero")
    func rounding() {
        #expect(TurnExecutor.microcents(from: 0.000000001) == 0)
        #expect(TurnExecutor.microcents(from: 0.000000006) == 1)
    }
}

// MARK: - Verify before retry

private let droppedStream = """
data: {"id":"gen-2","model":"openai/gpt-4o","choices":[{"delta":{"content":"Hi"},"finish_reason":null}]}


"""

private func sseStub(_ body: String, dropWith drop: URLError? = nil) -> StubURLProtocol.Stub {
    StubURLProtocol.Stub(
        statusCode: 200,
        headers: ["Content-Type": "text/event-stream"],
        body: Data(body.utf8),
        failAfterBody: drop
    )
}

/// Leaves a key frozen the way an in-doubt failure does.
private struct InDoubtEffect: EffectExecuting {
    func perform(_ payload: EffectPayload) async throws -> EffectResult {
        throw EffectFailure.indeterminate("crashed after sending")
    }
}

@Suite("Turn executor — verify before retry", .serialized)
struct TurnExecutorVerifiedCallTests {
    @Test("a stream that drops mid-answer is not resent, and the user is told it was billed")
    func midStreamDropIsNotResent() async throws {
        let harness = ExecutorHarness()
        try await harness.registerScopes()
        StubURLProtocol.setStubs([sseStub(droppedStream, dropWith: URLError(.networkConnectionLost)), sseStub(successStream)])

        let (result, trace) = await run(harness.executor(maxAttempts: 3))

        guard case let .refused(refusal) = result else {
            Issue.record("expected a refusal, got \(result)")
            return
        }
        #expect(refusal.stage == .verifiedCall)
        #expect(refusal.headline == "The connection dropped mid-answer")
        #expect(refusal.explanation.contains("billed separately"))
        #expect(refusal.recovery == .retryLater(after: nil))
        #expect(StubURLProtocol.requestCount == 1, "an attempt that was billed must not be resent silently")
        #expect(trace.outcome(for: .verifiedCall) == .refused(refusal))
        if case .failed? = trace.outcome(for: .providerRouting) {} else {
            Issue.record("providerRouting should record the dropped connection as a failure")
        }
    }

    @Test("Try again after a dropped answer sends a new request")
    func tryAgainAfterDropRunsAgain() async throws {
        let harness = ExecutorHarness()
        try await harness.registerScopes()
        StubURLProtocol.setStubs([sseStub(droppedStream, dropWith: URLError(.networkConnectionLost)), sseStub(successStream)])
        let executor = harness.executor(maxAttempts: 3)

        let (first, _) = await run(executor)
        let (second, _) = await run(executor)

        guard case .refused = first, case let .completed(completion) = second else {
            Issue.record("expected a refusal then a completion, got \(first) then \(second)")
            return
        }
        #expect(completion.text == "Hi there")
        #expect(StubURLProtocol.requestCount == 2)
    }

    /// The bug this stage's wiring found: a timeout froze the idempotency key, and the Try again
    /// button resent the same key into "Already sending" for a message that was not in flight.
    @Test("Try again after the retries ran out on a timeout is not a dead end")
    func tryAgainAfterTimeoutRunsAgain() async throws {
        let harness = ExecutorHarness()
        try await harness.registerScopes()
        StubURLProtocol.setStubs([StubURLProtocol.Stub(error: URLError(.timedOut)), sseStub(successStream)])
        let executor = harness.executor(maxAttempts: 1)

        let (first, firstTrace) = await run(executor)
        let (second, _) = await run(executor)

        guard case let .refused(refusal) = first else {
            Issue.record("expected the timeout to refuse, got \(first)")
            return
        }
        #expect(refusal.headline == "The model took too long")
        #expect(firstTrace.outcome(for: .verifiedCall)?.summary.contains("in doubt") == true)
        guard case let .completed(completion) = second else {
            Issue.record("Try again should send a new request, got \(second)")
            return
        }
        #expect(completion.text == "Hi there")
    }

    @Test("a timeout with nothing received is resent, and the trace says it may be billed twice")
    func emptyTimeoutIsResent() async throws {
        let harness = ExecutorHarness()
        try await harness.registerScopes()
        StubURLProtocol.setStubs([StubURLProtocol.Stub(error: URLError(.timedOut)), sseStub(successStream)])

        let (result, trace) = await run(harness.executor(maxAttempts: 3))

        guard case let .completed(completion) = result else {
            Issue.record("expected a completion, got \(result)")
            return
        }
        #expect(completion.attempts == 2)
        #expect(trace.outcome(for: .verifiedCall) == .ran(
            detail: "1 failed attempt(s) were in doubt with no response bytes to check, "
                + "so the retry policy decided; a resend may have been billed twice"
        ))
    }

    @Test("a rate limit did no work, so it is resent as before")
    func rateLimitIsHarmless() async throws {
        let harness = ExecutorHarness()
        try await harness.registerScopes()
        StubURLProtocol.setStubs([
            StubURLProtocol.Stub(
                statusCode: 429,
                headers: ["Content-Type": "application/json", "Retry-After": "0"],
                body: Data(OpenRouterTestFixtures.rateLimitedBody.utf8)
            ),
            sseStub(successStream)
        ])

        let (result, trace) = await run(harness.executor(maxAttempts: 3))

        guard case .completed = result else {
            Issue.record("expected a completion, got \(result)")
            return
        }
        #expect(trace.outcome(for: .verifiedCall) == .ran(
            detail: "1 failed attempt(s) did no work at OpenRouter; safe to resend"
        ))
    }

    @Test("a first-attempt success has nothing to verify, and a replay sent nothing")
    func successThenReplay() async throws {
        let harness = ExecutorHarness()
        try await harness.registerScopes()
        stubStream()
        let executor = harness.executor()

        let (_, firstTrace) = await run(executor)
        let (_, secondTrace) = await run(executor)

        #expect(firstTrace.outcome(for: .verifiedCall) == .noOp(reason: "no attempt failed; nothing to verify"))
        #expect(secondTrace.outcome(for: .verifiedCall) == InDoubtVerification.replayed)
    }

    @Test("a key frozen in doubt gets an honest refusal, and the next send is a new request")
    func frozenKeyRefusalIsHonest() async throws {
        let harness = ExecutorHarness()
        try await harness.registerScopes()
        let executor = harness.executor()
        let payload = EffectPayload(
            action: "chat.completion",
            fields: ["model": "openai/gpt-4o", "conversation": "conv-1"]
        )
        _ = try? await harness.idempotency.execute(
            key: IdempotencyKey("conv-1:openai/gpt-4o:\("hello".hashValue):0:0"),
            payload: payload,
            using: InDoubtEffect()
        )
        stubStream()

        let (first, firstTrace) = await run(executor)
        let (second, _) = await run(executor)

        guard case let .refused(refusal) = first else {
            Issue.record("expected the frozen key to refuse, got \(first)")
            return
        }
        #expect(refusal.headline == "An earlier send is unresolved")
        #expect(refusal.recovery == .retryLater(after: nil))
        #expect(firstTrace.outcome(for: .verifiedCall) == InDoubtVerification.notCalled)
        guard case .completed = second else {
            Issue.record("the send after the refusal should be a new request, got \(second)")
            return
        }
    }
}

