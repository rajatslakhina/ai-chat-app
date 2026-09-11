import EffectiveVoteKit
import ExactAssociationKit
import Foundation
import RestrictionRuleKit
import UnconditionalExactKit

extension MetadataPipeline {
    /// The level this stage audits at, which must be the level `unconditionalExact` draws at.
    static let restrictionRuleConfidence = ExactConfidence.ninetyFive

    /// The largest row-fixed design this stage will audit the *level* of, for both the
    /// conventional gamma and the recommended one.
    static let restrictionRuleAuditBudget = 200

    /// How fine `unconditionalExact`'s own grid is, expressed as the width of its bracket.
    static let restrictionRulePrecision = 1e-5

    /// The smallest restriction level the search considers — close enough to unrestricted that a
    /// caller who never wants to restrict at all still gets an honest answer.
    static let restrictionRuleGammaFloor = 1e-6

    /// The largest restriction level the search considers.
    static let restrictionRuleGammaCeiling = 0.2

    /// Answers the question `unconditionalExact` and `totalFixedExact` both leave open: whether
    /// their shared conventional `gamma = 0.001` is actually the right number for this panel.
    func auditRestrictionRule(
        trace: inout PipelineTrace,
        store: PanelHistoryStore = .shared
    ) async {
        auditRestrictionRule(trace: &trace, history: await store.history)
    }

    /// The same audit over a supplied history.
    ///
    /// `unconditionalExact` restricts its nuisance search with a Berger–Boos region at a fixed
    /// conventional `gamma`, chosen once, by nobody, for no particular design — this app has never
    /// used anything else. This stage reads the same block `unconditionalExact` reads and asks
    /// whether that convention is actually a good one, using `RestrictionRuleKit`'s search rather
    /// than assuming the answer. It changes nothing about how `unconditionalExact` or
    /// `totalFixedExact` compute their own p-values; it only measures whether the number they both
    /// default to is the one a search would have found.
    func auditRestrictionRule(
        trace: inout PipelineTrace,
        history: ObservationHistory,
        confidence: ExactConfidence = MetadataPipeline.restrictionRuleConfidence,
        precision: Double = MetadataPipeline.restrictionRulePrecision,
        gammaFloor: Double = MetadataPipeline.restrictionRuleGammaFloor,
        gammaCeiling: Double = MetadataPipeline.restrictionRuleGammaCeiling,
        budget: Int = MetadataPipeline.restrictionRuleAuditBudget
    ) {
        guard !history.observations.isEmpty else {
            trace.record(.restrictionRule, .skipped(reason: Self.restrictionRuleNothingObserved()))
            return
        }
        let judges = history.judges
        guard judges.count >= 2 else {
            trace.record(
                .restrictionRule, .noOp(reason: Self.restrictionRuleTooFewGates(judges.count))
            )
            return
        }
        guard let joint = Self.transportJoint(history, judges: judges) else {
            trace.record(.restrictionRule, .noOp(reason: Self.restrictionRuleNoPair(history)))
            return
        }
        record(
            Self.restrictionRuleRead(
                joint, confidence: confidence, precision: precision,
                gammaRange: gammaFloor...gammaCeiling, budget: budget
            ),
            for: joint, history: history, into: &trace
        )
    }

    private func record(
        _ result: RestrictionRuleResult,
        for joint: TransportJoint,
        history: ObservationHistory,
        into trace: inout PipelineTrace
    ) {
        switch result {
        case let .refused(message):
            trace.record(.restrictionRule, .failed(message: message))
        case let .nothingToTest(reason):
            trace.record(.restrictionRule, .noOp(reason: reason))
        case let .tested(reading):
            trace.record(
                .restrictionRule,
                .ran(detail: Self.restrictionRuleDetail(joint, reading: reading, history: history))
            )
        }
    }

    // MARK: - what the search found

    /// One reading: the conventional gamma against a search's recommendation, on the block
    /// `unconditionalExact` already reads.
    struct RestrictionRuleReading: Sendable, Equatable {
        let itemCount: Int
        let level: String
        let unrestricted: Double
        let conventional: Double
        let recommendedGamma: Double
        let recommendedValue: Double
        let isRestrictionWorthwhile: Bool
        /// `nil` when the design was over ``restrictionRuleAuditBudget``.
        let conventionalHoldsLevel: Bool?
        let recommendedHoldsLevel: Bool?
        let budget: Int
    }

    /// Three outcomes, and all three are reachable.
    enum RestrictionRuleResult: Sendable {
        case tested(RestrictionRuleReading)
        case nothingToTest(String)
        case refused(String)
    }

    static func restrictionRuleRead(
        _ joint: TransportJoint,
        confidence: ExactConfidence,
        precision: Double,
        gammaRange: ClosedRange<Double>,
        budget: Int
    ) -> RestrictionRuleResult {
        guard let audit = try? ExactAssociation.audit(joint.panel),
              let block = audit.readings.first?.block else {
            return .nothingToTest(Self.restrictionRuleAllPinned(joint))
        }
        do {
            return .tested(
                try Self.restrictionRuleTest(
                    block, confidence: confidence, precision: precision,
                    gammaRange: gammaRange, budget: budget
                )
            )
        } catch {
            return .refused(
                Self.restrictionRuleUnreadable(joint, items: block.itemCount, error: error)
            )
        }
    }

