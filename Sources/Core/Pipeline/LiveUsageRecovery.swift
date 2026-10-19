import Foundation
import TokenMeterKit
import UsageRecoveryKit

/// The `usageRecovery` stage's working parts: what a call that streamed and never reported its
/// usage could have cost, what the budget holds for it, and the billing lookup that settles it.
///
/// OpenRouter sends usage in a stream's last chunk. A turn the repetition guard cut, a turn the app
/// stopped reading, and a connection that dropped mid-answer all end before it, and each was still
/// billed. Before this stage `metering` said "no usage", `budgetSettle` closed the hold at zero (or
/// released it), and the month's spend never heard about the call.
///
/// The bound comes from what the provider saw (`UnmeteredCall`). The router chooses the upstream,
/// so whether it stops billing at a disconnect is unknown, and the upper bound runs to the output
/// limit. The budget settles at that upper bound now. The month's spend is told once, later: the
/// bill from `GET /generation` when it arrives, or the upper bound when it never does.
actor LiveUsageRecovery {
    /// What the budget should settle at for one turn's unmetered calls.
    struct Held: Sendable, Equatable {
        let tokens: Int
        let microcents: Int
        let detail: String
    }

    enum Decision: Sendable, Equatable {
        case held(Held)
        case skipped(String)
    }

    /// Where a resolved charge is reported: the meter for tokens, the month's spend for money.
    struct Sinks: Sendable {
        let meter: TokenMeter
        let spend: @Sendable (Int) -> Void
    }

    private let registry: PricingRegistry
    private let lookup: any GenerationLookup
    private let schedule: LookupSchedule
    private let sleeper: any Sleeping
    private var tasks: [Task<Void, Never>] = []
    /// Every resolution so far, oldest first. Read by Diagnostics-style checks and tests.
    private(set) var resolutions: [Resolution] = []

    init(
        registry: PricingRegistry,
        lookup: any GenerationLookup,
        schedule: LookupSchedule = .standard,
        sleeper: any Sleeping = TaskSleeper()
    ) {
        self.registry = registry
        self.lookup = lookup
        self.schedule = schedule
        self.sleeper = sleeper
    }

    /// Bounds every call, decides what to hold, and starts resolving them in the background.
    func hold(_ calls: [UnmeteredCall], promptTokens: Int, cutBy: String?, sinks: Sinks) async -> Decision {
        var book = PriceBook()
        for model in Set(calls.map(\.model)) {
            guard let pricing = await registry.pricing(for: model), let price = Self.price(pricing) else {
                return .skipped(
                    "\(calls.count) call(s) ended without usage, but there is no price for \(model) yet "
                        + "(the model catalogue has not loaded), so nothing could be bounded; settled at zero"
                )
            }
            book.set(price, for: model)
        }
        let recovery = UsageRecovery(
            prices: book,
            catalog: .openRouterDocumented(),
            schedule: schedule,
            sleeper: sleeper
        )
        var charges: [(ProvisionalCharge, String)] = []
        for call in calls {
            let observed = try? Self.observed(call, promptTokens: promptTokens, cutBy: cutBy)
            guard let observed, let charge = try? await recovery.open(observed) else { continue }
            charges.append((charge, call.model))
        }
        guard !charges.isEmpty else { return .skipped("no call could be described for a bound") }
        resolveLater(charges, recovery: recovery, sinks: sinks)
        return .held(Self.held(charges.map(\.0), calls: calls))
    }

    /// Waits for every background resolution started so far. For tests and orderly shutdown.
    func drain() async {
        while !tasks.isEmpty {
            let pending = tasks
            tasks.removeAll()
            for task in pending { await task.value }
        }
    }

    private func resolveLater(
        _ charges: [(ProvisionalCharge, String)],
        recovery: UsageRecovery,
        sinks: Sinks
    ) {
        let lookup = lookup
        let task = Task {
            for (charge, model) in charges {
                guard let resolution = try? await recovery.resolve(charge.id, using: lookup) else { continue }
                if case let .billed(usage, _, _, _) = resolution {
                    await sinks.meter.record(
                        TokenUsage(promptTokens: usage.inputTokens, completionTokens: usage.outputTokens),
                        for: model
                    )
                }
                if resolution.microcents > 0 { sinks.spend(resolution.microcents) }
                self.remember(resolution)
            }
        }
        tasks.append(task)
    }

    private func remember(_ resolution: Resolution) {
        resolutions.append(resolution)
    }

    static func observed(_ call: UnmeteredCall, promptTokens: Int, cutBy: String?) throws -> ObservedCall {
        // The prompt count is the app's own estimate, so it is held as a range around it.
        let estimate = max(0, promptTokens)
        return try ObservedCall(
            generationID: call.generationID.flatMap { try? GenerationID($0) },
            model: call.model,
            input: try TokenRange(lower: estimate * 3 / 4, upper: estimate * 3 / 2),
            outputText: call.receivedText,
            contentChunks: call.contentChunks,
            maxOutputTokens: call.maxOutputTokens,
            hiddenReasoningTokens: call.reasoningCeiling,
            ending: ending(call.ending, cutBy: cutBy)
        )
    }

    static func ending(_ ending: UnmeteredCall.Ending, cutBy: String?) -> StreamEnding {
        switch ending {
        case .completed: return .completedWithoutUsage
        case .stoppedReading: return .cancelled(reason: cutBy ?? "the app stopped reading")
        case .dropped: return .connectionDropped
        }
    }

    /// Dollars per million from the catalogue, as whole microcents per million.
    static func price(_ pricing: ModelPricing) -> UsageRecoveryKit.TokenPrice? {
        try? UsageRecoveryKit.TokenPrice(
            inputDollarsPerMillion: NSDecimalNumber(decimal: pricing.inputPerMillion).doubleValue,
            outputDollarsPerMillion: NSDecimalNumber(decimal: pricing.outputPerMillion).doubleValue
        )
    }

    static func held(_ charges: [ProvisionalCharge], calls: [UnmeteredCall]) -> Held {
        let tokens = charges.reduce(0) { $0 + $1.bounds.input.upper + $1.bounds.output.upper }
        let microcents = charges.reduce(0) { $0 + $1.estimateMicrocents }
        let first = charges[0]
        let lookups = charges.compactMap { $0.call.generationID?.rawValue }
        let asking = lookups.isEmpty
            ? "no generation id arrived, so the upper bound stands"
            : "asking OpenRouter for \(lookups.joined(separator: ", "))"
        return Held(
            tokens: tokens,
            microcents: microcents,
            detail: "\(charges.count) call(s) ended without usage (\(first.call.ending.label)); "
                + "held \(microcents) microcents, the upper bound of "
                + "\(first.bounds.lowerMicrocents)-\(first.bounds.upperMicrocents) "
                + "(output \(first.bounds.output) tokens, \(first.bounds.basis.label)); \(asking)"
        )
    }
}
