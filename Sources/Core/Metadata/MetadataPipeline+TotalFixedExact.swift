import ConditioningCostKit
import EffectiveVoteKit
import ExactAssociationKit
import Foundation
import TotalFixedExactKit
import UnconditionalExactKit

extension MetadataPipeline {
    /// The level this stage tests at, which must be the level `exactAssociation` draws at.
    static let totalFixedExactConfidence = ExactConfidence.ninetyFive

    /// How wide a bracket the p-value may be known to.
    ///
    /// A supremum reached by subdivision is approached from below, so the number found is a
    /// *lower* bound and only the number plus its remainder may be quoted. Naming the width lets
    /// the package choose how much subdivision that costs.
    static let totalFixedExactPrecision = 1e-7

    /// The largest total-fixed design this stage will audit the *level* of.
    ///
    /// A p-value here is one enumeration and a few hundred subdivisions. A size audit is a
    /// p-value for every table the design admits and then one more supremum, and a total-fixed
    /// design admits `C(n + 3, 3)` tables — cubic, where the row-fixed count is quadratic. The
    /// stage always reports the p-value and audits the level only when it can afford to, naming
    /// the design it did not audit rather than substituting a smaller one.
    static let totalFixedExactAuditBudget = 500

    /// Answers `unconditionalExact`'s question for the design this panel actually has.
    func auditTotalFixedExact(
        trace: inout PipelineTrace,
        store: PanelHistoryStore = .shared
    ) async {
        auditTotalFixedExact(trace: &trace, history: await store.history)
    }

    /// The same audit over a supplied history.
    ///
    /// `unconditionalExact` stopped conditioning on margins nothing fixed, and stopped one
    /// parameter short: its guarantee is about a design with one fixed row margin, and this panel
    /// has none. Its own detail line says so. This stage admits the second parameter, which makes
    /// the supremum a maximisation over a square rather than an interval.
    ///
    /// The reason it is worth doing rather than approximating is measured here rather than
    /// asserted: the row-fixed reading of the same block is not a bound in either direction, so
    /// there is no direction in which the cheaper number is the safe one.
    func auditTotalFixedExact(
        trace: inout PipelineTrace,
        history: ObservationHistory,
        confidence: ExactConfidence = MetadataPipeline.totalFixedExactConfidence,
        against conditional: ExactConfidence = MetadataPipeline.exactAssociationConfidence,
        precision: Double = MetadataPipeline.totalFixedExactPrecision,
        budget: Int = MetadataPipeline.totalFixedExactAuditBudget
    ) {
        guard !history.observations.isEmpty else {
            trace.record(.totalFixedExact, .skipped(reason: Self.totalFixedNothingObserved()))
            return
        }
        guard confidence.label == conditional.label else {
            trace.record(
                .totalFixedExact,
                .failed(message: Self.totalFixedLevelMismatch(confidence, conditional))
            )
            return
        }
        let judges = history.judges
        guard judges.count >= 2 else {
            trace.record(.totalFixedExact, .noOp(reason: Self.totalFixedTooFewGates(judges.count)))
            return
        }
        guard let joint = Self.transportJoint(history, judges: judges) else {
            trace.record(.totalFixedExact, .noOp(reason: Self.totalFixedNoPair(history)))
            return
        }
        record(
            Self.totalFixedRead(
                joint, confidence: confidence, precision: precision, budget: budget
            ),
            for: joint, history: history, into: &trace
        )
    }

    private func record(
        _ result: TotalFixedResult,
        for joint: TransportJoint,
        history: ObservationHistory,
        into trace: inout PipelineTrace
    ) {
        switch result {
        case let .refused(message):
            trace.record(.totalFixedExact, .failed(message: message))
        case let .nothingToTest(reason):
            trace.record(.totalFixedExact, .noOp(reason: reason))
        case let .tested(reading):
            trace.record(
                .totalFixedExact,
                .ran(detail: Self.totalFixedDetail(joint, reading: reading, history: history))
            )
        }
    }

    // MARK: - what the test found

    /// What auditing the level found, when the design was small enough to audit.
    struct TotalFixedSizeReading: Sendable, Equatable {
        let totalFixedSpend: Double
        let rowFixedSpend: Double
        let conditionalSpend: Double
        let asymptoticSpend: Double
        let asymptoticHolds: Bool
    }

    /// The block, tested under all three designs.
    struct TotalFixedReading: Sendable, Equatable {
        let itemCount: Int
        let level: String
        let totalFixed: Double
        let bracket: Double
        let rowFixed: Double
        let conditional: Double
        let admittedTables: Int
        let designTables: Int
        let worstRowRate: Double
        let worstColumnRate: Double
        let decisionsAgree: Bool
        let cheaperReadingIsLower: Bool
        /// `nil` when the design was over ``totalFixedExactAuditBudget``.
        let size: TotalFixedSizeReading?
        let budget: Int
    }