    /// The block, read row-fixed and searched for the gamma that minimises its own quoted value.
    static func restrictionRuleTest(
        _ block: ExactBlock,
        confidence: ExactConfidence,
        precision: Double,
        gammaRange: ClosedRange<Double>,
        budget: Int
    ) throws -> RestrictionRuleReading {
        let arms = try ArmCounts(
            successes: block.a, trials: block.rowTotal,
            otherSuccesses: block.c, otherTrials: block.otherRowTotal
        )
        let test = try UnconditionalExact(.remainder(precision))
        let measure = PooledScore()
        let cost = ClosureGammaCostFunction { gamma in
            try test.pValue(
                for: arms, alternative: .twoSided, using: measure,
                restriction: .bergerBoos(gamma: gamma)
            ).value
        }
        let conventional = try cost.value(atGamma: 0.001)
        let recommendation = try GammaSearch.recommend(
            costFunction: cost, gammaFloor: gammaRange.lowerBound, gammaCeiling: gammaRange.upperBound
        )
        let alpha = confidence.alpha
        let affordable = (arms.trials + 1) * (arms.otherTrials + 1) <= budget
        var conventionalHolds: Bool?
        var recommendedHolds: Bool?
        if affordable {
            conventionalHolds = try SizeCertificate.of(
                procedure: .unconditional(.bergerBoos(gamma: 0.001)),
                trials: arms.trials, otherTrials: arms.otherTrials, alpha: alpha
            ).holdsItsLevel
            recommendedHolds = try SizeCertificate.of(
                procedure: .unconditional(.bergerBoos(gamma: recommendation.recommendedGamma)),
                trials: arms.trials, otherTrials: arms.otherTrials, alpha: alpha
            ).holdsItsLevel
        }
        return RestrictionRuleReading(
            itemCount: block.itemCount,
            level: confidence.label,
            unrestricted: recommendation.floorValue,
            conventional: conventional,
            recommendedGamma: recommendation.recommendedGamma,
            recommendedValue: recommendation.recommendedValue,
            isRestrictionWorthwhile: recommendation.isRestrictionWorthwhile,
            conventionalHoldsLevel: conventionalHolds,
            recommendedHoldsLevel: recommendedHolds,
            budget: budget
        )
    }

    // MARK: - the outcomes

    private static func restrictionRuleNothingObserved() -> String {
        "no turn observed yet; searching for a better gamma still needs a table to search it on, "
            + "and this panel has produced none"
    }

    private static func restrictionRuleTooFewGates(_ count: Int) -> String {
        "\(count) gate(s) on this panel; a two-by-two table needs two classifications and there "
            + "is only one thing here to be one"
    }

    private static func restrictionRuleNoPair(_ history: ObservationHistory) -> String {
        "\(history.count) observed turn(s), but no two gates have different verdict rates; there "
            + "is no block here whose restriction is worth searching"
    }

    private static func restrictionRuleAllPinned(_ joint: TransportJoint) -> String {
        "\(joint.key): every block of the joint table is pinned by a zero margin, so both rows "
            + "are constants; there is no p-value here for a gamma to change"
    }

    private static func restrictionRuleUnreadable(
        _ joint: TransportJoint, items: Int, error: Error
    ) -> String {
        "\(joint.key): the readable block has \(items) item(s) and the search was declined — "
            + "\(error); no smaller design was substituted for it"
    }

    private static func restrictionRuleDetail(
        _ joint: TransportJoint, reading: RestrictionRuleReading, history: ObservationHistory
    ) -> String {
        var parts = [
            "\(history.count) turn(s), pair \(joint.key); the readable block has "
                + "\(reading.itemCount) item(s), searched at \(reading.level)"
        ]
        parts.append(restrictionRuleValueLine(reading))
        parts.append(restrictionRuleLevelLine(reading))
        return parts.joined(separator: "; ")
    }

    private static func restrictionRuleValueLine(_ reading: RestrictionRuleReading) -> String {
        func format(_ value: Double) -> String { restrictionRuleFormat(value) }
        return "unrestricted = " + format(reading.unrestricted) + ", conventional gamma=0.001 = "
            + format(reading.conventional) + ", recommended gamma = "
            + format(reading.recommendedGamma) + " (value " + format(reading.recommendedValue)
            + "), so restricting at all is "
            + (reading.isRestrictionWorthwhile ? "worthwhile here" : "not worthwhile here — "
                + "unconditionalExact's own convention would have been better left unrestricted")
    }

    private static func restrictionRuleLevelLine(_ reading: RestrictionRuleReading) -> String {
        guard let conventionalHolds = reading.conventionalHoldsLevel,
              let recommendedHolds = reading.recommendedHoldsLevel else {
            return "the row-fixed design of this block has more tables than this stage's audit "
                + "budget of \(reading.budget), so whether either gamma holds its level was not "
                + "measured here rather than measured on a design this block does not have"
        }
        return "on that design the conventional gamma "
            + (conventionalHolds ? "holds its level" : "does NOT hold its level")
            + " and the recommended gamma "
            + (recommendedHolds ? "holds its level" : "does NOT hold its level")
            + " — both are fixed before this block is looked at, which is what the guarantee needs"
    }

    static func restrictionRuleFormat(_ value: Double, _ places: Int = 6) -> String {
        String(format: "%.\(places)f", value)
    }
}
