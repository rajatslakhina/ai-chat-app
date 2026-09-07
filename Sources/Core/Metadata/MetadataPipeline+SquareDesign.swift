import EffectiveVoteKit
import Foundation
import SquareDesignKit

extension MetadataPipeline {
    /// The agreement rate a repaired three-way fixture would be built to carry.
    ///
    /// A policy input rather than a constant, for the same reason `panelRepairTarget` is one:
    /// what a control panel should agree at is a choice, and a stage that hides it behind a
    /// literal cannot be asked to justify it.
    static let squareRepairRate = 0.6

    /// Audits the panel `panelDesign` collapsed to two categories.
    func auditSquareDesign(
        trace: inout PipelineTrace,
        store: PanelHistoryStore = .shared
    ) async {
        auditSquareDesign(trace: &trace, history: await store.history)
    }

    /// The same audit over a supplied history.
    ///
    /// Every stage above this one, `panelDesign` included, reads the gates as a binary affirm
    /// grid. The gates do not produce one: they affirm, deny or abstain, and collapsing that to
    /// affirmed-or-not is a decision taken before any measurement, on every turn. Restoring the
    /// third case makes two questions answerable that the binary panel cannot pose — which
    /// agreement counts inside the attainable range no panel with these verdict rates reaches,
    /// and what a fixture built to a target rate on those same rates would agree at.
    func auditSquareDesign(
        trace: inout PipelineTrace,
        history: ObservationHistory,
        rate: Double = MetadataPipeline.squareRepairRate
    ) {
        guard !history.observations.isEmpty else {
            trace.record(.squareDesign, .skipped(reason: Self.squareNothingObserved()))
            return
        }
        let judges = history.judges
        guard judges.count >= 2 else {
            trace.record(.squareDesign, .noOp(reason: Self.squareTooFewGates(judges.count)))
            return
        }
        let pairs = Self.squarePairs(history, judges: judges)
        guard let widest = pairs.max(by: { $0.priced.upperTrace < $1.priced.upperTrace }) else {
            trace.record(.squareDesign, .noOp(reason: Self.squareNoPair(history)))
            return
        }
        let tally = Self.squareTally(pairs)
        guard tally.usedCategories > 2 else {
            trace.record(.squareDesign, .noOp(reason: Self.squareStillBinary(tally, history: history)))
            return
        }
        switch Self.squareRepair(widest, rate: rate) {
        case .refused(let message):
            trace.record(.squareDesign, .failed(message: message))
        case .built(let trace_, let agreement):
            trace.record(.squareDesign, .ran(detail: Self.squareDetail(
                tally, history: history, widest: widest, builtTrace: trace_, agreement: agreement
            )))
        }
    }

    // MARK: - the three-way panel the affirm grid discards

    /// One pair of gates, as the three-way verdicts they actually cast.
    struct SquarePairing: Sendable {
        let key: String
        let observed: Int
        let priced: AttainableTrace
    }

    /// Every gate's verdict per turn, coded `affirm / deny / abstain`.
    ///
    /// A gate with no verdict recorded for a turn is coded as an abstention, which is what an
    /// absent verdict means on this panel: the gate was present and produced no vote.
    static func squareCodes(
        _ history: ObservationHistory, judge: JudgeIdentity
    ) -> [Int] {
        history.observations.map { observation in
            guard let verdict = observation.verdicts[judge],
                  let code = Verdict.allCases.firstIndex(of: verdict) else {
                return Verdict.allCases.count - 1
            }
            return code
        }
    }

    static func squarePairs(
        _ history: ObservationHistory, judges: [JudgeIdentity]
    ) -> [SquarePairing] {
        var built: [SquarePairing] = []
        for left in judges.indices where left + 1 < judges.count {
            for right in (left + 1)..<judges.count {
                let first = squareCodes(history, judge: judges[left])
                let second = squareCodes(history, judge: judges[right])
                guard let row = try? LabelMargin(labels: first, categoryCount: Verdict.allCases.count),
                      let column = try? LabelMargin(labels: second, categoryCount: Verdict.allCases.count),
                      let priced = try? AttainableTrace(row: row, column: column) else { continue }
                built.append(SquarePairing(
                    key: "\(judges[left]) / \(judges[right])",
                    observed: zip(first, second).reduce(0) { $0 + ($1.0 == $1.1 ? 1 : 0) },
                    priced: priced
                ))
            }
        }
        return built
    }

    // MARK: - what the square panel comes to

    struct SquareTally: Sendable {
        var pairs = 0
        var withHoles = 0
        var holes = 0
        var reachable = 0
        var spanned = 0
        var identicalMarginals = 0
        var observedUnattainableNeighbour = 0
        var usedCategories = 0
    }

