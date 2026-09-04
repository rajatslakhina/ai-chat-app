import EffectiveComparisonKit
import EffectiveVoteKit
import FamilyErrorKit
import Foundation

extension MetadataPipeline {
    /// The panel shape this correction is derived from: the same four gates `familyError` counts.
    static let comparisonJudgeCount = familyJudgeCount

    /// Re-prices the correction `familyError` applied, using the dependence the panel actually has.
    func auditEffectiveComparison(
        trace: inout PipelineTrace,
        store: PanelHistoryStore = .shared
    ) async {
        await auditEffectiveComparison(trace: &trace, history: await store.history)
    }

    /// The same audit over a supplied history.
    ///
    /// `judgeCount` is injectable for the same reason its sibling's is: a panel too small to have
    /// a family is a real `failed` rather than a silent fallback, and it has to be reachable from
    /// a test to be worth writing.
    func auditEffectiveComparison(
        trace: inout PipelineTrace,
        history: ObservationHistory,
        judgeCount: Int = comparisonJudgeCount
    ) async {
        do {
            let design = try PanelDesign(judgeCount: judgeCount)
            let matrix = try design.correlationMatrix()
            let tail = try PermutationEffectiveCount.standard.estimate(for: matrix)
            let rank = try LiJi().checkedEstimate(for: matrix)
            let budget = try MultiplicityBudget(count: tail, level: Self.comparisonAlpha)

            let measured = measuredAssociations(history)
            guard let family = Self.family(from: measured, judgeCount: judgeCount) else {
                trace.record(
                    .effectiveComparison,
                    .skipped(reason: Self.knownBeforeAnyData(
                        design, tail: tail, rank: rank, history: history
                    ))
                )
                return
            }
            guard family.findings.contains(where: { $0.pValue <= Self.comparisonAlpha }) else {
                trace.record(
                    .effectiveComparison,
                    .noOp(reason: Self.nothingToReprice(family, budget: budget, tail: tail))
                )
                return
            }
            trace.record(
                .effectiveComparison,
                .ran(detail: Self.comparisonDetail(
                    family, design: design, budget: budget, tail: tail, rank: rank
                ))
            )
        } catch {
            trace.record(.effectiveComparison, .failed(message: "\(error)"))
        }
    }

    /// The level this stage and `familyError` both rule at.
    static var comparisonAlpha: Double { FamilyErrorKit.ConfidenceLevel.ninetyFive.alpha }

    /// The associations the panel has managed to measure so far.
    private func measuredAssociations(_ history: ObservationHistory) -> [PairwiseAssociation] {
        EffectiveVoteEstimator(basis: .verdictAgreement, policy: Self.effectiveVotePolicy)
            .estimate(history, stratum: .all)
            .measuredAssociations
    }

    // MARK: - the three outcomes

    /// What this stage can say on a panel nobody has observed yet.
    ///
    /// More than its siblings can, and that is the point worth recording. Every other stage in
    /// this family needs readings before it has anything; this correction is derived from the
    /// panel's *shape*, so the effective count, the dependence and the threshold are all knowable
    /// on a fresh install with zero turns behind them. The skip names them rather than waiting.
    private static func knownBeforeAnyData(
        _ design: PanelDesign,
        tail: EffectiveCount,
        rank: EffectiveCount,
        history: ObservationHistory
    ) -> String {
        "\(history.count) observed turn(s), no pair measurable yet; the shape is already known — "
            + "\(design.comparisonCount) comparisons, \(design.overlappingPairings) of "
            + "\(design.totalPairings) pairings sharing a gate, worth "
            + format(tail.value) + " effective comparison(s) rather than the "
            + format(rank.value) + " its rank would suggest"
    }

    /// A family with nothing in it strong enough for a looser threshold to matter.
    private static func nothingToReprice(
        _ family: Family,
        budget: MultiplicityBudget,
        tail: EffectiveCount
    ) -> String {
        "\(family.reportedCount) of \(family.size) pair(s) measurable; none reaches "
            + format(comparisonAlpha) + " uncorrected, so a denominator of "
            + format(tail.value) + " instead of \(family.size) moves the threshold to "
            + exponent(budget.effectiveThreshold) + " and changes nothing"
    }

    // MARK: - what the calibration found

    private static func comparisonDetail(
        _ family: Family,
        design: PanelDesign,
        budget: MultiplicityBudget,
        tail: EffectiveCount,
        rank: EffectiveCount
    ) -> String {
        [
            "\(family.reportedCount) of \(family.size) pair(s) measurable",
            dependenceSummary(design, budget: budget, family: family),
            countSummary(tail: tail, rank: rank, familySize: family.size),
            survivalSummary(family, budget: budget)
        ].joined(separator: "; ")
    }

    /// What the arbitrary-dependence default charged, and what this shape is worth.
    private static func dependenceSummary(
        _ design: PanelDesign,
        budget: MultiplicityBudget,
        family: Family
    ) -> String {
        "\(design.overlappingPairings) of \(design.totalPairings) pairings share a gate ("
            + String(format: "%.0f", design.overlapDensity * 100)
            + "% overlap), so Benjamini-Yekutieli charges " + format(budget.yekutieliMultiplier)
            + "x for arbitrary dependence where this shape is worth "
            + format(budget.effectiveMultiplier) + "x"
    }

    /// The distinction this stage exists to not get wrong.
    ///
    /// The rank is smaller here, which makes it the flattering number, which is why it is quoted
    /// beside the count actually spent rather than left out. `MultiplicityBudget` would have
    /// thrown had this stage tried to divide by it.
    private static func countSummary(tail: EffectiveCount, rank: EffectiveCount, familySize: Int) -> String {
        "spending the tail count " + format(tail.value) + " of \(familySize) and not the rank "
            + format(rank.value) + ", which counts the gates behind the family rather than "
            + "the behaviour of its largest reading"
    }

    /// Whether re-pricing actually changed which readings the app may publish.
    ///
    /// Reported either way. A calibration that moved a threshold and published the same set has
    /// not found anything, and a stage that only speaks up when it changed something is a stage
    /// nobody can calibrate their trust in.
    private static func survivalSummary(_ family: Family, budget: MultiplicityBudget) -> String {
        let correction = BenjaminiYekutieli()
        let underYekutieli = Set(
            correction.survivors(of: family, at: .ninetyFive).map(\.key)
        )
        let underCalibration = Set(
            family.findings.filter { budget.survives($0.pValue) }.map(\.key)
        )
        let bought = underCalibration.subtracting(underYekutieli).sorted()
        let summary = "\(underYekutieli.count) pair(s) survive Benjamini-Yekutieli, "
            + "\(underCalibration.count) survive the calibrated threshold "
            + exponent(budget.effectiveThreshold)
        guard !bought.isEmpty else {
            return summary + "; the same set either way, which is the honest result on this page"
        }
        return summary + "; measuring the shape publishes \(bought.joined(separator: ", "))"
    }

    // MARK: - formatting

    private static func format(_ value: Double) -> String {
        String(format: "%.4f", value)
    }

    private static func exponent(_ value: Double) -> String {
        String(format: "%.3e", value)
    }
}