    /// Three outcomes, and all three are reachable.
    enum TotalFixedResult: Sendable {
        case tested(TotalFixedReading)
        case nothingToTest(String)
        case refused(String)
    }

    static func totalFixedRead(
        _ joint: TransportJoint,
        confidence: ExactConfidence,
        precision: Double,
        budget: Int
    ) -> TotalFixedResult {
        guard let audit = try? ExactAssociation.audit(joint.panel),
              let block = audit.readings.first?.block else {
            return .nothingToTest(Self.totalFixedAllPinned(joint))
        }
        do {
            return .tested(
                try Self.totalFixedTest(
                    block, confidence: confidence, precision: precision, budget: budget
                )
            )
        } catch {
            return .refused(Self.totalFixedUnreadable(joint, items: block.itemCount, error: error))
        }
    }

    /// The block, tested three ways.
    ///
    /// One `do`/`catch` around the whole reading rather than a guard per step. Two things here
    /// throw for reasons a caller controls — a precision that is not a positive width, and a block
    /// past what the package will enumerate — so the single refusal arm is reachable from two
    /// directions and there is no arm left that cannot fire.
    static func totalFixedTest(
        _ block: ExactBlock,
        confidence: ExactConfidence,
        precision: Double,
        budget: Int
    ) throws -> TotalFixedReading {
        let table = try CrossTable(a: block.a, b: block.b, c: block.c, d: block.d)
        let test = try TotalFixedExact(.enclosure(precision), budget: 20_000)
        let reading = try test.pValue(for: table)
        let arms = try table.arms()
        let rowFixed = try UnconditionalExact(.remainder(1e-5)).pValue(for: arms)
        let conditional = FisherConditional.pValue(for: arms)
        let alpha = confidence.alpha
        let verdicts = Set(
            [reading.rejects(at: alpha), rowFixed.value <= alpha, conditional <= alpha]
        )
        let affordable = try TableSpace(total: table.total).count <= budget
        return TotalFixedReading(
            itemCount: table.total,
            level: confidence.label,
            totalFixed: reading.value,
            bracket: reading.uncertainty,
            rowFixed: rowFixed.value,
            conditional: conditional,
            admittedTables: reading.admittedTableCount,
            designTables: reading.designTableCount,
            worstRowRate: reading.worstRowRate,
            worstColumnRate: reading.worstColumnRate,
            decisionsAgree: verdicts.count == 1,
            cheaperReadingIsLower: rowFixed.value < reading.value,
            size: affordable ? try Self.totalFixedSize(table.total, alpha: alpha) : nil,
            budget: budget
        )
    }

    /// What each procedure spends of the level it claims, on the design the block sits in.
    static func totalFixedSize(
        _ total: Int,
        alpha: Double
    ) throws -> TotalFixedSizeReading {
        let test = try TotalFixedExact(.enclosure(1e-8), budget: 20_000)
        let unconditional = try Self.totalFixedSpend(
            .unconditional(restriction: .unrestricted), total: total, alpha: alpha, test: test
        )
        let conditional = try Self.totalFixedSpend(
            .conditional, total: total, alpha: alpha, test: test
        )
        let asymptotic = try Self.totalFixedSpend(
            .asymptoticScore, total: total, alpha: alpha, test: test
        )
        let rowFixed = try SizeCertificate.of(
            procedure: .unconditional(.unrestricted),
            trials: total / 2, otherTrials: total - total / 2, alpha: alpha
        )
        return TotalFixedSizeReading(
            totalFixedSpend: unconditional.spentShare,
            rowFixedSpend: rowFixed.spentShare,
            conditionalSpend: conditional.spentShare,
            asymptoticSpend: asymptotic.spentShare,
            asymptoticHolds: asymptotic.holdsItsLevel
        )
    }

    private static func totalFixedSpend(
        _ procedure: TotalFixedProcedure,
        total: Int,
        alpha: Double,
        test: TotalFixedExact
    ) throws -> LevelCertificate {
        let mask = try LevelAudit.rejectionMask(
            of: procedure, total: total, alpha: alpha, test: test
        )
        return try LevelAudit.certificate(
            of: procedure, total: total, alpha: alpha, rejecting: mask, test: test
        )
    }

    // MARK: - the outcomes

    private static func totalFixedNothingObserved() -> String {
        "no turn observed yet; admitting a second nuisance parameter still needs a table to "
            + "admit it for, and this panel has produced none"
    }

