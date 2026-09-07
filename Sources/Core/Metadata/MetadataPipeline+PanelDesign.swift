import EffectiveVoteKit
import Foundation
import PanelDesignKit

extension MetadataPipeline {
    /// What a repaired fixture would be built to carry, if this panel needed one.
    ///
    /// A policy input rather than a constant: what counts as "enough association to be worth
    /// measuring" is a choice, and a stage that hides it behind a literal cannot be asked to
    /// justify it.
    static let panelRepairTarget = AssociationTarget.oddsRatio(6)

    /// Audits the fixture five stages above are computing their coefficients over.
    func auditPanelDesign(
        trace: inout PipelineTrace,
        store: PanelHistoryStore = .shared
    ) async {
        await auditPanelDesign(trace: &trace, history: await store.history)
    }

    /// The same audit over a supplied history.
    ///
    /// `effectiveVote`, `sampleWidth`, `familyError`, `effectiveComparison` and `chanceAgreement`
    /// all publish a reading about how much two gates agree. Every one of them is computed over
    /// the same **fixture** — the grid of which gates affirmed which turns — and none of them
    /// checks whether that fixture can carry the thing being measured. It often cannot. Two gates
    /// whose affirm-rates are far apart are forced to disagree on a fixed share of turns before
    /// either has said anything, and a pair whose joint counts happen to be the products of their
    /// marginals has an association of exactly nil rather than of nearly nil.
    func auditPanelDesign(
        trace: inout PipelineTrace,
        history: ObservationHistory,
        target: AssociationTarget = MetadataPipeline.panelRepairTarget
    ) async {
        guard !history.observations.isEmpty else {
            trace.record(.panelDesign, .skipped(reason: Self.designNothingObserved()))
            return
        }
        let judges = history.judges
        guard judges.count >= 2 else {
            trace.record(.panelDesign, .noOp(reason: Self.designTooFewGates(judges.count)))
            return
        }
        guard let panel = Self.designPanel(history, judges: judges) else {
            trace.record(.panelDesign, .noOp(reason: Self.designNoPanel(history)))
            return
        }
        let ledger = DesignLedger()
        await ledger.record(Self.designKey, panel: panel)
        // Non-throwing on purpose: every pair it looks at is generated from the panel's own index
        // range, so a `catch` here would be an arm no test could reach.
        let tally = Self.designTally(
            panel, diagnosis: DesignDiagnosis(panel: panel), judges: judges
        )
        let repair = await Self.designRepair(ledger, tally: tally, target: target)
        if case .refused(let message) = repair {
            trace.record(.panelDesign, .failed(message: message))
            return
        }
        Self.designRecord(&trace, tally: tally, repair: repair, history: history)
    }

    /// The key the panel is held under. One panel, one audit, one name.
    static let designKey = "gate-panel"

    // MARK: - building the panel

    /// The gates' verdicts as the binary affirm grid, the same basis its siblings measure on.
    static func designPanel(
        _ history: ObservationHistory, judges: [JudgeIdentity]
    ) -> PanelMatrix? {
        let labels = judges.map { judge in
            history.observations.map { $0.verdicts[judge] == .affirm ? 0 : 1 }
        }
        return try? PanelMatrix(labels: labels, categoryCount: 2)
    }

    // MARK: - what the fixture supports

    /// What the panel's pairs came to, counted rather than summarised.
    struct DesignTally: Sendable {
        var pairs = 0
        var structurallyNull = 0
        var pinned = 0
        var identicalMarginals = 0
        var forcedAgreement = 0
        var narrowest = 1.0
        var narrowestKey = ""
        var repairable: (Int, Int)?
    }

    static func designTally(
        _ panel: PanelMatrix, diagnosis: DesignDiagnosis, judges: [JudgeIdentity]
    ) -> DesignTally {
        var tally = DesignTally()
        for deviation in diagnosis.deviations {
            tally.pairs += 1
            if deviation.deviation == 0 { tally.structurallyNull += 1 }
            guard let first = try? panel.margin(deviation.first),
                  let second = try? panel.margin(deviation.second),
                  let range = try? AttainableAgreement(first: first, second: second) else { continue }
            if range.isPinned { tally.pinned += 1 }
            if range.marginsAreIdentical { tally.identicalMarginals += 1 }
            if range.lowerCount > 0 { tally.forcedAgreement += 1 }
            let width = range.upper - range.lower
            if width < tally.narrowest {
                tally.narrowest = width
                tally.narrowestKey = "\(judges[deviation.first]) / \(judges[deviation.second])"
            }
            let usable = !first.isDegenerate && !second.isDegenerate && deviation.deviation == 0
            if usable, tally.repairable == nil {
                tally.repairable = (deviation.first, deviation.second)
            }
        }
        return tally
    }

