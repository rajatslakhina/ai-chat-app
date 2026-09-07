import AssociationFitKit
import EffectiveVoteKit
import Foundation

extension MetadataPipeline {
    /// How much extra agreement a designed control panel should carry on its diagonal.
    ///
    /// A policy input, like `panelRepairTarget` and `squareRepairRate` before it. What a control
    /// fixture should be built to contain is a choice, and a stage that hides its choice behind a
    /// literal cannot be asked to defend it.
    static let associationDiagonalWeight = 6.0

    /// Audits the structure `squareDesign` leaves to chance.
    func auditAssociationFit(
        trace: inout PipelineTrace,
        store: PanelHistoryStore = .shared
    ) async {
        auditAssociationFit(trace: &trace, history: await store.history)
    }

    /// The same audit over a supplied history.
    ///
    /// `squareDesign` builds a repaired fixture to a target **agreement rate**. On a three-way
    /// panel that pins one number out of nine, and the other eight are whatever the construction
    /// happened to leave — its construction reaches a diagonal by pushing mass into corners, so
    /// the association it produces is an artefact of the method rather than a decision.
    ///
    /// This stage states the association instead and lets the agreement rate follow. It also
    /// prices the step every fixture in this app eventually takes: a fit is real-valued and a
    /// panel is made of whole turns, and **the margins survive that exactly while the association
    /// does not**. The drift is what a coefficient computed over a rounded fixture is quietly
    /// standing on.
    func auditAssociationFit(
        trace: inout PipelineTrace,
        history: ObservationHistory,
        weight: Double = MetadataPipeline.associationDiagonalWeight,
        settings: FitSettings = .standard
    ) {
        guard !history.observations.isEmpty else {
            trace.record(.associationFit, .skipped(reason: Self.associationNothingObserved()))
            return
        }
        let judges = history.judges
        guard judges.count >= 2 else {
            trace.record(.associationFit, .noOp(reason: Self.associationTooFewGates(judges.count)))
            return
        }
        guard let pairing = Self.associationPairing(history, judges: judges) else {
            trace.record(.associationFit, .noOp(reason: Self.associationNoPair(history)))
            return
        }
        switch Self.associationFitted(pairing, weight: weight, settings: settings) {
        case .refused(let message):
            trace.record(.associationFit, .failed(message: message))
        case .built(let outcome):
            trace.record(
                .associationFit,
                .ran(detail: Self.associationDetail(pairing, outcome: outcome, history: history))
            )
        }
    }

    // MARK: - the pair, as three-way verdict margins

    /// One pair of gates and the two verdict margins they imply.
    struct AssociationPairing: Sendable {
        let key: String
        let row: FitMargin
        let column: FitMargin
        let observedTrace: Int
        let liveCategories: Int
    }

    /// The first pair whose two gates did not vote identically, as three-way margins.
    static func associationPairing(
        _ history: ObservationHistory, judges: [JudgeIdentity]
    ) -> AssociationPairing? {
        for left in 0..<judges.count where left + 1 < judges.count {
            for right in (left + 1)..<judges.count {
                let first = Self.squareCodes(history, judge: judges[left])
                let second = Self.squareCodes(history, judge: judges[right])
                let rowCounts = Self.associationTotals(first)
                let columnCounts = Self.associationTotals(second)
                guard rowCounts != columnCounts,
                      let row = try? FitMargin(counts: rowCounts),
                      let column = try? FitMargin(counts: columnCounts) else { continue }
                let live = zip(rowCounts, columnCounts).filter { $0 > 0 || $1 > 0 }.count
                let agreed = zip(first, second).filter { $0 == $1 }.count
                return AssociationPairing(
                    key: "\(judges[left]) / \(judges[right])",
                    row: row, column: column, observedTrace: agreed, liveCategories: live
                )
            }
        }
        return nil
    }

    private static func associationTotals(_ codes: [Int]) -> [Int] {
        var totals = [Int](repeating: 0, count: Verdict.allCases.count)
        for code in codes where code >= 0 && code < totals.count { totals[code] += 1 }
        return totals
    }

    // MARK: - fitting, and what whole turns cost it

    /// What the fit came to.
    struct AssociationOutcome: Sendable, Equatable {
        let iterations: Int
        let fittedAgreement: Double
        let panelAgreement: Double
        let oddsDrift: Double
        let cellDrift: Double
        let marginsExact: Bool
        let undefinedBlocks: Int
        let preservation: Double
    }

