import ConditioningCostKit
import EffectiveVoteKit
import ExactAssociationKit
import Foundation

extension MetadataPipeline {
    /// The level this stage prices, which must be the level `exactAssociation` draws at.
    static let conditioningCostConfidence = ExactConfidence.ninetyFive

    /// The largest enumeration this stage will run for one design.
    ///
    /// Coverage here is a finite sum over every table a design can produce, and a total-fixed
    /// design of `n` items has `(n+1)(n+2)(n+3)/6` of them — 156849 at ninety-six items, which is
    /// about twenty seconds. This stage is off the critical path, not free, so it prices the
    /// designs it can afford and says in its own detail which one it could not, with the table
    /// count. Substituting a cheaper design and not saying so would answer a question about a
    /// different experiment.
    static let conditioningCostTableBudget = 400

    /// Prices what `exactAssociation`'s guarantee is conditional on.
    func auditConditioningCost(
        trace: inout PipelineTrace,
        store: PanelHistoryStore = .shared
    ) async {
        auditConditioningCost(trace: &trace, history: await store.history)
    }

    /// The same audit over a supplied history.
    ///
    /// `exactAssociation` replaced a Woolf interval with an exact one, and exactness there comes
    /// from conditioning on all four margins. That removes the nuisance parameter, and it is free
    /// only when the design fixed those margins. This panel fixed neither: each turn is judged by
    /// two gates and no margin is chosen in advance, which makes the design total-fixed. The
    /// difference is measurable rather than arguable, and this stage measures it.
    func auditConditioningCost(
        trace: inout PipelineTrace,
        history: ObservationHistory,
        confidence: ExactConfidence = MetadataPipeline.conditioningCostConfidence,
        pricedAt asymptotic: ExactConfidence = MetadataPipeline.exactAssociationConfidence,
        budget: Int = MetadataPipeline.conditioningCostTableBudget
    ) {
        guard !history.observations.isEmpty else {
            trace.record(.conditioningCost, .skipped(reason: Self.conditioningNothingObserved()))
            return
        }
        guard confidence.label == asymptotic.label else {
            trace.record(
                .conditioningCost,
                .failed(message: Self.conditioningLevelMismatch(confidence, asymptotic))
            )
            return
        }
        let judges = history.judges
        guard judges.count >= 2 else {
            trace.record(.conditioningCost, .noOp(reason: Self.conditioningTooFewGates(judges.count)))
            return
        }
        guard let joint = Self.transportJoint(history, judges: judges) else {
            trace.record(.conditioningCost, .noOp(reason: Self.conditioningNoPair(history)))
            return
        }
        switch Self.conditioningRead(joint, confidence: confidence, budget: budget) {
        case .refused(let message):
            trace.record(.conditioningCost, .failed(message: message))
        case .nothingToPrice(let reason):
            trace.record(.conditioningCost, .noOp(reason: reason))
        case .priced(let outcome):
            trace.record(
                .conditioningCost,
                .ran(detail: Self.conditioningDetail(joint, outcome: outcome, history: history))
            )
        }
    }

    // MARK: - what the pricing found

    /// One design's reading of the block, or the reason it was not enumerated.
    struct ConditioningReading: Sendable, Equatable {
        let design: String
        let tables: Int
        let licensed: Bool
        let exactCoverage: Double
        let coverageAmongRead: Double
        let declinedMass: Double
        let widthPremium: Double
    }

    /// What the block turned out to cost.
    struct ConditioningOutcome: Sendable, Equatable {
        let itemCount: Int
        let level: String
        let readings: [ConditioningReading]
        /// The table count a total-fixed enumeration of this block would need.
        let totalFixedTables: Int
        /// Whether that enumeration fit inside the budget and was actually run.
        let totalFixedPriced: Bool
        let budget: Int
    }

    /// Three outcomes, and all three are reachable.
    ///
    /// `nothingToPrice` is what a panel whose blocks are all pinned by a zero margin gives: there
    /// is no interval on it for any design to be right or wrong about, so there is no cost either.
    /// It is the same state `exactAssociation` reports as `nothingEstimable`, seen one stage later.
    enum ConditioningResult: Sendable {
        case priced(ConditioningOutcome)
        case nothingToPrice(String)
        case refused(String)
    }