    // MARK: - the repair preview

    /// What a fixture built to carry `target` on the same marginals would look like.
    enum DesignRepair: Sendable, Equatable {
        /// No pair on this panel is both null and repairable.
        case none
        case built(agreement: Double, snapped: Double)
        /// The target itself was not one any pair of marginals admits.
        case refused(String)
    }

    static func designRepair(
        _ ledger: DesignLedger, tally: DesignTally, target: AssociationTarget
    ) async -> DesignRepair {
        guard let pair = tally.repairable else { return .none }
        do {
            let built = try await ledger.replacement(
                for: designKey, pair: pair, target: target, seed: designSeed
            )
            return .built(agreement: built.agreementRate, snapped: built.snapDistance)
        } catch {
            return .refused("panel repair preview refused: \(error)")
        }
    }

    /// Fixed, so the preview is the same figure on every device and every run.
    static let designSeed: UInt64 = 20_260_907

    // MARK: - the outcomes

    private static func designRecord(
        _ trace: inout PipelineTrace,
        tally: DesignTally,
        repair: DesignRepair,
        history: ObservationHistory
    ) {
        if tally.structurallyNull == tally.pairs {
            trace.record(.panelDesign, .noOp(reason: designWhollyNull(tally, history: history)))
            return
        }
        trace.record(.panelDesign, .ran(detail: designDetail(tally, repair: repair, history: history)))
    }

    private static func designNothingObserved() -> String {
        "no turn observed yet; what a fixture can carry is a fact about how often each gate "
            + "affirmed, and no gate has affirmed anything"
    }

    private static func designTooFewGates(_ count: Int) -> String {
        "\(count) gate(s) on this panel; a fixture carries association between a pair and there "
            + "is no pair"
    }

    private static func designNoPanel(_ history: ObservationHistory) -> String {
        "\(history.count) observed turn(s), which is fewer than the two a fixture needs before "
            + "any pair of gates has a joint count to look at"
    }

    /// Every pair independent by construction, which is a finding about the panel.
    ///
    /// Two different situations reach zero, and the message separates them because the fix is
    /// different. A **crossed** fixture is null because every combination was enumerated equally
    /// often. A gate that **affirmed every turn** is null against everything, trivially: its
    /// joint counts are the other gate's marginal, which is exactly what independence predicts.
    /// The first needs a different fixture; the second needs a gate that ever says no.
    private static func designWhollyNull(_ tally: DesignTally, history: ObservationHistory) -> String {
        let head = "\(history.count) turn(s), all \(tally.pairs) pair(s) sit at a joint count "
            + "exactly equal to the product of their marginals, so the association these gates "
            + "have is nil by construction rather than small by measurement; every coefficient, "
            + "interval and multiplicity correction this app publishes over this panel is "
            + "estimating zero"
        guard tally.pinned > 0 else {
            return head + "; the fixture enumerates its combinations evenly and needs replacing"
        }
        return head + "; \(tally.pinned) of them are null for the blunter reason that a gate "
            + "affirmed every turn, and a gate that never says no is independent of everything"
    }

    private static func designDetail(
        _ tally: DesignTally, repair: DesignRepair, history: ObservationHistory
    ) -> String {
        var parts = [
            "\(history.count) turn(s), \(tally.pairs) pair(s) of gates; "
                + "\(tally.structurallyNull) sit at exactly nil association by construction"
        ]
        if tally.forcedAgreement > 0 {
            parts.append(
                "\(tally.forcedAgreement) pair(s) are forced to agree on a share of turns by "
                    + "their affirm-rates alone, before either gate has said anything"
            )
        }
        if tally.pinned > 0 {
            parts.append(
                "\(tally.pinned) pair(s) have their agreement rate pinned to a single value by a "
                    + "gate that affirmed every turn, so the rate restates that gate rather than "
                    + "comparing two"
            )
        }
        if tally.identicalMarginals > 0 {
            parts.append(
                "\(tally.identicalMarginals) pair(s) have matching affirm-rates, which forbids "
                    + "them agreeing on exactly all-but-one turn"
            )
        }
        if !tally.narrowestKey.isEmpty {
            parts.append(
                "narrowest attainable band \(tally.narrowestKey) at " + format(tally.narrowest)
            )
        }
        if case .built(let agreement, let snapped) = repair {
            parts.append(
                "a fixture on those same marginals carrying the audit's target would agree at "
                    + format(agreement) + ", " + format(snapped) + " off the requested rate"
            )
        }
        return parts.joined(separator: "; ")
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.4f", value)
    }
}
