import CostEstimatorKit
import Foundation
import IdempotencyKit
import ProviderGatewayKit
import QuotaGovernorKit
import RetryPolicyKit
import TokenMeterKit
import WorkloadProfilerKit

/// What one executed turn produced.
enum TurnResult: Sendable {
    case completed(TurnCompletion)
    case refused(Refusal)
    case failed(message: String)
}

/// The numbers a completed turn puts in front of the user.
struct TurnCompletion: Sendable, Equatable {
    let text: String
    let providerID: String
    let promptTokens: Int
    let completionTokens: Int
    /// What OpenRouter reported charging, when it reported anything.
    let reportedCostUSD: Double?
    /// What `TokenMeterKit` priced the call at from the registered per-model rates.
    let meteredCostUSD: Decimal
    /// Attempts spent, so the UI can show "Retried 2×" rather than hiding it.
    let attempts: Int
}

/// Budget scopes this app reserves against, outermost first.
struct BudgetScopes: Sendable, Equatable {
    var account: ScopeID
    var conversation: ScopeID

    /// The path a reservation is taken against: the conversation's spend also spends the account's.
    func path() throws -> ScopePath {
        try ScopePath([account, conversation])
    }
}

/// Runs the model call and everything that has to happen around it.
///
/// Split from `PreModelPipeline` at the point where the turn stops being free. Everything before
/// this actor is local computation; everything inside it either costs money or exists to control
/// what it costs.
actor TurnExecutor {
    let provider: OpenRouterProvider
    let idempotency: IdempotencyGuard
    let profiler: WorkloadProfiler
    let estimator: CostEstimator
    /// Replaced, not mutated, when the spend ceiling changes: `QuotaGovernor` fixes a scope's
    /// limits at `register` time and offers no way to lower them afterwards, so a new ceiling
    /// means a new ledger. See `applyPendingBudget()` for when that swap is allowed to happen.
    private(set) var governor: QuotaGovernor
    let retryPolicy: ExponentialBackoffRetryPolicy
    let meter: TokenMeter
    let usage: UsageRecorder
    let scopes: BudgetScopes
    /// Nil means this conversation has no tools at all, which is a different fact from having
    /// tools the model declined to use — the trace records the two differently.
    let tools: ToolRoundTrip?
    /// How many tool calls one user message may fund before the turn is stopped. A model that
    /// never converges has already spent this much of the user's money.
    let maxToolHops: Int

    /// Generation parameters, already clamped to what `LLMRequest` will accept.
    private(set) var settings: TurnSettings

    /// The spend ceiling the current `governor` was built against.
    private(set) var budget: MonthlyBudget

    /// A ceiling the user has chosen that has not been installed yet. See `applyPendingBudget()`.
    private var pendingBudget: MonthlyBudget?

    /// Called with the integer microcents a settled turn actually cost, so the app can carry the
    /// month's running total across launches. The governor's own ledger cannot: it is in memory,
    /// and a monthly budget that resets whenever the app is killed is not a monthly budget.
    private let onSettled: @Sendable (Int) -> Void

    /// A monotonic logical clock. `QuotaGovernorKit` takes `Int` ticks and refuses to go
    /// backwards, so the app must own the counter rather than reading a wall clock — two turns
    /// completing in the same second would otherwise be indistinguishable to the ledger.
    private var tick: Int = 0

    /// The current turn's delta sink. Held for the duration of `execute` so the call phase can be
    /// its own method without threading the closure through every signature.
    var onDeltaSink: @Sendable (String) -> Void = { _ in }

    /// The current turn's tool-activity sink, held for the same reason as `onDeltaSink`.
    var onToolSink: @Sendable (ToolActivity) -> Void = { _ in }

    init(
        provider: OpenRouterProvider,
        idempotency: IdempotencyGuard,
        profiler: WorkloadProfiler,
        estimator: CostEstimator,
        governor: QuotaGovernor,
        retryPolicy: ExponentialBackoffRetryPolicy,
        meter: TokenMeter,
        usage: UsageRecorder,
        scopes: BudgetScopes,
        tools: ToolRoundTrip? = nil,
        maxToolHops: Int = 3,
        settings: TurnSettings = TurnSettings(),
        budget: MonthlyBudget = MonthlyBudget(),
        onSettled: @escaping @Sendable (Int) -> Void = { _ in }
    ) {
        self.settings = settings
        self.budget = budget
        self.onSettled = onSettled
        self.provider = provider
        self.idempotency = idempotency
        self.profiler = profiler
        self.estimator = estimator
        self.governor = governor
        self.retryPolicy = retryPolicy
        self.meter = meter
        self.usage = usage
        self.scopes = scopes
        self.tools = tools
        self.maxToolHops = max(1, maxToolHops)
    }

    func nextTick() -> Int {
        tick += 1
        return tick
    }

    func update(_ newValue: TurnSettings) {
        settings = newValue
    }

    /// Hands a settled turn's real cost to whoever is keeping the month's total. Zero is skipped
    /// rather than reported: a replayed turn and a provider that omitted `usage` both cost nothing
    /// here, and adding zero to a running total only invites a reader to think it was measured.
    func reportSpend(_ microcents: Int) {
        guard microcents > 0 else { return }
        onSettled(microcents)
    }

    /// Queues a spend ceiling. It takes effect at the top of the next turn, never immediately.
    ///
    /// Immediate would be wrong. Installing a new ledger while a reservation is open orphans that
    /// reservation — `settle` on the replacement throws `unknownReservation`, and the turn's
    /// budget stage would report a failure caused by the user touching a slider rather than by
    /// anything about the turn.
    func setBudget(_ ceiling: MonthlyBudget) {
        pendingBudget = ceiling
    }

    /// Installs a queued ceiling, if nothing is currently holding budget against the old one.
    ///
    /// Called at the start of `execute`, which is the one moment in a turn's life when the ledger
    /// is provably idle. A ceiling that arrives while a send is in flight simply waits for the
    /// send after that.
    private func applyPendingBudget() async {
        guard let pending = pendingBudget else { return }
        guard await governor.reservations().isEmpty else { return }
        guard let rebuilt = await Self.makeGovernor(scopes: scopes, budget: pending) else { return }
        governor = rebuilt
        budget = pending
        pendingBudget = nil
    }

    /// A governor with both scopes registered and the account capped at what is left this month.
    ///
    /// Returns nil rather than trapping if the limits are rejected: the caller keeps the ledger it
    /// already had, which enforces *something*, where a force-try would take the app down over a
    /// number typed into a settings field.
    static func makeGovernor(scopes: BudgetScopes, budget: MonthlyBudget) async -> QuotaGovernor? {
        let governor = QuotaGovernor()
        do {
            try await governor.register(scopes.account, limits: try budget.scopeLimits(), at: 0)
            try await governor.register(scopes.conversation, under: scopes.account, at: 0)
            return governor
        } catch {
            return nil
        }
    }

    /// Executes one prepared turn.
    ///
    /// `onDelta` is called on every streamed fragment so the UI can render progressively. It hops
    /// to the main actor at the call site rather than here, because this actor must not be blocked
    /// by view updates while a stream is open.
    func execute(
        _ turn: PreparedTurn,
        conversationID: String,
        trace: inout PipelineTrace,
        onDelta: @Sendable @escaping (String) -> Void,
        onTool: @Sendable @escaping (ToolActivity) -> Void = { _ in }
    ) async -> TurnResult {
        onDeltaSink = onDelta
        onToolSink = onTool
        defer {
            onDeltaSink = { _ in }
            onToolSink = { _ in }
        }

        // 0. A ceiling chosen since the last turn. Before the reservation, never during one.
        await applyPendingBudget()

        // 1. Idempotency — a double-tapped Send must not be charged twice. The key is derived from
        //    the conversation and the exact outbound text, so an identical re-ask replays.
        let key = IdempotencyKey(
            "\(conversationID):\(turn.modelID):\(turn.outboundUserText.hashValue)"
        )

        // 2. Workload profile — the shape of this conversation, learned from earlier turns.
        let plan = await derivePlan(for: turn, trace: &trace)

        // 3–4. Forecast, then hold budget against it. Either can refuse the turn.
        let forecast = await forecastCost(plan, trace: &trace)
        let held = await holdBudget(forecast, trace: &trace)
        if case let .refused(refusal) = held { return .refused(refusal) }
        let reservation = held.reservation

        // 5–7. The call itself, guarded so a duplicate send replays instead of re-billing.
        //
        // 8–10. Account for what happened, then teach the profiler. A `switch` rather than
        // `guard case`: `CallResult` has exactly two cases, and the `guard`-shaped version needed
        // a second `guard` returning a `.failed(message: "unreachable")` no turn could produce.
        switch await callProvider(turn, key: key, conversationID: conversationID, trace: &trace) {
        case let .stopped(result):
            await releaseIfHeld(reservation)
            return result
        case let .succeeded(body, attempts):
            return await account(
                turn: turn,
                body: body,
                attempts: attempts,
                reservation: reservation,
                trace: &trace
            )
        }
    }

    // MARK: - Workload profile

    private func derivePlan(
        for turn: PreparedTurn,
        trace: inout PipelineTrace
    ) async -> WorkloadPlan? {
        let key = ProfileKey(model: WorkloadProfilerKit.ModelID(turn.modelID), taskKind: "chat")
        do {
            let derived = try await profiler.derivePlan(for: key)
            trace.record(
                .workloadProfile,
                .ran(
                    detail: "derived from \(derived.evidence.runsProfiled) run(s), "
                        + "confidence \(derived.evidence.confidence)"
                )
            )
            let split = try derived.split(systemTokens: 0)
            return try WorkloadPlan(
                model: CostEstimatorKit.ModelID(turn.modelID),
                taskKind: "chat",
                systemTokens: split.systemTokens,
                promptTokens: max(1, split.promptTokens),
                steps: max(1, derived.steps),
                expectedOutputTokensPerStep: max(1, derived.expectedOutputTokensPerStep),
                cacheHitPercent: derived.cacheHitPercent
            )
        } catch {
            // Expected on the first few turns: three runs are not yet on record. Declared, not
            // derived — and the trace says which, so a forecast is never read as a measurement.
            trace.record(
                .workloadProfile,
                .noOp(reason: "not enough history yet; using a declared plan")
            )
            // A tool-enabled turn can make up to `maxToolHops + 1` billable calls, so the plan has
            // to be sized for that. Reserving for one call and then making four is how a budget
            // stage approves a turn the account cannot afford.
            return Self.declaredPlan(for: turn, steps: tools == nil ? 1 : maxToolHops + 1)
        }
    }

    /// The plan used before the profiler has enough history.
    ///
    /// Optional rather than falling back to a fabricated one-token plan: if `WorkloadPlan` ever
    /// refuses these values, the truthful response is "no forecast for this turn", which the
    /// caller already handles by skipping the reservation. A stand-in plan would produce a
    /// confident number describing nothing.
    static func declaredPlan(for turn: PreparedTurn, steps: Int = 1) -> WorkloadPlan? {
        try? WorkloadPlan(
            model: CostEstimatorKit.ModelID(turn.modelID),
            taskKind: "chat",
            systemTokens: 0,
            promptTokens: max(1, turn.estimatedInputTokens),
            steps: max(1, steps),
            expectedOutputTokensPerStep: 400
        )
    }

    func recordObservation(turn: PreparedTurn, prompt: Int, completion: Int) async {
        guard prompt > 0 || completion > 0 else { return }
        do {
            let step = try ObservedStep(
                ordinal: 1,
                tokens: try TokenCounts(inputTokens: prompt, outputTokens: completion)
            )
            try await profiler.ingest(
                ObservedRun(
                    runID: UUID().uuidString,
                    model: WorkloadProfilerKit.ModelID(turn.modelID),
                    taskKind: "chat",
                    steps: [step]
                )
            )
        } catch {
            // A run the profiler refuses is a run it should not learn from. Dropping it is the
            // designed behaviour, not an error worth surfacing.
        }
    }
}