    static func squareTally(_ pairs: [SquarePairing]) -> SquareTally {
        var tally = SquareTally()
        var used = Set<Int>()
        for pair in pairs {
            tally.pairs += 1
            let holes = pair.priced.holes
            tally.holes += holes.count
            tally.reachable += pair.priced.attainableTraces.count
            tally.spanned += pair.priced.upperTrace - pair.priced.lowerTrace + 1
            if !holes.isEmpty { tally.withHoles += 1 }
            if pair.priced.marginsAreIdentical { tally.identicalMarginals += 1 }
            if !pair.priced.admits(trace: pair.observed + 1) { tally.observedUnattainableNeighbour += 1 }
            for (category, count) in pair.priced.row.counts.enumerated() where count > 0 {
                used.insert(category)
            }
            for (category, count) in pair.priced.column.counts.enumerated() where count > 0 {
                used.insert(category)
            }
        }
        tally.usedCategories = used.count
        return tally
    }

    // MARK: - the repair preview

    enum SquareRepair: Sendable, Equatable {
        case built(trace: Int, agreement: Double)
        /// The requested rate is not one these two gates' verdict rates admit.
        case refused(String)
    }

    /// What a fixture on the widest pair's own verdict rates, built to `rate`, would agree at.
    ///
    /// Deliberately the strict call rather than the forgiving one. `nearestTable(toRate:)` would
    /// always answer, and an audit whose repair preview silently moved the target it was given
    /// would be reporting a rate nobody asked for as though it had been asked for.
    static func squareRepair(_ pair: SquarePairing, rate: Double) -> SquareRepair {
        let builder = SquarePanelBuilder(attainable: pair.priced)
        do {
            let table = try builder.table(agreementRate: rate)
            return .built(trace: table.trace, agreement: table.agreementRate)
        } catch {
            return .refused(
                "square repair preview refused for \(pair.key): \(error); the attainable band is "
                    + format(pair.priced.lowerRate) + " to " + format(pair.priced.upperRate)
            )
        }
    }

    // MARK: - the outcomes

    private static func squareNothingObserved() -> String {
        "no turn observed yet; which agreement counts a panel can reach is a fact about how often "
            + "each gate cast each verdict, and no gate has cast one"
    }

    private static func squareTooFewGates(_ count: Int) -> String {
        "\(count) gate(s) on this panel; an agreement count is a property of a pair and there is "
            + "no pair"
    }

    private static func squareNoPair(_ history: ObservationHistory) -> String {
        "\(history.count) observed turn(s), which is fewer than the two any pair of gates needs "
            + "before it has an agreement count to price"
    }

    /// The honest no-op: the gates never used the third case, so there is nothing square here.
    ///
    /// This is the outcome that keeps the stage from claiming credit it has not earned. If every
    /// gate only ever affirmed or denied, the three-way panel **is** the affirm grid, the
    /// attainable set is the familiar every-other-integer lattice, and `panelDesign` already
    /// reported it. Saying so is worth more than recomputing it under a new name.
    private static func squareStillBinary(_ tally: SquareTally, history: ObservationHistory) -> String {
        "\(history.count) turn(s), \(tally.pairs) pair(s); the gates used \(tally.usedCategories) "
            + "of \(Verdict.allCases.count) verdicts, so the three-way panel carries exactly what "
            + "the affirm grid does and its attainable counts are the every-other-integer lattice "
            + "panelDesign already priced; nothing here is square yet"
    }

    private static func squareDetail(
        _ tally: SquareTally,
        history: ObservationHistory,
        widest: SquarePairing,
        builtTrace: Int,
        agreement: Double
    ) -> String {
        var parts = [
            "\(history.count) turn(s), \(tally.pairs) pair(s) of gates over "
                + "\(tally.usedCategories) verdicts; \(tally.reachable) of \(tally.spanned) "
                + "agreement counts inside the attainable bands exist at all"
        ]
        if tally.withHoles > 0 {
            parts.append(
                "\(tally.withHoles) pair(s) have gaps in that band — \(tally.holes) count(s) no "
                    + "panel with these verdict rates reaches, which the binary affirm grid cannot "
                    + "express and PanelDesignKit declines to decide above two categories"
            )
        }
        if tally.observedUnattainableNeighbour > 0 {
            parts.append(
                "\(tally.observedUnattainableNeighbour) pair(s) sit one turn below a count that "
                    + "does not exist, so their agreement cannot move by a single turn"
            )
        }
        if tally.identicalMarginals > 0 {
            parts.append(
                "\(tally.identicalMarginals) pair(s) cast verdicts at matching rates, which "
                    + "forbids them differing on exactly one turn"
            )
        }
        parts.append(
            "\(widest.key) observed \(widest.observed); a fixture on those same verdict rates "
                + "built to " + format(squareRepairRate) + " agrees on \(builtTrace) turn(s), "
                + format(agreement)
        )
        return parts.joined(separator: "; ")
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.4f", value)
    }
}