    private static func totalFixedLevelMismatch(
        _ mine: ExactConfidence, _ theirs: ExactConfidence
    ) -> String {
        "this stage tests at \(mine.label) while exactAssociation draws its intervals at "
            + "\(theirs.label); every comparison here is between three decisions at one level, "
            + "and three levels disagree for reasons that have nothing to do with the design — "
            + "the mistake would not show up in the output, so it is refused instead"
    }

    private static func totalFixedTooFewGates(_ count: Int) -> String {
        "\(count) gate(s) on this panel; a two-by-two table needs two classifications and there "
            + "is only one thing here to be one"
    }

    private static func totalFixedNoPair(_ history: ObservationHistory) -> String {
        "\(history.count) observed turn(s), but no two gates have different verdict rates; there "
            + "is no block here whose rows could differ"
    }

    private static func totalFixedAllPinned(_ joint: TransportJoint) -> String {
        "\(joint.key): every block of the joint table is pinned by a zero margin, so both rows "
            + "are constants; there is no difference for any test to find under any design"
    }

    private static func totalFixedUnreadable(
        _ joint: TransportJoint, items: Int, error: Error
    ) -> String {
        "\(joint.key): the readable block has \(items) item(s) and the total-fixed reading was "
            + "declined — \(error); no smaller design was substituted for it, because a "
            + "guarantee about a design nobody ran is what this stage exists to stop reporting"
    }

    private static func totalFixedDetail(
        _ joint: TransportJoint, reading: TotalFixedReading, history: ObservationHistory
    ) -> String {
        var parts = [
            "\(history.count) turn(s), pair \(joint.key); the readable block has "
                + "\(reading.itemCount) item(s), tested at \(reading.level)"
        ]
        parts.append(totalFixedTestLine(reading))
        parts.append(totalFixedDirectionLine(reading))
        parts.append(totalFixedSizeLine(reading))
        parts.append(totalFixedLicenceLine(reading))
        return parts.joined(separator: "; ")
    }

    private static func totalFixedTestLine(_ reading: TotalFixedReading) -> String {
        "total-fixed p = " + totalFixedFormat(reading.totalFixed, 6) + " (bracket "
            + totalFixedFormat(reading.bracket, 9) + " wide, worst rates "
            + totalFixedFormat(reading.worstRowRate) + " and "
            + totalFixedFormat(reading.worstColumnRate) + ", region "
            + "\(reading.admittedTables) of \(reading.designTables) table(s)) against row-fixed "
            + totalFixedFormat(reading.rowFixed, 6) + " and Fisher's "
            + totalFixedFormat(reading.conditional, 6) + ", and at this level the three "
            + (reading.decisionsAgree ? "agree" : "DISAGREE about whether there is anything here")
    }

    /// The finding this stage exists for: which way the cheaper reading is wrong on *this* block.
    private static func totalFixedDirectionLine(_ reading: TotalFixedReading) -> String {
        let direction = reading.cheaperReadingIsLower
            ? "lower than the honest one, so reading this block as row-fixed would reject where "
                + "the design it came from does not"
            : "higher than the honest one, so reading this block as row-fixed gives away power "
                + "the design it came from would have spent"
        return "the row-fixed reading of this same block is " + direction
            + " — the cheaper reading moves both ways across panels and is not a bound in either"
    }

    /// What the level actually costs, or the design that was not audited, named.
    private static func totalFixedSizeLine(_ reading: TotalFixedReading) -> String {
        guard let size = reading.size else {
            return "the total-fixed design of this block has \(reading.designTables) table(s), "
                + "over this stage's audit budget of \(reading.budget), so what each procedure "
                + "spends of its level was not measured here rather than measured on a design "
                + "this block does not have"
        }
        return "on that design the conditional test spends "
            + totalFixedFormat(size.conditionalSpend * 100, 1) + "% of the level it claims, the "
            + "row-fixed test " + totalFixedFormat(size.rowFixedSpend * 100, 1) + "%, the "
            + "asymptotic score test " + totalFixedFormat(size.asymptoticSpend * 100, 1) + "% and "
            + (size.asymptoticHolds ? "holds it" : "does NOT hold it")
            + ", against this stage's " + totalFixedFormat(size.totalFixedSpend * 100, 1) + "%"
    }

    /// The part this stage no longer has to leave implied.
    private static func totalFixedLicenceLine(_ reading: TotalFixedReading) -> String {
        "the guarantee above is for \(SamplingDesign.totalFixed.label), which is the design this "
            + "panel has: \(SamplingDesign.totalFixed.rationale). Both rates were estimated and "
            + "neither was chosen, which is why there are two of them and why "
            + "\(reading.designTables) tables had to be enumerated to say anything at all"
    }

    static func totalFixedFormat(_ value: Double, _ places: Int = 4) -> String {
        String(format: "%.\(places)f", value)
    }
}
