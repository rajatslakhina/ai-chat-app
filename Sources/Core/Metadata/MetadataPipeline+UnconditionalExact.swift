import EffectiveVoteKit
import ExactAssociationKit
import Foundation
import UnconditionalExactKit

extension MetadataPipeline {
    /// The level this stage tests at, which must be the level `exactAssociation` draws at.
    static let unconditionalExactConfidence = ExactConfidence.ninetyFive

    /// The largest row-fixed design this stage will audit the *level* of.
    ///
    /// A p-value is one enumeration of the design and one pass over the nuisance grid, which is
    /// cheap at any panel this app produces. A size audit is a p-value for every table the design
    /// can produce and then one more supremum, so its cost is the square of the first. This stage
    /// always reports the p-value and audits the level only when it can afford to, naming the
    /// design it did not audit rather than substituting a smaller one.
    static let unconditionalExactAuditBudget = 200

    /// How fine the nuisance grid is, expressed as the width of the bracket rather than as a
    /// count of subintervals.
    ///
    /// The count a precision needs scales with the square root of the design, so a count chosen
    /// for one panel is the wrong count for the next. Naming the precision lets the package pick.
    static let unconditionalExactPrecision = 1e-5

    /// Answers `exactAssociation`'s question without the assumption `conditioningCost` priced.
    func auditUnconditionalExact(
        trace: inout PipelineTrace,
        store: PanelHistoryStore = .shared
    ) async {
        auditUnconditionalExact(trace: &trace, history: await store.history)
    }

    /// The same audit over a supplied history.
    ///
    /// `conditioningCost` established that this app's exact intervals condition on margins nothing
    /// fixed, and measured what that costs in coverage. This stage stops paying it: Barnard's test
    /// keeps the nuisance parameter and maximises the null probability over it, so the guarantee it
    /// returns is about a design rather than about a table.
    ///
    /// What it is honest about is that the design it returns a guarantee for is still not the one
    /// this panel has. A panel of turns cross-classified by two gates is total-fixed. The row-fixed
    /// reading below is the same one `conditioningCost` already prices, read from the size side
    /// instead of the coverage side, and the detail line says so rather than implying otherwise.
    func auditUnconditionalExact(
        trace: inout PipelineTrace,
        history: ObservationHistory,
        confidence: ExactConfidence = MetadataPipeline.unconditionalExactConfidence,
        against conditional: ExactConfidence = MetadataPipeline.exactAssociationConfidence,
        precision: Double = MetadataPipeline.unconditionalExactPrecision,
        budget: Int = MetadataPipeline.unconditionalExactAuditBudget
    ) {
        guard !history.observations.isEmpty else {
            trace.record(.unconditionalExact, .skipped(reason: Self.unconditionalNothingObserved()))
            return
        }
        guard confidence.label == conditional.label else {
            trace.record(
                .unconditionalExact,
                .failed(message: Self.unconditionalLevelMismatch(confidence, conditional))
            )
            return
        }
        let judges = history.judges
        guard judges.count >= 2 else {
            trace.record(
                .unconditionalExact,
                .noOp(reason: Self.unconditionalTooFewGates(judges.count))
            )
            return
        }
        guard let joint = Self.transportJoint(history, judges: judges) else {
            trace.record(.unconditionalExact, .noOp(reason: Self.unconditionalNoPair(history)))
            return
        }
        record(
            Self.unconditionalRead(
                joint, confidence: confidence, precision: precision, budget: budget
            ),
            for: joint, history: history, into: &trace
        )
    }

    private func record(
        _ result: UnconditionalResult,
        for joint: TransportJoint,
        history: ObservationHistory,
        into trace: inout PipelineTrace
    ) {
        switch result {
        case let .refused(message):
            trace.record(.unconditionalExact, .failed(message: message))
        case let .nothingToTest(reason):
            trace.record(.unconditionalExact, .noOp(reason: reason))
        case let .tested(reading):
            trace.record(
                .unconditionalExact,
                .ran(detail: Self.unconditionalDetail(joint, reading: reading, history: history))
            )
        }
    }

    // MARK: - what the test found

