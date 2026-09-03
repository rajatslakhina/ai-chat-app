import EffectiveVoteKit
import FamilyErrorKit
import Foundation

extension MetadataPipeline {
    /// The panel this app runs: four evidence gates, and therefore six pairs.
    ///
    /// Read as a count rather than derived from whatever happened to be measurable, because that
    /// is the whole argument. `effectiveVote` measures every pair it can and stays silent about
    /// the ones it cannot; correcting for the pairs that produced a number would divide by the
    /// filtered count, which is always the flattering one.
    static let familyJudgeCount = 4

    /// Corrects the panel-wide readings the three stages above publish one pair at a time.
    func auditFamilyError(trace: inout PipelineTrace, store: PanelHistoryStore = .shared) async {
        await auditFamilyError(trace: &trace, history: await store.history)
    }

    /// The same correction over a supplied history, for the same reason the sibling stages take one.
    ///
    /// `judgeCount` is injectable only so that a panel too small to have a pair is reachable from a
    /// test. The app always passes ``familyJudgeCount``, and a panel below two judges is a genuine
    /// `failed` rather than a silent fallback: nothing downstream of the overlap graph means
    /// anything without it, and a stage that invents a shape it could not count is worse than one
    /// that says it could not count.
    func auditFamilyError(
        trace: inout PipelineTrace,
        history: ObservationHistory,
        judgeCount: Int = familyJudgeCount
    ) async {
        do {
            let graph = try PairOverlapGraph(judgeCount: judgeCount)
            let estimator = EffectiveVoteEstimator(
                basis: .verdictAgreement,
                policy: Self.effectiveVotePolicy
            )
            let measured = estimator.estimate(history, stratum: .all).measuredAssociations
            guard let family = Self.family(from: measured, judgeCount: judgeCount),
                  let top = Self.strongest(of: measured) else {
                trace.record(
                    .familyError,
                    .skipped(reason: Self.waitingForAFamily(history: history, graph: graph))
                )
                return
            }
            let level = FamilyErrorKit.ConfidenceLevel.ninetyFive
            guard family.findings.contains(where: { $0.pValue <= level.alpha }) else {
                trace.record(
                    .familyError,
                    .noOp(reason: Self.nothingToTakeAway(family, history: history))
                )
                return
            }
            let detail = try Self.familyDetail(
                family, measured: measured, top: top, graph: graph, history: history
            )
            trace.record(.familyError, .ran(detail: detail))
        } catch {
            trace.record(.familyError, .failed(message: "\(error)"))
        }
    }

    /// A measured pair with its coefficient already unwrapped.
    ///
    /// The unwrap happens once, here, instead of five times downstream behind a `?? 0` that could
    /// never fire. A default nobody can reach is not a safety net — it is an untestable lie about
    /// what the value would have been, and it is exactly the kind of thing this stage is about.
    struct MeasuredPair {
        let association: PairwiseAssociation
        let coefficient: Double

        var magnitude: Double { abs(coefficient) }
        var name: String { association.pair.description }
        var sampleSize: Int { association.sampleSize }
        var interval: ClosedRange<Double>? { association.interval }
    }

    /// Every association that produced a coefficient on a non-empty sample.
    static func measuredPairs(_ measured: [PairwiseAssociation]) -> [MeasuredPair] {
        measured.compactMap { association in
            guard let coefficient = association.coefficient, association.sampleSize > 0 else {
                return nil
            }
            return MeasuredPair(association: association, coefficient: coefficient)
        }
    }

    /// The measured pair with the largest magnitude, or `nil` when nothing was measured.
    static func strongest(of measured: [PairwiseAssociation]) -> MeasuredPair? {
        measuredPairs(measured).max { $0.magnitude < $1.magnitude }
    }

    // MARK: - building the family

    /// Every measured pair as a finding, sized by the panel's shape rather than by the count.
    ///
    /// `nil` when nothing is measurable, which is the ordinary state of a new install. Pairs that
    /// produced no coefficient are left out and enter every correction at `p = 1`, which is the
    /// conservative reading: a pair the panel could not measure has not produced evidence of
    /// anything, and treating it as a near-miss would make the correction weaker than it should be.
    static func family(from measured: [PairwiseAssociation], judgeCount: Int = familyJudgeCount) -> Family? {
        let findings = measured.compactMap { association -> Finding? in
            guard let coefficient = association.coefficient, association.sampleSize > 0 else {
                return nil
            }
            let statistic = coefficient * Double(association.sampleSize).squareRoot()
            return try? Finding(
                key: association.pair.description,
                pValue: NormalTail.twoSidedPValue(forZ: statistic),
                estimate: coefficient,
                standardError: 1 / Double(max(association.sampleSize - 3, 1)).squareRoot()
            )
        }
        return try? Family(findings: findings, origin: .panelPairs(judgeCount: judgeCount))
    }

    // MARK: - the three outcomes

    /// What a history with no measurable pair can still be told.
    private static func waitingForAFamily(
        history: ObservationHistory,
        graph: PairOverlapGraph
    ) -> String {
        "\(history.count) observed turn(s), no pair measurable yet; this panel will have "
            + "\(graph.pairCount) pairs whatever it measures, and \(graph.overlappingPairings) of "
            + "the \(graph.totalPairings) pairings among them share a gate, so the correction that "
            + "will apply is already known to be \(graph.recommendedAssumption.rawValue)"
    }

