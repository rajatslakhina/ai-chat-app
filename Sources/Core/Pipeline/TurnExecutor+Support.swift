import CostEstimatorKit
import Foundation
import IdempotencyKit
import ProviderGatewayKit
import QuotaGovernorKit
import RetryPolicyKit
import TokenMeterKit

extension TurnExecutor {
    /// What the guarded provider call produced.
    enum CallResult {
        case succeeded(body: String, attempts: Int)
        /// The turn ended here — either refused or failed. The value is what to return.
        case stopped(TurnResult)
    }

    /// Makes the model call inside the idempotency guard, under the retry policy.
    ///
    /// The tool round trip happens inside the same effect: a turn that called a tool and then
    /// answered is one billable unit of work as far as a double-tapped Send is concerned, and
    /// splitting it would let a replay re-run the tool.
    func callProvider(
        _ turn: PreparedTurn,
        key: IdempotencyKey,
        conversationID: String,
        trace: inout PipelineTrace
    ) async -> CallResult {
        let executor = await makeEffectExecutor(turn, conversationID: conversationID)
        let outcome: EffectOutcome
        do {
            outcome = try await idempotency.execute(
                key: key,
                payload: EffectPayload(
                    action: "chat.completion",
                    fields: ["model": turn.modelID, "conversation": conversationID]
                ),
                now: nextTick(),
                using: executor
            )
        } catch let error as IdempotencyError {
            let refusal = Self.refusal(for: error)
            trace.record(.idempotencyGuard, .refused(refusal))
            return .stopped(.refused(refusal))
        } catch {
            // The guard replaced the executor's error with its own, so ask the executor what
            // really went wrong rather than reporting "indeterminate effect" to a user.
            if let providerError = await executor.providerFailure() {
                let refusal = Self.refusal(for: providerError)
                trace.record(.providerRouting, .refused(refusal))
                return .stopped(.refused(refusal))
            }
            return .stopped(failed(error, trace: &trace))
        }

        let attempts = await executor.attemptsMade()
        await recordCallStages(
            executor,
            turn: turn,
            outcome: outcome,
            attempts: attempts,
            trace: &trace
        )
        return .succeeded(body: outcome.result.body, attempts: attempts)
    }

    private func makeEffectExecutor(
        _ turn: PreparedTurn,
        conversationID: String
    ) async -> ProviderEffectExecutor {
        ProviderEffectExecutor(
            provider: provider,
            request: await request(from: turn),
            retryPolicy: retryPolicy,
            onDelta: onDeltaSink,
            tools: tools,
            context: ToolCallContext.forTurn(
                conversationID: conversationID,
                sources: turn.sources
            ),
            onToolActivity: onToolSink,
            maxToolHops: maxToolHops
        )
    }

    private func recordCallStages(
        _ executor: ProviderEffectExecutor,
        turn: PreparedTurn,
        outcome: EffectOutcome,
        attempts: Int,
        trace: inout PipelineTrace
    ) async {
        var replayed = false
        switch outcome {
        case .executed:
            trace.record(.idempotencyGuard, .ran(detail: "first execution under this key"))
        case .replayed:
            replayed = true
            trace.record(
                .idempotencyGuard,
                .ran(detail: "replayed an earlier result — not charged again")
            )
        }
        trace.record(
            .retryPolicy,
            attempts > 1
                ? .ran(detail: "succeeded on attempt \(attempts)")
                : .noOp(reason: "first attempt succeeded")
        )
        let deltaCount = await executor.deltaCount()
        trace.record(.providerRouting, .ran(detail: "answered by \(turn.modelID)"))
        trace.record(.streamAggregation, .ran(detail: "\(deltaCount) fragment(s) assembled"))
        trace.record(.sessionDelivery, .ran(detail: "delivered and acknowledged"))

        let toolRecords = await executor.toolRecords()
        let recorded = toolRecords.isEmpty && replayed
            ? ProviderEffectExecutor.replayedRecords()
            : toolRecords
        for record in recorded {
            trace.record(record.stage, record.outcome, durationMs: record.durationMs)
        }
    }

    /// The outcome of trying to hold budget: a hold, no hold, or a refusal that stops the turn.
    enum BudgetHold {
        case held(Reservation)
        case none(reason: String)
        case refused(Refusal)

