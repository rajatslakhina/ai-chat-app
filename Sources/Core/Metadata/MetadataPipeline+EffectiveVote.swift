import EffectiveVoteKit
import Foundation

extension MetadataPipeline {
    /// The policy this audit publishes under.
    ///
    /// The package default is kept rather than lowered. A looser floor would let this stage print a
    /// number sooner, and the number it printed would be one nobody should change the arbiter on.
    /// The stage reports how many more turns it is waiting for instead, which is the useful half of
    /// a refusal anyway.
    static let effectiveVotePolicy = IntervalWidthPolicy()

    /// Measures the dependence graph the arbiter is standing on.
    ///
    /// Uses `verdictAgreement`, and that limit is stated in the reading rather than hidden. Error
    /// agreement is the basis that governs how much information a panel carries, and it needs to
    /// know which gate was *right* — a label this app does not have for its own evidence gates.
    /// Measuring what it can measure and saying which one it measured is the honest version;
    /// quietly reporting vote agreement as though it were the other would not be.
    func auditEffectiveVote(trace: inout PipelineTrace, store: PanelHistoryStore = .shared) async {
        await auditEffectiveVote(trace: &trace, history: await store.history)
    }

    /// The same audit over a supplied history, for the same reason the sibling stages take one.
    func auditEffectiveVote(trace: inout PipelineTrace, history: ObservationHistory) async {
        guard !history.isEmpty else {
            trace.record(
                .effectiveVote,
                .skipped(
                    reason: "no turn has had a gate file a reading yet, "
                        + "so the panel has never been observed"
                )
            )
            return
        }

        let estimator = EffectiveVoteEstimator(
            basis: .verdictAgreement,
            policy: Self.effectiveVotePolicy
        )
        switch estimator.outcome(history, stratum: .all) {
        case let .estimated(estimate):
            trace.record(.effectiveVote, .ran(detail: Self.publishedDetail(estimate, history: history)))
        case let .refused(refusal):
            trace.record(.effectiveVote, Self.waiting(refusal, history: history))
        }
    }

    /// A history too thin to publish from, reported with what it is still short of.
    ///
    /// The withheld figure is quoted because the refusal carries it. A reader told only "not enough
    /// turns" cannot tell a panel that is probably fine from one that has already collapsed, and
    /// that difference is what decides whether waiting is worth it.
    private static func waiting(
        _ refusal: EstimationRefusal,
        history: ObservationHistory
    ) -> StageOutcome {
        var detail = "\(history.count) observed turn(s): \(refusal.ground.detail)"
        if let withheld = refusal.withheldEffectiveVotes {
            detail += String(format: "; the withheld figure was %.2f of %d gates",
                             withheld, refusal.withheld.nominalJudges)
        } else {
            detail += "; no figure was reached"
        }
        return .noOp(reason: detail)
    }

    /// What the measurement says about the two declared edges.
    private static func publishedDetail(
        _ estimate: EffectiveVoteEstimate,
        history: ObservationHistory
    ) -> String {
        var parts: [String] = []
        if let votes = estimate.effectiveVotes {
            parts.append(String(format: "%.2f of %d gates are independent voices by vote agreement",
                                votes, estimate.nominalJudges))
        }
        let gaps = estimate.discrepancies(against: PanelHistoryStore.declaredStrengths())
        if gaps.isEmpty {
            parts.append("no declared edge could be measured over \(history.count) turns")
        } else {
            parts.append(contentsOf: gaps.sorted { $0.excess > $1.excess }.map(\.summary))
        }
        if !estimate.unmeasurablePairs.isEmpty {
            parts.append(
                "\(estimate.unmeasurablePairs.count) pair(s) unmeasurable, not scored as independent"
            )
        }
        parts.append(
            "basis is vote agreement, not error agreement; "
                + "this app has no label for which gate was right"
        )
        return parts.joined(separator: "; ")
    }
}
