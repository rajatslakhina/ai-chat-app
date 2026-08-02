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

/// Collects the settled costs the executor reports, from a `@Sendable` callback.
private final class SpendRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []

    func record(_ microcents: Int) {
        lock.lock()
        defer { lock.unlock() }
        values.append(microcents)
    }

    func recorded() -> [Int] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private struct SettingsHarness {
    let usage = UsageRecorder()
    let registry = PricingRegistry()
    let spend = SpendRecorder()
    let scopes = BudgetScopes(account: ScopeID("account"), conversation: ScopeID("conversation"))

    func executor(
        settings: TurnSettings = TurnSettings(),
        budget: MonthlyBudget = MonthlyBudget()
    ) async -> TurnExecutor {
        let governor = await TurnExecutor.makeGovernor(scopes: scopes, budget: budget)
        return TurnExecutor(
            provider: OpenRouterProvider(
                configuration: OpenRouterConfiguration(apiKey: "sk-or-v1-test", streaming: false),
                session: StubURLProtocol.makeSession(),
                usageObserver: usage
            ),
            idempotency: IdempotencyGuard(),
            profiler: WorkloadProfiler(),
            estimator: CostEstimator(priceBook: Self.priceBook()),
            governor: governor ?? QuotaGovernor(),
            retryPolicy: ExponentialBackoffRetryPolicy(maxAttempts: 1),
            meter: TokenMeter(registry: registry),
            usage: usage,
            scopes: scopes,
            settings: settings,
            budget: budget,
            onSettled: { spend.record($0) }
        )
    }

    static func priceBook() -> PriceBook {
        // Force-unwrapped after `try?` for the same reason the sibling harness does: a price book
        // that failed to build here would silently price the forecast at zero, and a budget test
        // against a zero forecast asserts nothing.
        (try? PriceBook([
            (
                CostEstimatorKit.ModelID("openai/gpt-4o"),
                try CostEstimatorKit.ModelPrice(
                    model: CostEstimatorKit.ModelID("openai/gpt-4o"),
                    inputPerMillion: 250_000_000,
                    outputPerMillion: 1_000_000_000
                )
            )
        ]))!
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

private func stubSuccess() {
    StubURLProtocol.respond(json: OpenRouterTestFixtures.textResponse)
}

@Suite("Executor settings")
struct TurnExecutorSettingsTests {
    /// The end of the clamping story: whatever the slider produced has to arrive on the wire, and
    /// arrive inside the range the provider's `precondition` accepts.
    @Test("the configured temperature is what the request carries")
    func temperatureReachesTheWire() async throws {
        stubSuccess()
        let harness = SettingsHarness()
        let executor = await harness.executor(settings: TurnSettings(temperature: 1.85))
        var trace = PipelineTrace()
        _ = await executor.execute(turn(), conversationID: "c1", trace: &trace, onDelta: { _ in })

        let body = try #require(StubURLProtocol.lastBody)
        let json = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        #expect(json["temperature"] as? Double == 1.85)
        #expect(json["max_tokens"] as? Int == 1_024)
    }

    @Test("an out-of-range temperature never reaches the wire, because it never got stored")
    func clampedTemperatureReachesTheWire() async throws {
        stubSuccess()
        let harness = SettingsHarness()
        let executor = await harness.executor()
        await executor.update(TurnSettings(temperature: 42))
        var trace = PipelineTrace()
        _ = await executor.execute(turn(), conversationID: "c2", trace: &trace, onDelta: { _ in })

        let body = try #require(StubURLProtocol.lastBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["temperature"] as? Double == 2)
    }

    /// Not a cosmetic total: the governor's ledger is in memory, so without this the month's spend
    /// would reset every time the app was killed.
    @Test("a settled turn reports what it really cost")
    func reportsSettledSpend() async {
        stubSuccess()
        let harness = SettingsHarness()
        let executor = await harness.executor(budget: MonthlyBudget(ceilingUSD: 5))
        var trace = PipelineTrace()
        _ = await executor.execute(turn(), conversationID: "c3", trace: &trace, onDelta: { _ in })

        // $0.000104 reported by the fixture, in integer microcents.
        #expect(harness.spend.recorded() == [10_400])
    }

    @Test("a turn that cost nothing measurable is not added to the running total")
    func ignoresUnreportedCost() async {
        StubURLProtocol.respond(json: OpenRouterTestFixtures.responseWithoutUsage)
        let harness = SettingsHarness()
        let executor = await harness.executor()
        var trace = PipelineTrace()
        _ = await executor.execute(turn(), conversationID: "c4", trace: &trace, onDelta: { _ in })

        #expect(harness.spend.recorded().isEmpty, "adding zero only implies it was measured")
    }

    /// A ceiling arriving mid-turn would orphan an open reservation, so it waits.
    @Test("a new ceiling is not installed until the next turn starts")
    func budgetIsDeferred() async {
        stubSuccess()
        let harness = SettingsHarness()
        let executor = await harness.executor()
        await executor.setBudget(MonthlyBudget(ceilingUSD: 3))

        #expect(await executor.budget.isUnlimited, "queued, not installed")

        var trace = PipelineTrace()
        _ = await executor.execute(turn(), conversationID: "c5", trace: &trace, onDelta: { _ in })
        #expect(await executor.budget.ceilingUSD == 3)
    }

    /// The refusal has to be a refusal — the system working — with an action attached, not a
    /// failure banner saying something went wrong.
    @Test("a month already spent refuses the next turn with a way out")
    func exhaustedMonthRefuses() async {
        stubSuccess()
        let harness = SettingsHarness()
        let executor = await harness.executor()
        // A ceiling of one cent, of which the month has already consumed all of it.
        await executor.setBudget(
            MonthlyBudget(ceilingUSD: 0.01, spentMicrocents: 1_000_000, month: "2026-07")
        )

        var trace = PipelineTrace()
        let result = await executor.execute(
            turn(),
            conversationID: "c6",
            trace: &trace,
            onDelta: { _ in }
        )

        guard case let .refused(refusal) = result else {
            Issue.record("expected a refusal, got \(result)")
            return
        }
        #expect(refusal.stage == .budgetReserve)
        #expect(refusal.recovery == .addCredit)
        #expect(refusal.recoveryTitle == "Add credit")
        #expect(trace.outcome(for: .budgetReserve)?.isRefusal == true)
        #expect(harness.spend.recorded().isEmpty, "a refused turn spends nothing")
    }

    @Test("an unlimited ceiling reserves and settles without refusing")
    func unlimitedRuns() async {
        stubSuccess()
        let harness = SettingsHarness()
        let executor = await harness.executor(budget: MonthlyBudget())
        var trace = PipelineTrace()
        let result = await executor.execute(
            turn(),
            conversationID: "c7",
            trace: &trace,
            onDelta: { _ in }
        )

        guard case .completed = result else {
            Issue.record("expected completion, got \(result)")
            return
        }
        #expect(trace.refusal == nil)
    }

    @Test("makeGovernor registers both scopes so a reservation on the path resolves")
    func governorRegistersThePath() async throws {
        let scopes = BudgetScopes(account: ScopeID("a"), conversation: ScopeID("c"))
        let governor = try #require(
            await TurnExecutor.makeGovernor(scopes: scopes, budget: MonthlyBudget(ceilingUSD: 1))
        )
        let held = try await governor.reserve(
            try QuotaGovernorKit.Cost(tokens: 10, microcents: 10),
            for: try scopes.path(),
            at: 1
        )
        #expect(held.held.microcents >= 10)
        let snapshot = try await governor.snapshot(of: scopes.account)
        #expect(snapshot.quota.microcents == 100_000_000)
    }
}