    /// What auditing the level found, when the design was small enough to audit.
    struct UnconditionalSizeReading: Sendable, Equatable {
        let unconditionalSize: Double
        let conditionalSize: Double
        let unconditionalSpend: Double
        let conditionalSpend: Double
    }

    /// The block, tested twice.
    struct UnconditionalReading: Sendable, Equatable {
        let itemCount: Int
        let level: String
        let unconditional: Double
        let bracket: Double
        let conditional: Double
        let regionTables: Int
        let designTables: Int
        let worstRate: Double
        let decisionsAgree: Bool
        /// `nil` when the design was over ``unconditionalExactAuditBudget``.
        let size: UnconditionalSizeReading?
        let budget: Int
    }

    /// Three outcomes, and all three are reachable.
    enum UnconditionalResult: Sendable {
        case tested(UnconditionalReading)
        case nothingToTest(String)
        case refused(String)
    }

    static func unconditionalRead(
        _ joint: TransportJoint,
        confidence: ExactConfidence,
        precision: Double,
        budget: Int
    ) -> UnconditionalResult {
        guard let audit = try? ExactAssociation.audit(joint.panel),
              let block = audit.readings.first?.block else {
            return .nothingToTest(Self.unconditionalAllPinned(joint))
        }
        guard precision > 0 else {
            return .refused(Self.unconditionalUnusablePrecision(joint, precision: precision))
        }
        do {
            return .tested(
                try Self.unconditionalTest(
                    block, confidence: confidence, precision: precision, budget: budget
                )
            )
        } catch {
            return .refused(Self.unconditionalUnreadable(joint, items: block.itemCount))
        }
    }

    /// The block, tested both ways.
    ///
    /// Every step here throws for one reason — a design past what the package will enumerate — and
    /// there is one arm above that catches it. The earlier draft guarded each step separately, and
    /// two of those three guards could not fail: a block's corner count is never past its own row
    /// total, and a precision fixed as a constant is never non-positive. Both showed up as partial
    /// regions rather than as uncovered lines, which is the fifth time this repository has found
    /// that shape. The precision is a parameter now, so its refusal is real.
    static func unconditionalTest(
        _ block: ExactBlock,
        confidence: ExactConfidence,
        precision: Double,
        budget: Int
    ) throws -> UnconditionalReading {
        let arms = try ArmCounts(
            successes: block.a, trials: block.rowTotal,
            otherSuccesses: block.c, otherTrials: block.otherRowTotal
        )
        let reading = try UnconditionalExact(.remainder(precision)).pValue(for: arms)
        let alpha = confidence.alpha
        let conditional = FisherConditional.pValue(for: arms)
        let affordable = (arms.trials + 1) * (arms.otherTrials + 1) <= budget
        return UnconditionalReading(
            itemCount: block.itemCount,
            level: confidence.label,
            unconditional: reading.value,
            bracket: reading.uncertainty,
            conditional: conditional,
            regionTables: reading.regionTableCount,
            designTables: reading.designTableCount,
            worstRate: reading.worstRate,
            decisionsAgree: reading.rejects(at: alpha) == (conditional <= alpha),
            size: affordable ? try Self.unconditionalSize(arms, alpha: alpha) : nil,
            budget: budget
        )
    }

    /// What each test spends of the level it claims, on the design the block sits in.
    static func unconditionalSize(
        _ arms: ArmCounts,
        alpha: Double
    ) throws -> UnconditionalSizeReading {
        let free = try SizeCertificate.of(
            procedure: .unconditional(.unrestricted),
            trials: arms.trials, otherTrials: arms.otherTrials, alpha: alpha
        )
        let conditioned = try SizeCertificate.of(
            procedure: .fisherConditional,
            trials: arms.trials, otherTrials: arms.otherTrials, alpha: alpha
        )
        return UnconditionalSizeReading(
            unconditionalSize: free.size.attained,
            conditionalSize: conditioned.size.attained,
            unconditionalSpend: free.spentShare,
            conditionalSpend: conditioned.spentShare
        )
    }

    // MARK: - the outcomes

    private static func unconditionalNothingObserved() -> String {
        "no turn observed yet; a test without an assumption still needs a table to test, and this "
            + "panel has produced none"
    }

