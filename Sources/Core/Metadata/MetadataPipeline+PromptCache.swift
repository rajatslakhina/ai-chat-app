import Foundation
import PromptCacheKit

extension MetadataPipeline {
    /// The contract the layout is judged against: a provider that caches a matching prefix on its
    /// own and charges nothing extra to write it.
    ///
    /// The app sends no cache markers, so a provider that needs them cannot cache anything here and
    /// a two-tier explicit policy would describe a mechanism this app never engages. The preset is
    /// an illustrative shape, not a term any OpenRouter model has promised, and the detail line says
    /// which numbers came from it.
    static let promptCachePolicy = CachePolicy.freeWritesSingleTier

    /// How far a provider's cached-token count may sit from the prediction before it counts as a
    /// disagreement. Providers cache in blocks rather than at an arbitrary token, and the layout's
    /// prefix lengths are scaled from an estimate, so an exact match would be a coincidence.
    static let promptCacheToleranceTokens = 128

    /// The id the system message carries in every audited layout, and the one the detail explains.
    static let promptCacheSystemID = "system message"

    /// Audits whether this conversation's own layout would let a provider's prefix cache work.
    func auditPromptCache(trace: inout PipelineTrace, prompts: [SentPrompt]) {
        trace.record(.promptCache, Self.promptCacheOutcome(prompts))
    }

    /// What the requests this conversation sent say about the prefix a provider could have matched.
    ///
    /// The layout half needs nothing but the requests. The reconciliation half checks the layout's
    /// prediction against the cached-token count the provider reported for each request, and is
    /// only as good as that count: OpenRouter reports it as `prompt_tokens_details.cached_tokens`,
    /// which `OpenRouterUsage` stores as `0` when the field is absent, so a genuine zero and an
    /// omitted field cannot be told apart and the detail names the case rather than blaming the
    /// layout for it.
    static func promptCacheOutcome(_ prompts: [SentPrompt]) -> StageOutcome {
        guard let latest = prompts.last else {
            return .skipped(reason: promptCacheNothingSent())
        }
        let run = promptCacheRun(prompts, model: latest.modelID)
        guard run.count >= 2 else {
            return .noOp(reason: promptCacheNothingToCompare(sent: prompts.count, model: latest.modelID))
        }
        let layouts = run.map(promptCacheAssemble)
        let policy = promptCachePolicy
        // A cache read can only be as long as the earlier prompt, so the newest prompt's size is
        // irrelevant to whether anything *could* have been cached.
        let largest = layouts.dropLast().reduce(0) { max($0, $1.totalTokens) }
        guard largest >= policy.minimumCacheableTokens else {
            return .noOp(
                reason: promptCacheBelowMinimum(
                    largest: largest,
                    requests: run.count,
                    minimum: policy.minimumCacheableTokens
                )
            )
        }
        let report = PrefixStabilityAuditor().audit(layouts)
        let checked = promptCacheReconcile(run, layouts: layouts, report: report, policy: policy)
        return .ran(
            detail: [
                promptCacheLayoutLine(model: latest.modelID, largest: largest, report: report),
                promptCacheVerdictLine(report),
                promptCacheReconcileLine(checked),
                promptCacheScopeLine(policy)
            ].joined(separator: "; ")
        )
    }

    // MARK: - the layout

    /// The trailing run of requests to the latest request's model, oldest first and at most one
    /// window long. A provider's cache belongs to one model, so a request before a model switch
    /// cannot have warmed anything for the ones after it.
    static func promptCacheRun(_ prompts: [SentPrompt], model: String) -> [SentPrompt] {
        Array(
            prompts.reversed()
                .prefix { $0.modelID == model }
                .prefix(SentPrompt.window)
                .reversed()
        )
    }

    /// One request in the shape the package audits, as sent and not tidied.
    ///
    /// The system message is declared `frozen`, the newest user message `ephemeral` and everything
    /// between `turn`, which is what each is meant to be. Declaring the system message `frozen`
    /// when it is rebuilt every turn is the point rather than a mistake: it is the audit that
    /// reports a message that keeps changing after being declared stable. The layout is never
    /// canonicalised, because canonicalising would report the order the package prefers and not the
    /// order the app used. By construction it holds no `hazard` — the system message is first and
    /// the newest message last — so hazards are not reported.
    static func promptCacheAssemble(_ prompt: SentPrompt) -> AssembledPrompt {
        let last = prompt.messages.count - 1
        return AssembledPrompt(
            segments: prompt.messages.enumerated().map { index, message in
                let volatility = promptCacheVolatility(message, index: index, last: last)
                return PromptSegment(
                    id: volatility == .frozen ? promptCacheSystemID : "message \(index)",
                    content: message.tagged,
                    volatility: volatility,
                    tokens: message.estimatedTokens
                )
            }
        )
    }