    /// Two outcomes, and both are reachable.
    ///
    /// A `diagonalWeight` seed is strictly positive everywhere, so no forbidden-cell pattern can
    /// make these margins unsatisfiable — the zero-pattern refusal this package offers cannot fire
    /// here. What is left is the two genuine policy inputs: a structure no distribution has, and a
    /// pass budget too small to reach the gates' own rates. **A third case for "the gates forbid
    /// it" was written and removed, because nothing could reach it.**
    enum AssociationResult: Sendable {
        case built(AssociationOutcome)
        case refused(String)
    }

    static func associationFitted(
        _ pairing: AssociationPairing, weight: Double, settings: FitSettings = .standard
    ) -> AssociationResult {
        let seed: AssociationSeed
        do {
            seed = try AssociationSeed.diagonalWeight(
                categoryCount: pairing.row.categoryCount, weight: weight
            )
        } catch {
            return .refused("control structure refused: \(error)")
        }
        let fitted: FittedTable
        do {
            fitted = try ProportionalFit.fit(
                seed: seed, row: pairing.row, column: pairing.column, settings: settings
            )
        } catch {
            return .refused(associationNoFixture(pairing, error: error))
        }
        let report = fitted.report()
        let panel = report.panel
        return .built(
            AssociationOutcome(
                iterations: fitted.iterations,
                fittedAgreement: fitted.agreementRate,
                panelAgreement: panel.agreementRate,
                oddsDrift: report.oddsRatioDrift,
                cellDrift: report.cellDrift,
                marginsExact: report.marginsExact,
                undefinedBlocks: panel.localOdds.undefinedCount,
                preservation: fitted.localOdds.maximumRelativeDeviation(
                    from: LocalOddsRatios(table: seed.weights)
                )
            )
        )
    }

    // MARK: - the outcomes

    private static func associationNothingObserved() -> String {
        "no turn observed yet; an association is a claim about how two gates' verdicts move "
            + "together, and neither gate has cast one"
    }

    private static func associationTooFewGates(_ count: Int) -> String {
        "\(count) gate(s) on this panel; an association is a property of a pair and there is no pair"
    }

    private static func associationNoPair(_ history: ObservationHistory) -> String {
        "\(history.count) observed turn(s), but no two gates have different verdict rates; two "
            + "gates with identical margins are one gate for this purpose"
    }

    /// The fit ran out of passes before it reached these gates' rates.
    private static func associationNoFixture(
        _ pairing: AssociationPairing, error: Error
    ) -> String {
        "\(pairing.key): the control fixture did not reach these gates' verdict rates — \(error)"
    }

    private static func associationDetail(
        _ pairing: AssociationPairing, outcome: AssociationOutcome, history: ObservationHistory
    ) -> String {
        var parts = [
            "\(history.count) turn(s), pair \(pairing.key) with \(pairing.liveCategories) live "
                + "verdict categories; a control fixture on these gates' own rates carrying a "
                + "diagonal weight of \(format(MetadataPipeline.associationDiagonalWeight, 1)) "
                + "would agree at " + format(outcome.fittedAgreement)
        ]
        parts.append(
            "the fit reached those rates in \(outcome.iterations) pass(es) and moved the "
                + "structure it was told to keep by " + scientific(outcome.preservation)
        )
        parts.append(
            "made of whole turns it agrees at " + format(outcome.panelAgreement)
                + ", margins " + (outcome.marginsExact ? "exact" : "MOVED")
                + ", association shifted " + scientific(outcome.oddsDrift)
                + " and no cell by more than " + format(outcome.cellDrift, 3)
        )
        if outcome.undefinedBlocks > 0 {
            parts.append(
                "\(outcome.undefinedBlocks) block(s) of the rounded panel contain a zero, so their "
                    + "odds ratio is absent rather than large — these gates simply never produce "
                    + "those verdict combinations"
            )
        }
        parts.append(
            "the observed panel agrees on \(pairing.observedTrace) of \(history.count) turn(s); "
                + "the gap to the designed figure is how far this app's real fixture sits from one "
                + "built on purpose"
        )
        return parts.joined(separator: "; ")
    }

    private static func format(_ value: Double, _ places: Int = 4) -> String {
        String(format: "%.\(places)f", value)
    }

    private static func scientific(_ value: Double) -> String {
        value == 0 ? "0" : String(format: "%.3e", value)
    }
}