        var reservation: Reservation? {
            if case let .held(reservation) = self { return reservation }
            return nil
        }
    }

    /// What this turn is expected to cost, before it happens.
    func forecastCost(_ plan: WorkloadPlan?, trace: inout PipelineTrace) async -> CostForecast? {
        guard let plan else {
            trace.record(.costForecast, .skipped(reason: "no plan could be built for this turn"))
            return nil
        }
        do {
            let value = try await estimator.forecast(plan)
            trace.record(
                .costForecast,
                .ran(
                    detail: "\(value.tokens) · band ±\(value.spreadPercent)% "
                        + "· flat estimate would say \(value.naiveTokens)"
                )
            )
            return value
        } catch {
            trace.record(.costForecast, .failed(message: "\(error)"))
            return nil
        }
    }

    /// The first place the turn can be refused for money reasons.
    func holdBudget(_ forecast: CostForecast?, trace: inout PipelineTrace) async -> BudgetHold {
        guard let forecast else {
            trace.record(.budgetReserve, .skipped(reason: "no forecast to reserve against"))
            return .none(reason: "no forecast")
        }
        do {
            let hold = try QuotaGovernorKit.Cost(
                tokens: forecast.expected.tokens,
                microcents: forecast.expected.microcents
            )
            let reservation = try await governor.reserve(
                hold,
                for: scopes.path(),
                at: nextTick()
            )
            trace.record(.budgetReserve, .ran(detail: "held \(hold)"))
            return .held(reservation)
        } catch let error as QuotaError {
            let refusal = Refusal(
                stage: .budgetReserve,
                headline: "Out of budget",
                explanation: Self.explain(error),
                recovery: .addCredit
            )
            trace.record(.budgetReserve, .refused(refusal))
            return .refused(refusal)
        } catch {
            trace.record(.budgetReserve, .failed(message: "\(error)"))
            return .none(reason: "\(error)")
        }
    }

    /// Meters the real usage, settles the hold against it, and teaches the profiler.
    func account(
        turn: PreparedTurn,
        body: String,
        attempts: Int,
        reservation: Reservation?,
        trace: inout PipelineTrace
    ) async -> TurnResult {
        let recorded = await usage.mostRecent
        let promptTokens = recorded?.promptTokens ?? 0
        let completionTokens = recorded?.completionTokens ?? 0

        if let recorded {
            await meter.record(
                TokenMeterKit.TokenUsage(
                    promptTokens: recorded.promptTokens,
                    completionTokens: recorded.completionTokens
                ),
                for: recorded.model
            )
            trace.record(
                .metering,
                .ran(detail: "\(recorded.promptTokens) in / \(recorded.completionTokens) out")
            )
        } else {
            // Not a failure of ours: some upstreams omit the usage envelope entirely.
            trace.record(.metering, .noOp(reason: "the provider reported no usage for this call"))
        }
        let metered = await meter.cost(for: recorded?.model ?? turn.modelID)

        await settle(
            reservation,
            tokens: promptTokens + completionTokens,
            microcents: Self.microcents(from: recorded?.reportedCostUSD ?? 0),
            trace: &trace
        )
        await recordObservation(turn: turn, prompt: promptTokens, completion: completionTokens)

        return .completed(
            TurnCompletion(
                text: body,
                providerID: ProviderIdentifier.openRouter.rawValue,
                promptTokens: promptTokens,
                completionTokens: completionTokens,
                reportedCostUSD: recorded?.reportedCostUSD,
                meteredCostUSD: metered,
                attempts: attempts
            )
        )
    }
    /// Closes the hold against what the turn really cost, and reports that cost onwards.
    ///
    /// The report happens whether or not anything was held, because an uncapped turn still spends
    /// money and the month's total has to include it — the governor's ledger does not survive a
    /// relaunch, so it cannot be the thing that remembers.
    private func settle(
        _ reservation: Reservation?,
        tokens: Int,
        microcents: Int,
        trace: inout PipelineTrace
    ) async {
        defer { reportSpend(microcents) }
        guard let reservation else {
            trace.record(.budgetSettle, .skipped(reason: "nothing was reserved"))
            return
        }
        do {
            let actual = try QuotaGovernorKit.Cost(tokens: tokens, microcents: microcents)
            let settlement = try await governor.settle(
                reservation.id,
                actual: actual,
                at: nextTick()
            )
            trace.record(.budgetSettle, .ran(detail: "\(settlement)"))
        } catch {
            trace.record(.budgetSettle, .failed(message: "\(error)"))
        }
    }

