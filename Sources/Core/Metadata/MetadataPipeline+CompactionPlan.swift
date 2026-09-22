import CompactionPlannerKit
import Foundation

extension MetadataPipeline {
    /// The window `PreModelPipeline.compactIfNeeded` compacts against, carried to the audit.
    ///
    /// Built from `PipelineSettings` rather than from two loose integers, so the audit reads the
    /// same numbers the compactor does. The default is the settings' own default, which is what a
    /// caller that never passes a window gets from the compactor too.
    struct CompactionWindow: Sendable, Equatable {
        let contextWindowTokens: Int
        let reservedResponseTokens: Int

        init(_ settings: PipelineSettings = PipelineSettings()) {
            contextWindowTokens = settings.contextWindowTokens
            reservedResponseTokens = settings.reservedResponseTokens
        }

        /// How large the assembled prompt may grow before the compactor steps in.
        var promptTokens: Int { contextWindowTokens - reservedResponseTokens }
    }

    /// The cache the schedules are priced against: automatic prefix caching with free writes.
    ///
    /// The same choice `promptCache` makes and for the same reason: the app sends no cache
    /// markers, so a provider that needs them caches nothing here. The preset's prices are
    /// illustrative, which is why the detail reports ratios, where they cancel, and never dollars.
    static let compactionPlanTerms = CacheTerms.automaticFreeWrites

    /// The share of the app's mean history the cheaper alternative must still keep.
    static let compactionPlanKeptShare = 0.9

    /// Replays this conversation's requests under the app's own compaction schedule.
    func auditCompactionPlan(
        trace: inout PipelineTrace,
        prompts: [SentPrompt],
        window: CompactionWindow
    ) async {
        trace.record(.compactionPlan, await Self.compactionPlanOutcome(prompts, window: window))
    }

    /// What the requests this conversation sent say about the schedule that compacted them.
    ///
    /// An audit only: it changes nothing sent, and `PreModelPipeline` keeps compacting exactly as
    /// it does. The run is the one `promptCache` reads, because a cache belongs to one model.
    static func compactionPlanOutcome(
        _ prompts: [SentPrompt],
        window: CompactionWindow
    ) async -> StageOutcome {
        guard let latest = prompts.last else {
            return .skipped(reason: compactionPlanNothingSent())
        }
        let run = promptCacheRun(prompts, model: latest.modelID)
        guard run.count >= 2 else {
            return .noOp(reason: compactionPlanNothingToReplay(model: latest.modelID))
        }
        let setup: CompactionPlanSetup
        do {
            setup = try CompactionPlanSetup(run, latest: latest, window: window)
        } catch {
            return .failed(message: compactionPlanUnreplayable(error))
        }
        return await compactionPlanVerdict(setup)
    }

    /// Prices the app's schedule and the alternatives, once the run has become a trace.
    static func compactionPlanVerdict(_ setup: CompactionPlanSetup) async -> StageOutcome {
        let planner = CompactionPlanner(terms: compactionPlanTerms)
        let app = await planner.evaluate(setup.policy, on: setup.trace)
        guard app.compactions > 0 else {
            return .noOp(reason: compactionPlanNothingCompacted(setup, app: app))
        }
        let comparison = await planner.likeForLike(setup.trace, grid: setup.grid, baseline: setup.policy)
        let cheaper = await planner.recommend(
            setup.trace,
            grid: setup.grid,
            minimumMeanHistoryTokens: compactionPlanKeptShare * app.meanHistoryTokens
        )
        return .ran(
            detail: [
                compactionPlanScheduleLine(setup, app: app),
                compactionPlanLikeForLikeLine(comparison, app: app, setup: setup),
                compactionPlanCheaperLine(cheaper, app: app, setup: setup),
                compactionPlanLapsedLine(setup),
                compactionPlanScopeLine()
            ].joined(separator: "; ")
        )
    }

    // MARK: - the outcomes that price nothing

    private static func compactionPlanNothingSent() -> String {
        "no request this conversation sent has a provider-reported usage on record, so there is no "
            + "history to replay; a cache hit, a refusal and a replayed result all end a turn without one"
    }

    private static func compactionPlanNothingToReplay(model: String) -> String {
        "only one request to \(model) is on record since the model last changed, and a provider's "
            + "cache belongs to one model, so there is no compaction schedule to replay yet"
    }