    /// One design this stage will price, named so the list of them is not a list of tuples.
    struct PricedDesign: Sendable {
        let label: String
        let frame: TableFrame
        let truth: TruthParameter
    }

    static func conditioningRead(
        _ joint: TransportJoint,
        confidence: ExactConfidence,
        budget: Int
    ) -> ConditioningResult {
        guard let audit = try? ExactAssociation.audit(joint.panel),
              let reading = audit.readings.first else {
            return .nothingToPrice(Self.conditioningAllPinned(joint))
        }
        let block = reading.block
        let items = block.itemCount
        let totalFixedTables = (items + 1) * (items + 2) * (items + 3) / 6
        var priced: [ConditioningReading] = []
        for design in Self.conditioningDesigns(block, budget: budget) {
            guard let entry = Self.conditioningPrice(design, at: confidence) else {
                return .refused(Self.conditioningUnpriceable(joint, design: design.label))
            }
            priced.append(entry)
        }
        return .priced(
            ConditioningOutcome(
                itemCount: items,
                level: confidence.label,
                readings: priced,
                totalFixedTables: totalFixedTables,
                totalFixedPriced: totalFixedTables <= budget,
                budget: budget
            )
        )
    }

    /// The designs worth pricing for `block`, in order, dropping the ones over `budget`.
    ///
    /// The doubly-fixed design is never dropped. Its enumeration is the block's own conditional
    /// support — at most one table per possible corner count — so it is cheap at any panel size,
    /// and it is the one design the exact interval was built for. A stage that could not afford it
    /// would have nothing to compare against.
    static func conditioningDesigns(_ block: ExactBlock, budget: Int) -> [PricedDesign] {
        var designs = [
            PricedDesign(
                label: "both margins fixed",
                frame: .bothMarginsFixed(
                    rowTotal: block.rowTotal,
                    otherRowTotal: block.otherRowTotal,
                    columnTotal: block.columnTotal
                ),
                truth: .oddsRatio(1)
            )
        ]
        let items = block.itemCount
        if (block.rowTotal + 1) * (block.otherRowTotal + 1) <= budget {
            designs.append(
                PricedDesign(
                    label: "row margins fixed",
                    frame: .rowMarginsFixed(rowTotal: block.rowTotal, otherRowTotal: block.otherRowTotal),
                    truth: .binomial(
                        p1: Double(block.a) / Double(block.rowTotal),
                        p2: Double(block.c) / Double(block.otherRowTotal)
                    )
                )
            )
        }
        if (items + 1) * (items + 2) * (items + 3) / 6 <= budget {
            designs.append(
                PricedDesign(
                    label: "total fixed",
                    frame: .totalFixed(itemCount: items),
                    truth: TruthGrid.cells(
                        rowRate: Double(block.rowTotal) / Double(items),
                        columnRate: Double(block.columnTotal) / Double(items),
                        oddsRatio: 1
                    )
                )
            )
        }
        return designs
    }

    /// One design's reading, or `nil` when it could not be enumerated at all.
    static func conditioningPrice(
        _ design: PricedDesign,
        at confidence: ExactConfidence
    ) -> ConditioningReading? {
        guard let cost = try? ConditioningCost.measure(
                frame: design.frame, truth: design.truth, at: confidence
              ),
              let exact = cost.reading(.exactConditional) else {
            return nil
        }
        return ConditioningReading(
            design: design.label,
            tables: exact.tableCount,
            licensed: cost.conditioningIsLicensed,
            exactCoverage: exact.actualCoverage,
            coverageAmongRead: exact.coverageAmongRead,
            declinedMass: exact.declinedMass,
            widthPremium: cost.widthPremium
        )
    }

    // MARK: - the outcomes

    private static func conditioningNothingObserved() -> String {
        "no turn observed yet; the cost of an assumption is a statement about a design that has "
            + "produced data, and this one has produced none"
    }

