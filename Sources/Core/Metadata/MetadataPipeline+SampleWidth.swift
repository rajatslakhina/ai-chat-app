import EffectiveVoteKit
import Foundation
import SampleWidthKit

extension MetadataPipeline {
    /// The association this panel is sized to detect, used only when there is nothing to measure.
    ///
    /// `PanelHistoryStore.declaredStrengths()` names the edges this app expects between its gates,
    /// and the largest of them is around this. Quoting a turn count against it answers "how long
    /// until `effectiveVote` can say anything" on an install that has observed nothing at all,
    /// which is every install for its first several dozen turns.
    static let sampleWidthTarget = 0.30

    /// Checks the panel's published intervals against what its own margins can express, and turns
    /// `effectiveVote`'s "not enough turns" into a number of turns.
    func auditSampleWidth(trace: inout PipelineTrace, store: PanelHistoryStore = .shared) async {
        await auditSampleWidth(trace: &trace, history: await store.history)
    }

    /// The same audit over a supplied history, for the same reason the sibling stages take one.
    func auditSampleWidth(trace: inout PipelineTrace, history: ObservationHistory) async {
        let estimator = EffectiveVoteEstimator(
            basis: .verdictAgreement,
            policy: Self.effectiveVotePolicy
        )
        let measured = estimator.estimate(history, stratum: .all).measuredAssociations
        guard !measured.isEmpty else {
            trace.record(.sampleWidth, .skipped(reason: Self.waitingForAPair(history: history)))
            return
        }
        trace.record(.sampleWidth, .ran(detail: Self.widthDetail(measured, history: history)))
    }

    /// What a history with no measurable pair can still be told.
    ///
    /// The count is quoted because it is the only actionable thing available before any gate has
    /// fired twice, and because it is genuinely surprising: a chat client whose gates fire on a
    /// minority of turns needs far more turns than a reader guesses before a correlation between
    /// two of them means anything.
    private static func waitingForAPair(history: ObservationHistory) -> String {
        var detail = "\(history.count) observed turn(s), no pair measurable yet"
        if let needed = try? SampleSufficiency.requiredCount(toSeparate: sampleWidthTarget, from: 0) {
            detail += "; separating an association of "
                + String(format: "%.2f", sampleWidthTarget)
                + " from zero at 95% needs \(needed) turns that each contribute a usable pair, "
                + "which is a floor rather than an estimate"
        }
        return detail
    }

    /// What the measured pairs look like once their own margins are taken into account.
    private static func widthDetail(
        _ measured: [PairwiseAssociation],
        history: ObservationHistory
    ) -> String {
        var parts = ["\(measured.count) measured pair(s) over \(history.count) turn(s)"]
        parts.append(overreachSummary(measured))
        parts.append(separationSummary(measured))
        parts.append(
            "the published intervals clamp to -1...1, which bounds any correlation and not one "
                + "this table could have produced"
        )
        return parts.joined(separator: "; ")
    }

    /// Pairs whose published interval reaches past what their margins can express.
    private static func overreachSummary(_ measured: [PairwiseAssociation]) -> String {
        let overreaches = measured.compactMap(overreach)
        guard let worst = overreaches.max(by: { $0.excess < $1.excess }) else {
            return "every published interval sits inside its own margin-feasible range"
        }
        return "\(overreaches.count) pair(s) publish an interval reaching past their feasible range; "
            + "widest is \(worst.pair) by "
            + String(format: "%.4f", worst.excess)
            + " (margins permit at most "
            + String(format: "%.4f", worst.reach) + ")"
    }

    /// How far one pair's published interval reaches outside its attainable range.
    ///
    /// A named type rather than a tuple: three members is one past what SwiftLint allows here, and
    /// the fix is a name, not a raised limit.
    struct MarginOverreach {
        let pair: String
        let excess: Double
        let reach: Double
    }

    /// The overreach for one pair, or `nil` when its interval sits inside the feasible range.
    private static func overreach(_ association: PairwiseAssociation) -> MarginOverreach? {
        guard let published = association.interval,
              let table = contingency(association.table) else { return nil }
        let feasible = MarginFeasibleRange(table: table)
        let below = feasible.range.lowerBound - published.lowerBound
        let above = published.upperBound - feasible.range.upperBound
        let excess = max(below, above)
        guard excess > 0 else { return nil }
        return MarginOverreach(pair: association.pair.description, excess: excess, reach: feasible.reach)
    }

    /// Which pairs separate from zero, and the longest wait among those that do not.
    private static func separationSummary(_ measured: [PairwiseAssociation]) -> String {
        var separated = 0
        var outstanding: (pair: String, count: Int)?
        for association in measured {
            guard let table = contingency(association.table),
                  let verdict = try? SampleSufficiency().verdict(for: table, against: 0) else { continue }
            switch verdict {
            case .separated:
                separated += 1
            case let .unresolved(required):
                guard let required, required > (outstanding?.count ?? 0) else { continue }
                outstanding = (pair: association.pair.description, count: required)
            }
        }
        guard let outstanding else { return "\(separated) pair(s) separate from zero" }
        return "\(separated) of \(measured.count) pair(s) separate from zero; the longest wait is "
            + "\(outstanding.pair) at \(outstanding.count) turns"
    }

    /// The same counts, in the shape `SampleWidthKit` measures widths on.
    private static func contingency(
        _ table: EffectiveVoteKit.ContingencyTable
    ) -> SampleWidthKit.ContingencyTable? {
        try? SampleWidthKit.ContingencyTable(
            bothTrue: table.bothTrue,
            firstTrueOnly: table.leftOnly,
            secondTrueOnly: table.rightOnly,
            bothFalse: table.bothFalse
        )
    }
}