    private static func promptCacheVolatility(
        _ message: SentPrompt.Message,
        index: Int,
        last: Int
    ) -> Volatility {
        if index == 0 && message.role == .system { return .frozen }
        return index == last && message.role == .user ? .ephemeral : .turn
    }

    // MARK: - the outcomes

    private static func promptCacheNothingSent() -> String {
        "no request this conversation sent has a provider-reported usage on record, so there is no "
            + "prompt to audit; a cache hit, a refusal and a replayed result all end a turn without "
            + "one, and none of them is a prompt a provider could have cached"
    }

    private static func promptCacheNothingToCompare(sent: Int, model: String) -> String {
        "only one request to \(model) is on record in this conversation "
            + (sent > 1 ? "since the model last changed, and a provider's cache belongs to one model"
                : "this session, so there is no second prompt to compare its prefix with")
    }

    private static func promptCacheBelowMinimum(largest: Int, requests: Int, minimum: Int) -> String {
        "the largest earlier prompt among \(requests) requests is about \(largest) tokens, estimated "
            + "at 4 characters a token, under the \(minimum) a provider starts caching at, so no "
            + "layout could have produced a cache read yet"
    }

    // MARK: - the detail

    private static func promptCacheLayoutLine(
        model: String,
        largest: Int,
        report: StabilityReport
    ) -> String {
        let healthy = report.transitions.filter(\.isHealthy).count
        return "\(report.transitions.count + 1) requests to \(model) audited, the largest earlier "
            + "prompt about \(largest) tokens (estimated at 4 characters a token): \(healthy) of "
            + "\(report.transitions.count) transition(s) left every cacheable token of the previous "
            + "prompt matchable, and on average \(promptCachePercent(report.retainedRatio)) of the "
            + "previous prompt's tokens stayed matchable"
    }

    private static func promptCacheVerdictLine(_ report: StabilityReport) -> String {
        guard let first = report.transitions.first(where: { !$0.isHealthy }) else {
            return "every change was an append behind an unchanged prefix, so a provider that "
                + "caches automatically was offered a stable prefix on every turn"
        }
        let broken = report.transitions.filter { !$0.isHealthy }.count
        let head = "the prefix first broke on request \(first.turn): "
            + "\(promptCacheBreakText(first.kind)), leaving \(first.retainedTokens) tokens "
            + "matchable and invalidating \(first.invalidatedTokens); it broke on \(broken) of "
            + "\(report.transitions.count) transition(s)"
        guard let worst = report.churn.first else { return head }
        let cause = worst.id == promptCacheSystemID
            ? " (the app builds that message from its instructions plus any remembered facts and "
                + "retrieved excerpts, so a change in either rewrites everything behind it)"
            : ""
        return head + ", and \(worst.id), declared \(worst.declared), changed on \(worst.changes) of "
            + "\(report.transitions.count)" + cause
    }

    /// How one break reads. Total over `DivergenceKind` so a new package case cannot fall through.
    static func promptCacheBreakText(_ kind: DivergenceKind) -> String {
        switch kind {
        case .identical, .appendOnly: return "the previous prompt was kept whole"
        case let .mutated(id, _): return "\(id) changed"
        case let .reordered(id): return "\(id) moved"
        case let .inserted(id): return "\(id) appeared"
        case let .removed(id): return "\(id) was dropped"
        }
    }

    private static func promptCacheReconcileLine(_ tally: PromptCacheReconciliation) -> String {
        guard tally.compared > 0 else {
            return "no request carried a provider-reported prompt size, so the layout's prediction "
                + "was not checked against what the provider cached"
        }
        return "against the provider's own cached-token counts on \(tally.compared) transition(s), "
            + "\(tally.agreed) agreed with the layout, \(tally.readLess) cached less, "
            + "\(tally.readMore) cached more, and \(tally.silent) reported none where the layout "
            + "allowed a hit, which a provider that does not cache, or omits the count, also produces"
    }