    func releaseIfHeld(_ reservation: Reservation?) async {
        guard let reservation else { return }
        try? await governor.release(reservation.id, at: nextTick())
    }

    func failed(_ error: Error, trace: inout PipelineTrace) -> TurnResult {
        if let providerError = error as? ProviderError {
            let refusal = Self.refusal(for: providerError)
            trace.record(.providerRouting, .refused(refusal))
            return .refused(refusal)
        }
        trace.record(.providerRouting, .failed(message: "\(error)"))
        return .failed(message: "\(error)")
    }

    /// The request one turn goes out as, carrying whatever tools are registered.
    ///
    /// The tools list comes from `ToolRegistryKit`'s own catalogue rather than a second hand-kept
    /// list, translated on the way out — the registry's `Codable` form is not the OpenRouter tool
    /// shape and sending it raw is a 400.
    /// `TurnSettings` clamps both parameters in its own initializer, so the two `precondition`s
    /// inside `LLMRequest.init` — which trap in release — cannot be reached from the slider.
    func request(from turn: PreparedTurn) async -> LLMRequest {
        LLMRequest(
            messages: turn.messages,
            tools: await tools?.wireTools() ?? [],
            maxOutputTokens: settings.maxOutputTokens,
            temperature: settings.temperature
        )
    }

    /// USD to integer microcents (1e-8 of a dollar), via `Decimal` so no binary float touches a
    /// money value on the way into the ledger.
    static func microcents(from usd: Double) -> Int {
        let scaled = Decimal(usd) * Decimal(100_000_000)
        var rounded = Decimal()
        var input = scaled
        NSDecimalRound(&rounded, &input, 0, .plain)
        return NSDecimalNumber(decimal: rounded).intValue
    }

    static func explain(_ error: QuotaError) -> String {
        switch error {
        case let .exhausted(scope, axis, remaining, requested):
            // A negative remainder is not a rounding artefact: the scope is in arrears from an
            // earlier overrun, and saying "0 left" would hide that it owes.
            if remaining < 0 {
                return "\(scope) overspent an earlier request by \(-remaining) \(axis) "
                    + "and is paused until it is topped up."
            }
            return "\(scope) has \(remaining) \(axis) left and this message needs \(requested)."
        case let .quarantined(scope):
            return "\(scope) is paused after an earlier overrun."
        case let .fairShareExceeded(scope, share):
            return "\(scope) already has its share of \(share) requests in flight."
        case let .concurrencyExhausted(scope, limit):
            return "\(scope) is at its limit of \(limit) requests in flight."
        default:
            return "\(error)"
        }
    }

    static func refusal(for error: ProviderError) -> Refusal {
        switch error {
        case let .rateLimited(retryAfter):
            return Refusal(
                stage: .providerRouting,
                headline: "Too many requests",
                explanation: "OpenRouter asked us to slow down.",
                recovery: .retryLater(after: retryAfter)
            )
        case .timeout:
            return Refusal(
                stage: .providerRouting,
                headline: "The model took too long",
                explanation: "The request timed out before an answer arrived.",
                recovery: .retryLater(after: nil)
            )
        case let .capabilityMismatch(message):
            let needsKey = message.contains("API key") || message.contains("credit")
            return Refusal(
                stage: .providerRouting,
                headline: needsKey ? "API key problem" : "This model can't handle that",
                explanation: message,
                recovery: needsKey ? .openSettings(field: "apiKey") : .switchModel
            )
        case let .connectionFailed(message):
            return Refusal(
                stage: .providerRouting,
                headline: "Couldn't reach OpenRouter",
                explanation: message,
                recovery: .retryLater(after: nil)
            )
        }
    }

    static func refusal(for error: IdempotencyError) -> Refusal {
        Refusal(
            stage: .idempotencyGuard,
            headline: "Already sending",
            explanation: "This exact message is still in flight; it will not be sent twice.",
            recovery: nil
        )
    }
}
