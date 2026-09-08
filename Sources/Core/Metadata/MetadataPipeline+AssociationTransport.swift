import AssociationFitKit
import AssociationTransportKit
import EffectiveVoteKit
import Foundation

extension MetadataPipeline {
    /// How the stage reads an empty cell when it is allowed to read one at all.
    ///
    /// A policy input, like `associationDiagonalWeight` before it. Half an item is the
    /// conventional amount and it is not arbitrary — it is what a Jeffreys prior does to a
    /// binomial — but it is still a choice, and a stage that hides its choice behind a literal
    /// cannot be asked to defend it.
    static let associationTransportCorrection = 0.5

    /// How this stage reads the panel's empty cells.
    ///
    /// The stage's whole subject expressed as its input. `associationFit` has no equivalent —
    /// a designed structure has no empty cells to interpret — and a stage that reported one
    /// reading without naming it would be presenting a decision as a measurement.
    static let associationTransportPolicy = ZeroPolicy.corrected(
        by: MetadataPipeline.associationTransportCorrection
    )

    /// Audits the structure `associationFit` designs, on the panel this app actually has.
    func auditAssociationTransport(
        trace: inout PipelineTrace,
        store: PanelHistoryStore = .shared
    ) async {
        auditAssociationTransport(trace: &trace, history: await store.history)
    }

    /// The same audit over a supplied history.
    ///
    /// `associationFit` fits a control structure onto the gates' verdict **margins**. This reads
    /// the structure the gates' **joint** verdicts already carry — a table nothing else in this
    /// app builds — and prices what it took to read it: which cells had to be filled in before a
    /// ratio existed, and how much of the result the panel is large enough to distinguish from
    /// independence.
    func auditAssociationTransport(
        trace: inout PipelineTrace,
        history: ObservationHistory,
        policy: ZeroPolicy = MetadataPipeline.associationTransportPolicy
    ) {
        guard !history.observations.isEmpty else {
            trace.record(.associationTransport, .skipped(reason: Self.transportNothingObserved()))
            return
        }
        let judges = history.judges
        guard judges.count >= 2 else {
            trace.record(.associationTransport, .noOp(reason: Self.transportTooFewGates(judges.count)))
            return
        }
        guard let joint = Self.transportJoint(history, judges: judges) else {
            trace.record(.associationTransport, .noOp(reason: Self.transportNoPair(history)))
            return
        }
        switch Self.transportRead(joint, policy: policy) {
        case .refused(let message):
            trace.record(.associationTransport, .failed(message: message))
        case .read(let outcome):
            trace.record(
                .associationTransport,
                .ran(detail: Self.transportDetail(joint, outcome: outcome, history: history))
            )
        }
    }

    // MARK: - the joint table, which is the part nothing else here builds

    /// One pair of gates and the table their verdicts landed in together.
    struct TransportJoint: Sendable {
        let key: String
        let panel: ObservedPanel
        let agreedTurns: Int
    }

    /// The first pair of gates whose joint table is not degenerate.
    ///
    /// The margins are what `associationFit` uses and they are a projection: two gates with the
    /// same margins can have opposite associations, and two with different margins can have the
    /// same one. Only the joint counts carry it.
    static func transportJoint(
        _ history: ObservationHistory, judges: [JudgeIdentity]
    ) -> TransportJoint? {
        let size = Verdict.allCases.count
        for left in judges.indices where left + 1 < judges.count {
            for right in (left + 1)..<judges.count {
                let first = Self.squareCodes(history, judge: judges[left])
                let second = Self.squareCodes(history, judge: judges[right])
                var counts = [[Int]](repeating: [Int](repeating: 0, count: size), count: size)
                for (row, column) in zip(first, second) where row < size && column < size {
                    counts[row][column] += 1
                }
                guard let panel = try? ObservedPanel(counts: counts),
                      panel.rowMargin.counts != panel.columnMargin.counts else { continue }
                return TransportJoint(
                    key: "\(judges[left]) / \(judges[right])",
                    panel: panel,
                    agreedTurns: zip(first, second).filter { $0 == $1 }.count
                )
            }
        }
        return nil
    }

    // MARK: - reading it, and what reading it cost

    /// What the panel turned out to say.
    struct TransportOutcome: Sendable, Equatable {
        let emptyCells: Int
        let readsUndecided: Bool
        let structuralBlocks: Int
        let correctedBlocks: Int
        let invoice: TransportInvoice?
        let distinguishable: Int
        let widestInterval: Double
        let itemsToDistinguish: Int?
    }

    /// Two outcomes, and both are reachable.
    ///
    /// The refusal is not a hypothetical. Reading an empty cell as forbidden makes it a cell no
    /// fit can move mass into, and when a whole verdict category is empty — which it is on this
    /// panel, because no gate here has ever abstained — the seed has an entirely forbidden line
    /// and cannot be built at all. That is the reading this stage exists to make visible, so it
    /// is taken first and reported when it fails rather than skipped past.
    /// What a correction cost, when one was applied.
    struct TransportInvoice: Sendable, Equatable {
        let invented: Int
        let largestChange: Double
        let movedAway: Int
        let unmoved: Int
    }

    enum TransportResult: Sendable {
        case read(TransportOutcome)
        case refused(String)
    }