    private static func promptCacheScopeLine(_ policy: CachePolicy) -> String {
        "predictions use the package's automatic-caching preset (\(policy.minimumCacheableTokens)-token "
            + "minimum, \(Int(policy.tiers[0].ttlSeconds))s lifetime), scaled to the provider's own "
            + "prompt size; the app sets no cache markers, so this reports the layout and changes "
            + "nothing sent, and tool definitions and other conversations' requests are not counted"
    }

    private static func promptCachePercent(_ ratio: Double) -> String {
        String(format: "%.1f%%", ratio * 100)
    }
}

// MARK: - reconciliation

/// How the layout's prediction compared with what the provider reported, over a run of requests.
struct PromptCacheReconciliation: Sendable, Equatable {
    /// Transitions whose later request had a provider-reported prompt size to scale against.
    var compared = 0
    var agreed = 0
    var readLess = 0
    var readMore = 0
    /// The provider reported nothing cached where the layout allowed a hit.
    var silent = 0

    enum Verdict: Sendable, Equatable {
        case agreed, readLess, readMore, silent
    }

    mutating func record(_ verdict: Verdict) {
        compared += 1
        switch verdict {
        case .agreed: agreed += 1
        case .readLess: readLess += 1
        case .readMore: readMore += 1
        case .silent: silent += 1
        }
    }
}

extension MetadataPipeline {
    /// Checks each transition's predicted read against the cached tokens the provider reported for
    /// the later request.
    static func promptCacheReconcile(
        _ run: [SentPrompt],
        layouts: [AssembledPrompt],
        report: StabilityReport,
        policy: CachePolicy
    ) -> PromptCacheReconciliation {
        var tally = PromptCacheReconciliation()
        for (index, transition) in report.transitions.enumerated() {
            let later = run[index + 1]
            guard later.usage.promptTokens > 0 else { continue }
            let predicted = promptCachePredictedRead(
                retained: transition.retainedTokens,
                estimatedTotal: layouts[index + 1].totalTokens,
                providerTotal: later.usage.promptTokens,
                gap: later.sentAt.timeIntervalSince(run[index].sentAt),
                policy: policy
            )
            tally.record(promptCacheVerdict(predicted: predicted, usage: later.usage))
        }
        return tally
    }

    /// The tokens the layout says a provider should have read, in the provider's own units.
    ///
    /// The retained prefix is counted in estimated tokens and the provider counts its own, so it is
    /// scaled by the ratio of the later request's reported prompt size to its estimated size. Below
    /// the policy's minimum nothing is cacheable, and past its lifetime the earlier request's entry
    /// has lapsed — both predict a read of zero rather than a read the provider could not give.
    static func promptCachePredictedRead(
        retained: Int,
        estimatedTotal: Int,
        providerTotal: Int,
        gap: TimeInterval,
        policy: CachePolicy
    ) -> Int {
        let ratio = Double(providerTotal) / Double(max(1, estimatedTotal))
        let scaled = Int((Double(retained) * ratio).rounded())
        let lapsed = gap > policy.tiers[0].ttlSeconds
        return scaled >= policy.minimumCacheableTokens && !lapsed ? scaled : 0
    }

    static func promptCacheVerdict(
        predicted: Int,
        usage: OpenRouterUsage
    ) -> PromptCacheReconciliation.Verdict {
        let tolerance = promptCacheToleranceTokens
        // Split off before the package sees it: `0` is what `OpenRouterUsage` stores both for a
        // provider that cached nothing and for one that omitted the field, so calling it "the
        // provider read less" would put a claim in the detail the data cannot support.
        if usage.cachedPromptTokens == 0, predicted > tolerance { return .silent }
        let outcome = CacheOutcome(
            totalTokens: usage.promptTokens,
            readTokens: predicted,
            writtenTokens: [0],
            uncachedTokens: usage.promptTokens - predicted,
            missReason: predicted > 0 ? .hit : .cold
        )
        let reported = ReportedCacheUsage(
            readTokens: usage.cachedPromptTokens,
            writtenTokens: 0,
            uncachedTokens: max(0, usage.promptTokens - usage.cachedPromptTokens)
        )
        switch CacheReconciler.reconcile(predicted: outcome, reported: reported, toleranceTokens: tolerance) {
        case .agrees: return .agreed
        case .providerReadLess: return .readLess
        case .providerReadMore: return .readMore
        }
    }
}