    private static func compactionPlanUnreplayable(_ error: Error) -> String {
        "the requests on record could not be replayed as one conversation (\(error)); a request dated "
            + "before the one sent ahead of it, as a device clock set backwards produces, is the case "
            + "this meets"
    }

    private static func compactionPlanNothingCompacted(
        _ setup: CompactionPlanSetup,
        app: ReplayResult
    ) -> String {
        "the app's schedule, \(compactionPlanScheduleText(setup)), compacted nothing over "
            + "\(setup.trace.turns.count) requests to \(setup.model): the history peaked at about "
            + "\(app.maxHistoryTokens) tokens against a budget of \(setup.historyBudget), so there was "
            + "no compaction decision to price"
    }

    // MARK: - the detail

    private static func compactionPlanScheduleText(_ setup: CompactionPlanSetup) -> String {
        "a sliding window at \(setup.historyBudget) history tokens, \"\(setup.policy)\" (the "
            + "\(setup.window.contextWindowTokens)-token window less "
            + "\(setup.window.reservedResponseTokens) reserved for the reply and "
            + "\(setup.stablePrefixTokens) of system message)"
    }

    private static func compactionPlanScheduleLine(
        _ setup: CompactionPlanSetup,
        app: ReplayResult
    ) -> String {
        let folded = setup.folded == 0 ? "" : ", counting \(setup.folded) request(s) that added nothing "
            + "new (a retry resends the same messages) as 1 token so their timing still counts"
        return "the app's schedule, \(compactionPlanScheduleText(setup)), replayed over "
            + "\(setup.trace.turns.count) requests to \(setup.model)\(folded): \(app.compactions) "
            + "compaction(s), about \(compactionPlanTokens(app.meanHistoryTokens)) history tokens kept "
            + "on average (peak \(app.maxHistoryTokens)), \(compactionPlanPercent(app.hitRate)) of prompt "
            + "tokens read from the cache"
    }

    /// The like-for-like answer, rendered from what the planner returned rather than from what it
    /// is expected to return.
    ///
    /// Against a sliding window at the full budget the match is always the app's own schedule at
    /// 0.0%: that window keeps the longest history that fits on every request, so any cheaper
    /// drop-oldest schedule keeps less. A separate "this one is cheaper" arm could never be taken,
    /// so there is none, and the line prints the planner's match and saving as they come.
    private static func compactionPlanLikeForLikeLine(
        _ comparison: LikeForLike?,
        app: ReplayResult,
        setup: CompactionPlanSetup
    ) -> String {
        guard let comparison else {
            let over = app.requestsOver(budget: setup.historyBudget)
            return "the app's own schedule let \(over) request(s) carry more than "
                + "\(setup.historyBudget) history tokens, because one turn was larger than the budget "
                + "and a compaction always keeps the newest turn, so it is no fair like-for-like reference"
        }
        return "like for like over \(setup.grid.policies().count) drop-oldest schedules (targets down "
            + "to \(setup.grid.floor) in steps of \(setup.grid.step)), the cheapest that keeps at least "
            + "the app's mean history is \"\(comparison.match.policy)\", "
            + "\(compactionPlanPercent(comparison.savedFraction)) cheaper than the app's; a sliding "
            + "window at the full budget keeps the longest history that fits on every request, so "
            + "every cheaper schedule keeps less"
    }

    private static func compactionPlanCheaperLine(
        _ outcome: PlanningOutcome,
        app: ReplayResult,
        setup: CompactionPlanSetup
    ) -> String {
        let floor = compactionPlanTokens(compactionPlanKeptShare * app.meanHistoryTokens)
        switch outcome {
        case let .recommended(cheaper):
            let saved = (app.totalUSD - cheaper.totalUSD) / app.totalUSD
            return "giving up the last 10% of the app's kept history (keeping at least \(floor) tokens "
                + "on average), the cheapest schedule is \"\(cheaper.policy)\": about "
                + "\(compactionPlanTokens(cheaper.meanHistoryTokens)) tokens kept, "
                + "\(cheaper.compactions) compaction(s), \(compactionPlanPercent(saved)) cheaper than "
                + "the app's"
        case .infeasible:
            return "no schedule in the grid keeps every request inside \(setup.historyBudget) history "
                + "tokens, so none can be recommended at \(floor) tokens kept on average"
        }
    }

    private static func compactionPlanLapsedLine(_ setup: CompactionPlanSetup) -> String {
        let ttl = Int(compactionPlanTerms.ttlSeconds)
        return "\(setup.trace.pauses(atLeast: compactionPlanTerms.ttlSeconds)) of "
            + "\(setup.trace.turns.count - 1) gap(s) between requests were \(ttl)s or longer, so those "
            + "requests found the cache lapsed whatever the schedule"
    }

