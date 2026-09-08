import AssociationTransportKit
import EffectiveVoteKit
import ExactAssociationKit
import Foundation

extension MetadataPipeline {
    /// The level this stage draws both of its intervals at.
    ///
    /// A policy input for the same reason `associationTransportPolicy` is one. The comparison this
    /// stage exists to make is between two intervals around the same parameter **at the same
    /// level**, and a stage that hid the level behind a literal could not be asked whether the two
    /// sides matched.
    static let exactAssociationConfidence = ExactConfidence.ninetyFive

    /// The level the asymptotic side is drawn at, which must agree with the one above.
    static let exactAssociationAsymptoticConfidence = ConfidenceLevel.ninetyFive

    /// How the asymptotic side reads an empty cell here: it does not.
    ///
    /// `.structural` adds nothing to any count, so a block that both sides can read is read by
    /// both from the same integers. `associationTransport` corrects and says what the correction
    /// cost; this stage declines to correct, so that its width comparison is method against method
    /// rather than method against repair.
    static let exactAssociationPolicy = ZeroPolicy.structural

    /// Audits the intervals `associationTransport` reports.
    func auditExactAssociation(
        trace: inout PipelineTrace,
        store: PanelHistoryStore = .shared
    ) async {
        auditExactAssociation(trace: &trace, history: await store.history)
    }

    /// The same audit over a supplied history.
    ///
    /// `associationTransport` reads the joint table's structure and puts a **Woolf** interval
    /// around every block of it — a normal approximation on the log scale, valid in the limit of
    /// large counts. This panel is not large. Conditioning a block on all four of its margins
    /// leaves the odds ratio as the only parameter of a distribution over a finite support, so the
    /// interval it approximates can be summed exactly, and this stage reports the difference.
    func auditExactAssociation(
        trace: inout PipelineTrace,
        history: ObservationHistory,
        confidence: ExactConfidence = MetadataPipeline.exactAssociationConfidence,
        asymptotic: ConfidenceLevel = MetadataPipeline.exactAssociationAsymptoticConfidence,
        policy: ZeroPolicy = MetadataPipeline.exactAssociationPolicy
    ) {
        guard !history.observations.isEmpty else {
            trace.record(.exactAssociation, .skipped(reason: Self.exactNothingObserved()))
            return
        }
        let judges = history.judges
        guard judges.count >= 2 else {
            trace.record(.exactAssociation, .noOp(reason: Self.exactTooFewGates(judges.count)))
            return
        }
        guard let joint = Self.transportJoint(history, judges: judges) else {
            trace.record(.exactAssociation, .noOp(reason: Self.exactNoPair(history)))
            return
        }
        switch Self.exactRead(joint, confidence: confidence, asymptotic: asymptotic, policy: policy) {
        case .refused(let message):
            trace.record(.exactAssociation, .failed(message: message))
        case .nothingEstimable(let reason):
            trace.record(.exactAssociation, .noOp(reason: reason))
        case .read(let outcome):
            trace.record(
                .exactAssociation,
                .ran(detail: Self.exactDetail(joint, outcome: outcome, history: history))
            )
        }
    }

    // MARK: - what the audit found

    /// What the panel turned out to support.
    struct ExactOutcome: Sendable, Equatable {
        let blocks: Int
        let readable: Int
        let pinned: Int
        let compared: Int
        let disagreements: Int
        let distinguishable: Int
        let widestUnderstatement: Double
        let level: String
        /// Seeded at `1`, which is the largest a p-value can be, so no block lowers it wrongly and
        /// the field needs no optional for a case the outcome above has already excluded.
        let smallestFisherP: Double
        /// Seeded at `1`, which is the smallest the exact interval can be relative to its own
        /// mid-p counterpart, since the exact interval always contains it.
        let conservatism: Double
    }

    /// Three outcomes, and all three are reachable.
    ///
    /// `nothingEstimable` is not a defensive branch. A gate that has only ever returned one
    /// verdict gives every block of the joint table a zero margin, and a zero margin **determines**
    /// the block: its counts are fixed by the margins alone, so there is no odds ratio in it for
    /// any method to estimate. Reporting an interval for such a block is not imprecise, it is
    /// fictional, and the honest outcome is to say the panel supports nothing rather than to
    /// report zero of zero blocks distinguishable.
    enum ExactResult: Sendable {
        case read(ExactOutcome)
        case nothingEstimable(String)
        case refused(String)
    }