    private static func unconditionalLevelMismatch(
        _ mine: ExactConfidence, _ theirs: ExactConfidence
    ) -> String {
        "this stage tests at \(mine.label) while exactAssociation draws its intervals at "
            + "\(theirs.label); every comparison here is between two decisions at one level, and "
            + "two levels disagree for a reason that has nothing to do with conditioning — the "
            + "mistake would not show up in the output, so it is refused instead"
    }

    private static func unconditionalTooFewGates(_ count: Int) -> String {
        "\(count) gate(s) on this panel; an unconditional test compares two arms and there is only "
            + "one thing here to be an arm"
    }

    private static func unconditionalNoPair(_ history: ObservationHistory) -> String {
        "\(history.count) observed turn(s), but no two gates have different verdict rates; there "
            + "is no block here whose arms could differ"
    }

    private static func unconditionalAllPinned(_ joint: TransportJoint) -> String {
        "\(joint.key): every block of the joint table is pinned by a zero margin, so both arms are "
            + "constants; there is no difference for any test, conditional or not, to find"
    }

    private static func unconditionalUnusablePrecision(
        _ joint: TransportJoint, precision: Double
    ) -> String {
        "\(joint.key): a bracket of \(unconditionalFormat(precision, 8)) is not a positive width, "
            + "and a p-value maximised on a grid is only a bound if the grid's remainder is one; "
            + "reporting the grid maximum instead would err towards rejecting"
    }

    private static func unconditionalUnreadable(_ joint: TransportJoint, items: Int) -> String {
        "\(joint.key): the readable block has \(items) item(s), past what this package will "
            + "enumerate, so the unconditional p-value cannot be computed at all and no smaller "
            + "design was substituted for it"
    }

    private static func unconditionalDetail(
        _ joint: TransportJoint, reading: UnconditionalReading, history: ObservationHistory
    ) -> String {
        var parts = [
            "\(history.count) turn(s), pair \(joint.key); the readable block has "
                + "\(reading.itemCount) item(s), tested at \(reading.level)"
        ]
        parts.append(unconditionalTestLine(reading))
        parts.append(unconditionalSizeLine(reading))
        parts.append(unconditionalLicenceLine())
        return parts.joined(separator: "; ")
    }

    private static func unconditionalTestLine(_ reading: UnconditionalReading) -> String {
        "unconditional p = " + unconditionalFormat(reading.unconditional, 6) + " (bracket "
            + unconditionalFormat(reading.bracket, 6) + " wide, worst shared rate "
            + unconditionalFormat(reading.worstRate) + ", region "
            + "\(reading.regionTables) of \(reading.designTables) table(s)) against Fisher's "
            + unconditionalFormat(reading.conditional, 6) + ", and at this level the two "
            + (reading.decisionsAgree ? "agree" : "DISAGREE about whether there is anything here")
    }

    /// What the level actually costs, or the design that was not audited, named.
    private static func unconditionalSizeLine(_ reading: UnconditionalReading) -> String {
        guard let size = reading.size else {
            return "the row-fixed design of this block has \(reading.designTables) table(s), over "
                + "this stage's audit budget of \(reading.budget), so what each test spends of its "
                + "level was not measured here rather than measured on a smaller design"
        }
        return "on that design the conditional test's actual size is "
            + unconditionalFormat(size.conditionalSize * 100) + "%, "
            + unconditionalFormat(size.conditionalSpend * 100, 1) + "% of the level it claims, "
            + "against the unconditional test's " + unconditionalFormat(size.unconditionalSize * 100)
            + "%, " + unconditionalFormat(size.unconditionalSpend * 100, 1) + "%; unspent level is "
            + "power that was paid for and never collected"
    }

    /// The part this stage refuses to leave implied.
    private static func unconditionalLicenceLine() -> String {
        "the design read here fixes the row margins, and a panel of turns cross-classified by two "
            + "gates fixes neither — this is the same row-fixed reading conditioningCost prices, "
            + "seen from the size side, and it is not yet a guarantee about the design this app has"
    }

    private static func unconditionalFormat(_ value: Double, _ places: Int = 4) -> String {
        String(format: "%.\(places)f", value)
    }
}