    private static func compactionPlanScopeLine() -> String {
        let terms = compactionPlanTerms
        return "prices come from the package's illustrative automatic-caching preset (free writes, "
            + "reads at \(terms.readMultiplier)x, \(Int(terms.ttlSeconds))s lifetime, "
            + "\(terms.minimumCacheableTokens)-token minimum) and cancel in a ratio, so only percentages "
            + "are reported; sizes are estimated at 4 characters a token and the latest system message "
            + "is taken as the stable prefix; advisory only: the app keeps compacting to the whole "
            + "window, because a cheaper schedule keeps less history and trading history for price is "
            + "the owner's call, not a cache optimisation to make silently"
    }

    private static func compactionPlanPercent(_ ratio: Double) -> String {
        String(format: "%.1f%%", ratio * 100)
    }

    private static func compactionPlanTokens(_ tokens: Double) -> String {
        String(format: "%.0f", tokens)
    }
}

// MARK: - the run as a trace

/// A run of sent requests, read as the conversation `CompactionPlanner` replays, with the app's own
/// schedule and the grid of alternatives it is compared with.
struct CompactionPlanSetup: Sendable {
    let model: String
    let window: MetadataPipeline.CompactionWindow
    let trace: ConversationTrace
    /// Estimated tokens of the latest request's system message, or 0 when it has none.
    let stablePrefixTokens: Int
    /// What the history may hold once the system message is inside the window. At least 1.
    let historyBudget: Int
    /// Requests that added nothing new and were counted as one token.
    let folded: Int
    /// The app's schedule in history terms: `PreModelPipeline` compacts the whole prompt to the
    /// window whenever it overflows, which is a sliding window at `historyBudget`.
    let policy: CompactionPolicy
    let grid: PlanningGrid

    /// Throws when the run cannot be a conversation. The only way a real run meets that is a
    /// request dated before the one sent ahead of it; the policy and grid are built from a budget
    /// of at least 1 and cannot themselves refuse.
    init(_ run: [SentPrompt], latest: SentPrompt, window: MetadataPipeline.CompactionWindow) throws {
        model = latest.modelID
        self.window = window
        // The first message, when it is the system message, and nothing otherwise.
        stablePrefixTokens = latest.messages.prefix(1)
            .filter { $0.role == .system }
            .reduce(0) { $0 + $1.estimatedTokens }
        historyBudget = max(1, window.promptTokens - stablePrefixTokens)
        let start = run[0].sentAt
        var previous: [SentPrompt.Message] = []
        var turns: [TurnArrival] = []
        var folded = 0
        for prompt in run {
            let added = Self.addedTokens(prompt.messages, after: previous)
            // The package refuses an arrival of zero tokens. A request that added nothing was still
            // sent, and dropping it would lose the gap that decides whether the cache had lapsed.
            folded += added == 0 ? 1 : 0
            turns.append(TurnArrival(tokens: max(1, added), time: prompt.sentAt.timeIntervalSince(start)))
            previous = prompt.messages
        }
        self.folded = folded
        trace = try ConversationTrace(stablePrefixTokens: stablePrefixTokens, turns: turns)
        policy = try CompactionPolicy.slidingWindow(budget: historyBudget)
        grid = try PlanningGrid(
            budget: historyBudget,
            floor: historyBudget / 4,
            step: max(1, historyBudget / 20)
        )
    }

    /// Estimated tokens of the non-system messages in `messages` that `previous` did not carry.
    ///
    /// Compared as a multiset on the role-tagged text, so a question asked twice counts twice and
    /// a turn the app's compactor dropped from the front of the request is not read as the
    /// conversation shrinking: the package's history grows by arrivals, and the replay does the
    /// dropping itself.
    static func addedTokens(_ messages: [SentPrompt.Message], after previous: [SentPrompt.Message]) -> Int {
        var unmatched: [String: Int] = [:]
        for message in previous where message.role != .system {
            unmatched[message.tagged, default: 0] += 1
        }
        var added = 0
        for message in messages where message.role != .system {
            let remaining = unmatched[message.tagged, default: 0]
            if remaining > 0 {
                unmatched[message.tagged] = remaining - 1
            } else {
                added += message.estimatedTokens
            }
        }
        return added
    }
}