    /// A family where nothing cleared even the uncorrected threshold.
    ///
    /// A real `noOp` rather than a `ran` with an empty list: the correction removed nothing
    /// because there was nothing to remove, and a Diagnostics reader should be able to tell that
    /// from a correction that suppressed every row it was given.
    private static func nothingToTakeAway(_ family: Family, history: ObservationHistory) -> String {
        "\(family.reportedCount) of \(family.size) pair(s) measurable over \(history.count) turn(s); "
            + "none reaches 0.05 uncorrected, so there is nothing for a family correction to take "
            + "away — the page is already saying nothing"
    }

    // MARK: - what the correction found

    private static func familyDetail(
        _ family: Family,
        measured: [PairwiseAssociation],
        top: MeasuredPair,
        graph: PairOverlapGraph,
        history: ObservationHistory
    ) throws -> String {
        var parts = [
            "\(family.reportedCount) of \(family.size) pair(s) measurable over \(history.count) turn(s)"
        ]
        parts.append(survivalSummary(family))
        parts.append(dependenceSummary(family, graph: graph))
        parts.append(try selectionSummary(family, top: top))
        if let widening = wideningSummary(measured, familySize: family.size) {
            parts.append(widening)
        }
        return parts.joined(separator: "; ")
    }

    /// How many readings the family takes back, and which one it takes back first.
    private static func survivalSummary(_ family: Family) -> String {
        let level = FamilyErrorKit.ConfidenceLevel.ninetyFive
        let uncorrected = family.findings.filter { $0.pValue <= level.alpha }
        let correction = BenjaminiYekutieli()
        let survivors = correction.survivors(of: family, at: level)
        let surviving = Set(survivors.map(\.key))
        let withdrawn = uncorrected.map(\.key).filter { !surviving.contains($0) }
        var summary = "\(uncorrected.count) pair(s) clear 0.05 uncorrected, "
            + "\(survivors.count) survive \(correction.name) over \(family.size)"
        guard !withdrawn.isEmpty else { return summary }
        summary += "; the app publishes \(withdrawn.count) reading(s) the family does not support"
        if let first = withdrawn.first,
           let adjusted = correction.adjust(family).first(where: { $0.key == first }) {
            summary += ", first \(first) at adjusted "
                + String(format: "%.4f", adjusted.adjustedPValue)
        }
        return summary
    }

    /// How much of this family is dependent because of how the panel is shaped.
    private static func dependenceSummary(_ family: Family, graph: PairOverlapGraph) -> String {
        "\(graph.overlappingPairings) of \(graph.totalPairings) pairings share a gate ("
            + String(format: "%.0f", graph.overlapDensity * 100)
            + "% overlap), so independence is unavailable and the correction pays H("
            + "\(family.size)) = "
            + String(format: "%.4f", BenjaminiYekutieli.dependencePrice(forSize: family.size))
    }

    /// What noise alone would have put at the top of this page.
    ///
    /// The count is the **pair's own** sample size, not the turn count. A pair is measured only on
    /// turns where both of its gates spoke, which in this app is a fraction of the turns recorded,
    /// and quoting the larger number would shrink the ceiling and make the largest reading look
    /// more impressive than the evidence behind it. That is the exact direction of error this
    /// stage exists to catch, so it is not one to make here.
    private static func selectionSummary(
        _ family: Family,
        top: MeasuredPair
    ) throws -> String {
        let largest = top.magnitude
        let ceiling = try NullMaximum.threshold(
            familySize: family.size, observationCount: top.sampleSize)
        let single = try NullMaximum.threshold(
            familySize: 1, observationCount: top.sampleSize)
        let verdict = largest > ceiling ? "clears" : "does not clear"
        return "the largest reading is " + String(format: "%.4f", largest)
            + " on \(top.sampleSize) shared turn(s) and " + verdict + " the "
            + String(format: "%.4f", ceiling)
            + " ceiling for the largest of \(family.size) (a single reading would face "
            + String(format: "%.4f", single) + ")"
    }

    /// The strongest widenable interval, re-quoted so the whole page holds at 95%.
    ///
    /// A pair at `|phi| == 1` carries no widenable interval — `atanh` is unbounded there — and is
    /// named rather than dropped, because on this panel the perfectly-associated pair is the one a
    /// reader is most likely to be looking at.
    private static func wideningSummary(
        _ measured: [PairwiseAssociation],
        familySize: Int
    ) -> String? {
        let ranked = measuredPairs(measured).sorted { $0.magnitude > $1.magnitude }
        if let perfect = ranked.first, perfect.magnitude >= 1 {
            return "the largest reading, \(perfect.name), sits at |phi| 1.0000 where atanh is "
                + "unbounded, so it is the one member of this family that cannot be re-quoted at all"
        }
        guard let strongest = ranked.first(where: { $0.magnitude < 1 }),
              let published = strongest.interval,
              let widened = try? SimultaneousInterval.widenedFisher(
                published, familySize: familySize) else { return nil }
        return "\(strongest.name) is published as "
            + range(published) + " and holds across all \(familySize) only as "
            + range(widened.simultaneous) + " ("
            + String(format: "%.4f", widened.addedWidth) + " wider, member level "
            + String(format: "%.6f", widened.memberLevel.coverage) + ")"
    }

    private static func range(_ interval: ClosedRange<Double>) -> String {
        "[" + String(format: "%.4f", interval.lowerBound)
            + ", " + String(format: "%.4f", interval.upperBound) + "]"
    }
}
