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
            .retryPolicy, .providerRouting, .streamAggregation, .sessionDelivery,
            .metering, .budgetSettle
        ]
        for stage in owned {
            #expect(trace.outcome(for: stage) != nil, "\(stage.rawValue) never reported")
        }
        #expect(trace.refusal == nil)
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
        #expect(secondTrace.outcome(for: .idempotencyGuard)?.summary.contains("replayed") == true)
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