    static func transportRead(_ joint: TransportJoint, policy: ZeroPolicy) -> TransportResult {
        let panel = joint.panel
        let readsUndecided = (try? StructureMeasurement.measure(panel, policy: .refuse)) != nil
        // Counted rather than measured. `.structural` is the one policy that cannot refuse — it
        // returns the panel's counts unchanged — so measuring under it to read the count back
        // would need a fallback for an error that has no way to happen, and a fallback nothing
        // can reach is a line no test can cover. A block keeps its ratio exactly when none of its
        // four cells is empty, which is the same answer and needs no call.
        let structuralBlocks = panel.blocks.filter { !panel.cells(of: $0).contains(0) }.count
        let structure: MeasuredStructure
        do {
            structure = try StructureMeasurement.measure(panel, policy: policy)
        } catch {
            return .refused(Self.transportUnreadable(joint, error: error))
        }
        return .read(
            TransportOutcome(
                emptyCells: panel.emptyCells.count,
                readsUndecided: readsUndecided,
                structuralBlocks: structuralBlocks,
                correctedBlocks: structure.readings.count,
                invoice: structure.invoice.map {
                    TransportInvoice(
                        invented: $0.inventedBlocks.count,
                        largestChange: $0.largestRelativeChange,
                        movedAway: $0.blocksMovedAway.count,
                        unmoved: $0.blocksUnmoved.count
                    )
                },
                distinguishable: structure.distinguishableCount,
                widestInterval: structure.widestIntervalRatio,
                itemsToDistinguish: Self.transportCheapestClaim(structure)
            )
        )
    }

    /// The fewest items any block would need to separate its ratio from independence.
    ///
    /// `nil` when no block has one: a ratio of exactly `1.0` is centred on independence at every
    /// sample size, and on a fully crossed corpus that is most of them.
    static func transportCheapestClaim(_ structure: MeasuredStructure) -> Int? {
        structure.readings
            .filter { $0.coversIndependence }
            .compactMap { $0.itemsRequiredToDistinguish() }
            .min()
    }

    // MARK: - the outcomes

    private static func transportNothingObserved() -> String {
        "no turn observed yet; an association is a statement about how two gates' verdicts fall "
            + "together and no pair has fallen yet"
    }

    private static func transportTooFewGates(_ count: Int) -> String {
        "\(count) gate(s) on this panel; a joint table needs two gates and there is no pair"
    }

    private static func transportNoPair(_ history: ObservationHistory) -> String {
        "\(history.count) observed turn(s), but no two gates have different verdict rates; two "
            + "gates with identical margins are one gate for this purpose"
    }

    private static func transportUnreadable(_ joint: TransportJoint, error: Error) -> String {
        "\(joint.key): the joint table could not be read even with a correction — \(error)"
    }

    private static func transportDetail(
        _ joint: TransportJoint, outcome: TransportOutcome, history: ObservationHistory
    ) -> String {
        let panel = joint.panel
        let cells = panel.categoryCount * panel.categoryCount
        var parts = [
            "\(history.count) turn(s), pair \(joint.key); the joint table nothing else here builds "
                + "has \(outcome.emptyCells) of \(cells) cells empty and agrees on "
                + "\(joint.agreedTurns) turn(s), a rate of " + format(panel.agreementRate)
        ]
        parts.append(transportDecisionLine(outcome))
        parts.append(transportReadingLine(outcome, blockCount: panel.blockCount))
        parts.append(
            "\(outcome.distinguishable) of \(panel.blockCount) block(s) clear independence at 95% "
                + "on \(panel.itemCount) item(s), the widest interval spanning a factor of "
                + format(outcome.widestInterval, 1)
        )
        parts.append(transportPrecisionLine(outcome))
        if let invoice = outcome.invoice {
            parts.append(
                "the correction moved the comparable ratios by at most "
                    + format(invoice.largestChange)
                    + " (\(invoice.movedAway) away from independence, "
                    + "\(invoice.unmoved) not at all)"
            )
        }
        return parts.joined(separator: "; ")
    }

    /// Whether the panel could be read at all without deciding what an absence means.
    private static func transportDecisionLine(_ outcome: TransportOutcome) -> String {
        outcome.readsUndecided
            ? "no cell is empty, so the structure can be read without deciding what an absence "
                + "means"
            : "read without deciding what an absence means it refuses, and it is right to: a count "
                + "of zero here is either a rule these gates follow or a pair they have not met, "
                + "and nothing in the counts says which"
    }

    /// What each of the two readings kept, and what the applied one had to invent.
    private static func transportReadingLine(
        _ outcome: TransportOutcome, blockCount: Int
    ) -> String {
        guard let invoice = outcome.invoice else {
            return "read as rules, \(outcome.correctedBlocks) of \(blockCount) block(s) keep a "
                + "ratio and nothing was invented to reach that; the blocks that touch an empty "
                + "cell are reported as absent rather than filled in"
        }
        return "read as rules, \(outcome.structuralBlocks) of \(blockCount) block(s) keep a "
            + "ratio; read as absences, \(outcome.correctedBlocks) do, of which "
            + "\(invoice.invented) exist only because "
            + format(MetadataPipeline.associationTransportCorrection, 1)
            + " was added to every cell"
    }

    /// What the cheapest claim this panel could support would cost, if any could.
    private static func transportPrecisionLine(_ outcome: TransportOutcome) -> String {
        guard let needed = outcome.itemsToDistinguish else {
            return "no covered block could be separated at any sample size; their ratios are "
                + "exactly 1.0, which is what a fully crossed corpus produces"
        }
        return "the cheapest claim any covered block could support would take \(needed) item(s) "
            + "at this panel's shape"
    }

    private static func format(_ value: Double, _ places: Int = 4) -> String {
        String(format: "%.\(places)f", value)
    }
}