    private static func conditioningLevelMismatch(
        _ mine: ExactConfidence, _ theirs: ExactConfidence
    ) -> String {
        "this stage prices at \(mine.label) while exactAssociation draws its intervals at "
            + "\(theirs.label); every number here is a difference between coverages, and two levels "
            + "differ for a reason that has nothing to do with conditioning — the mistake would not "
            + "show up in the output, so it is refused instead"
    }

    private static func conditioningTooFewGates(_ count: Int) -> String {
        "\(count) gate(s) on this panel; the intervals this stage prices are drawn around a pair "
            + "and there is no pair"
    }

    private static func conditioningNoPair(_ history: ObservationHistory) -> String {
        "\(history.count) observed turn(s), but no two gates have different verdict rates; there "
            + "is no joint table here whose blocks could be priced"
    }

    private static func conditioningAllPinned(_ joint: TransportJoint) -> String {
        "\(joint.key): every block of the joint table is pinned by a zero margin, so no design "
            + "produces an interval here that could be right or wrong about anything; there is no "
            + "assumption in play and therefore nothing it costs"
    }

    private static func conditioningUnpriceable(_ joint: TransportJoint, design: String) -> String {
        "\(joint.key): the \(design) design could not be enumerated for this block, so the cost of "
            + "conditioning on its margins cannot be stated at all"
    }

    private static func conditioningDetail(
        _ joint: TransportJoint, outcome: ConditioningOutcome, history: ObservationHistory
    ) -> String {
        var parts = [
            "\(history.count) turn(s), pair \(joint.key); the readable block has "
                + "\(outcome.itemCount) item(s) and its interval is drawn at \(outcome.level)"
        ]
        parts.append(contentsOf: outcome.readings.map(conditioningReadingLine))
        parts.append(conditioningLicenceLine(outcome))
        parts.append(conditioningBudgetLine(outcome))
        return parts.joined(separator: "; ")
    }

    private static func conditioningReadingLine(_ reading: ConditioningReading) -> String {
        "under \(reading.design) (\(reading.tables) table(s), conditioning "
            + (reading.licensed ? "licensed" : "not licensed") + ") the exact interval covers "
            + conditioningFormat(reading.exactCoverage * 100, 4) + "% overall and "
            + conditioningFormat(reading.coverageAmongRead * 100, 4) + "% among the tables it reads, "
            + "declining " + conditioningFormat(reading.declinedMass * 100, 4)
            + "% of them, at " + conditioningFormat(reading.widthPremium, 4) + "x the asymptotic width"
    }

    /// The part that is the point: the same block, the same claim, and a different answer per design.
    ///
    /// The spread is reduced from the first reading rather than taken with `max()` and a default.
    /// The guard below has already established that an unlicensed reading exists, so the collection
    /// cannot be empty here and a `?? 0` would be a claim no test could reach.
    private static func conditioningLicenceLine(_ outcome: ConditioningOutcome) -> String {
        guard let first = outcome.readings.first(where: { !$0.licensed }) else {
            return "only the design that licenses conditioning was affordable here, so nothing on "
                + "this panel yet says what conditioning costs"
        }
        let spread = outcome.readings.map(\.exactCoverage)
        let widest = spread.reduce(first.exactCoverage, Swift.max)
            - spread.reduce(first.exactCoverage, Swift.min)
        return "the same block under \(outcome.readings.count) design(s) at the same \(outcome.level) "
            + "claim spans " + conditioningFormat(widest * 100, 4)
            + " percentage point(s) of actual coverage, and the design is not an argument to any "
            + "interval this app computes"
    }

    /// What was not enumerated, named rather than quietly replaced.
    private static func conditioningBudgetLine(_ outcome: ConditioningOutcome) -> String {
        guard !outcome.totalFixedPriced else {
            return "the total-fixed design this panel actually has was enumerated in full, at "
                + "\(outcome.totalFixedTables) table(s)"
        }
        return "the total-fixed design this panel actually has needs \(outcome.totalFixedTables) "
            + "table(s), over this stage's budget of \(outcome.budget), so it was not enumerated; "
            + "the readings above are of designs that fix more than this one did"
    }

    private static func conditioningFormat(_ value: Double, _ places: Int = 4) -> String {
        String(format: "%.\(places)f", value)
    }
}