    static func exactRead(
        _ joint: TransportJoint,
        confidence: ExactConfidence,
        asymptotic: ConfidenceLevel,
        policy: ZeroPolicy
    ) -> ExactResult {
        let panel = joint.panel
        let audit: ExactAudit
        do {
            let structure = try StructureMeasurement.measure(
                panel, policy: policy, confidence: asymptotic
            )
            audit = try ExactAssociation.audit(structure, at: confidence)
        } catch {
            return .refused(Self.exactUnreadable(joint, error: error))
        }
        guard !audit.readings.isEmpty else {
            return .nothingEstimable(Self.exactAllPinned(joint, audit: audit))
        }
        return .read(
            ExactOutcome(
                blocks: audit.blockCount,
                readable: audit.readings.count,
                pinned: audit.degenerateBlocks.count,
                compared: audit.comparisons.count,
                disagreements: audit.disagreementCount,
                distinguishable: audit.distinguishableCount,
                widestUnderstatement: audit.widestUnderstatement,
                level: confidence.label,
                smallestFisherP: audit.readings.reduce(1) { Swift.min($0, $1.fisherP) },
                conservatism: audit.readings
                    .map(\.conservatism)
                    .filter(\.isFinite)
                    .reduce(1) { Swift.max($0, $1) }
            )
        )
    }

    // MARK: - the outcomes

    private static func exactNothingObserved() -> String {
        "no turn observed yet; an interval is a statement about how much a panel has seen and this "
            + "one has seen nothing"
    }

    private static func exactTooFewGates(_ count: Int) -> String {
        "\(count) gate(s) on this panel; the intervals this stage checks are drawn around a pair "
            + "and there is no pair"
    }

    private static func exactNoPair(_ history: ObservationHistory) -> String {
        "\(history.count) observed turn(s), but no two gates have different verdict rates; there "
            + "is no joint table here whose blocks could be estimated"
    }

    private static func exactAllPinned(_ joint: TransportJoint, audit: ExactAudit) -> String {
        "\(joint.key): all \(audit.degenerateBlocks.count) block(s) of the joint table have a "
            + "margin of zero, which determines their counts outright; there is no odds ratio in "
            + "any of them for either method to estimate, and an interval reported for one would "
            + "be fiction rather than an approximation"
    }

    private static func exactUnreadable(_ joint: TransportJoint, error: Error) -> String {
        "\(joint.key): the exact and asymptotic sides could not be compared — \(error)"
    }

    private static func exactDetail(
        _ joint: TransportJoint, outcome: ExactOutcome, history: ObservationHistory
    ) -> String {
        var parts = [
            "\(history.count) turn(s), pair \(joint.key); of \(outcome.blocks) block(s) "
                + "\(outcome.readable) have an odds ratio to estimate and \(outcome.pinned) are "
                + "pinned by a zero margin"
        ]
        parts.append(exactPinnedLine(outcome))
        parts.append(exactComparisonLine(outcome))
        parts.append(
            "\(outcome.distinguishable) of \(outcome.blocks) block(s) clear independence exactly "
                + "at \(outcome.level) on "
                + "\(joint.panel.itemCount) item(s)"
        )
        parts.append(exactTestLine(outcome))
        parts.append(exactGuaranteeLine(outcome))
        return parts.joined(separator: "; ")
    }

    /// What a pinned block means for the numbers the stage above it reported.
    private static func exactPinnedLine(_ outcome: ExactOutcome) -> String {
        guard outcome.pinned > 0 else {
            return "every block's counts are free given its margins, so every ratio the transport "
                + "stage reported is one this panel actually contains"
        }
        return "a pinned block's counts are fixed by its margins alone, so the \(outcome.pinned) "
            + "ratio(s) the transport stage reported for those exist only because half an item "
            + "was added to cells nobody landed in"
    }

    /// How the two methods compared where both could read.
    private static func exactComparisonLine(_ outcome: ExactOutcome) -> String {
        guard outcome.compared > 0 else {
            return "no block is readable by both methods on these counts, so there is nothing to "
                + "compare the asymptotic interval against"
        }
        return "\(outcome.compared) block(s) both methods read from the same integers, of which "
            + "\(outcome.disagreements) reach opposite conclusions about independence; the exact "
            + "interval is up to " + exactFormat(outcome.widestUnderstatement, 3)
            + "x wider on the log scale"
    }

    /// What an exact test says, which is not the same question as whether an interval covers one.
    private static func exactTestLine(_ outcome: ExactOutcome) -> String {
        "the strongest exact evidence any block carries is a Fisher two-sided p of "
            + exactFormat(outcome.smallestFisherP, 6)
    }

    /// What the exact method's guarantee costs against its mid-p counterpart.
    ///
    /// Blocks whose interval is unbounded on one side are left out of this figure rather than
    /// reported as infinitely conservative: both intervals are unbounded there and their ratio is
    /// not a number, which is a fact about the block rather than a measurement of the method.
    private static func exactGuaranteeLine(_ outcome: ExactOutcome) -> String {
        "the guarantee is not free: a discrete support cannot place a tail probability at "
            + "exactly 0.025, so the exact interval runs up to " + exactFormat(outcome.conservatism, 3)
            + "x wider than the mid-p one it overshoots"
    }

    private static func exactFormat(_ value: Double, _ places: Int = 4) -> String {
        String(format: "%.\(places)f", value)
    }
}
