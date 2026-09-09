import AssociationTransportKit
import ConditioningCostKit
import EffectiveVoteKit
import EvalHarness
import ExactAssociationKit
import Foundation
import Testing
@testable import AIChatApp

/// The `conditioningCost` stage, which prices what `exactAssociation`'s exactness rests on.
///
/// That stage's interval is exact because it conditions on all four margins of its block. The move
/// removes the nuisance parameter and it is free under exactly one of the three designs a
/// two-by-two table can arise from. This app's panel fixed neither margin, and until now nothing
/// here could say what that costs.
@Suite("Conditioning cost stage")
struct ConditioningCostStageTests {
    private static let answerability = JudgeIdentity("answerability")
    private static let stability = JudgeIdentity("verdict stability")

    private func pipeline() async -> MetadataPipeline {
        MetadataPipeline(
            completer: ScriptedCompleter(
                title: [MetadataHarness.goodTitle],
                followUps: [MetadataHarness.goodFollowUps]
            ),
            contracts: await Composition.makeContracts(),
            transcripts: InMemoryTranscriptStore()
        )
    }

    private func outcome(_ trace: PipelineTrace) -> StageOutcome? {
        trace.records.first { $0.stage == .conditioningCost }?.outcome
    }

    private func history(cells: [[Int]]) -> ObservationHistory {
        let verdicts = Verdict.allCases
        var observations: [PanelObservation] = []
        for (row, line) in cells.enumerated() {
            for (column, count) in line.enumerated() {
                for _ in 0..<count {
                    observations.append(
                        PanelObservation(
                            id: "turn-\(observations.count)",
                            verdicts: [
                                Self.answerability: verdicts[row],
                                Self.stability: verdicts[column]
                            ],
                            truth: nil
                        )
                    )
                }
            }
        }
        return ObservationHistory(observations)
    }

    /// A gate that has only ever said one thing, so every block carries a zero margin.
    private func constantGateHistory() -> ObservationHistory {
        history(cells: [[5, 0, 0], [3, 0, 0], [2, 0, 0]])
    }

    /// Two gates that voted identically, so the pair carries no rates to tell apart.
    private func identicalHistory(count: Int = 20) -> ObservationHistory {
        ObservationHistory((0..<count).map { index in
            let verdict: Verdict = index % 3 == 0 ? .deny : .affirm
            return PanelObservation(
                id: "turn-\(index)",
                verdicts: [Self.answerability: verdict, Self.stability: verdict],
                truth: nil
            )
        })
    }

    @Test("a fresh install is quiet, and says why rather than reporting nothing")
    func skippedOnFreshInstall() async {
        var trace = PipelineTrace()
        await pipeline().auditConditioningCost(trace: &trace, history: ObservationHistory([]))
        guard case .skipped(let reason)? = outcome(trace) else {
            Issue.record("expected a skip, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(reason.contains("produced none"))
    }

    @Test("one gate is not a pair, and a cost needs a pair")
    func noOpOnASingleGate() async {
        var trace = PipelineTrace()
        let history = ObservationHistory([
            PanelObservation(id: "a", verdicts: [Self.answerability: .affirm], truth: nil),
            PanelObservation(id: "b", verdicts: [Self.answerability: .deny], truth: nil)
        ])
        await pipeline().auditConditioningCost(trace: &trace, history: history)
        guard case .noOp(let reason)? = outcome(trace) else {
            Issue.record("expected a no-op, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(reason.contains("there is no pair"))
    }

    @Test("two gates that voted identically leave no joint table to price")
    func noOpOnIdenticalGates() async {
        var trace = PipelineTrace()
        await pipeline().auditConditioningCost(trace: &trace, history: identicalHistory())
        guard case .noOp(let reason)? = outcome(trace) else {
            Issue.record("expected a no-op, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(reason.contains("no two gates have different verdict rates"))
    }

    @Test("a panel whose every block is pinned has no assumption in play, so nothing it costs")
    func noOpWhenEveryBlockIsPinned() async {
        var trace = PipelineTrace()
        await pipeline().auditConditioningCost(trace: &trace, history: constantGateHistory())
        guard case .noOp(let reason)? = outcome(trace) else {
            Issue.record("expected a no-op, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(reason.contains("nothing it costs"))
    }

    @Test("two levels cannot be differenced, and the stage refuses rather than subtracting them")
    func failedOnMismatchedLevels() async {
        var trace = PipelineTrace()
        await pipeline().auditConditioningCost(
            trace: &trace,
            history: history(cells: [[3, 2, 1], [2, 3, 1], [1, 1, 2]]),
            confidence: .ninetyNine,
            pricedAt: .ninetyFive
        )
        guard case .failed(let message)? = outcome(trace) else {
            Issue.record("expected a refusal, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(message.contains("99%"))
        #expect(message.contains("95%"))
        #expect(message.contains("would not"))
    }

    @Test("a panel small enough to enumerate in full is priced under all three designs")
    func pricesEveryDesignWhenItFits() async throws {
        var trace = PipelineTrace()
        // Row margins [4, 5, 2] against column margins [5, 4, 2], so the pair is not skipped for
        // having identical margins. The readable block holds eight items and enumerates in 165
        // tables under the total-fixed design, inside the default budget.
        await pipeline().auditConditioningCost(
            trace: &trace,
            history: history(cells: [[3, 1, 0], [2, 2, 1], [0, 1, 1]])
        )
        guard case .ran(let detail)? = outcome(trace) else {
            Issue.record("expected a reading, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(detail.contains("both margins fixed"))
        #expect(detail.contains("row margins fixed"))
        #expect(detail.contains("total fixed"))
        #expect(detail.contains("conditioning licensed"))
        #expect(detail.contains("not licensed"))
        #expect(detail.contains("enumerated in full"))
        #expect(detail.contains("percentage point(s) of actual coverage"))
    }

    @Test("a panel too large to enumerate is told which design was left out, and how large it is")
    func namesTheDesignItCouldNotAfford() async {
        var trace = PipelineTrace()
        // Thirty turns, whose readable block holds nineteen items: 1540 tables, over the budget.
        await pipeline().auditConditioningCost(
            trace: &trace,
            history: history(cells: [[6, 4, 2], [3, 6, 2], [2, 2, 3]])
        )
        guard case .ran(let detail)? = outcome(trace) else {
            Issue.record("expected a reading, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(detail.contains("over this stage's budget of 400"))
        #expect(detail.contains("was not enumerated"))
        #expect(!detail.contains("enumerated in full"))
    }

    @Test("a budget that affords only the licensed design says so instead of comparing one thing")
    func detailSaysWhenOnlyTheLicensedDesignWasAffordable() async {
        var trace = PipelineTrace()
        await pipeline().auditConditioningCost(
            trace: &trace,
            history: history(cells: [[3, 1, 0], [2, 2, 1], [0, 1, 1]]),
            budget: 0
        )
        guard case .ran(let detail)? = outcome(trace) else {
            Issue.record("expected a reading, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(detail.contains("only the design that licenses conditioning was affordable"))
        #expect(!detail.contains("percentage point(s) of actual coverage"))
        #expect(detail.contains("over this stage's budget of 0"))
    }

    @Test("the licensed design never declines a table, and an unlicensed one can")
    func licensingIsTheDecliningEvent() throws {
        // A block is a two-by-two window on the panel rather than a collapse of it, so this
        // eleven-item panel's first readable block holds nine.
        let panel = try ObservedPanel(counts: [[3, 2, 0], [2, 2, 1], [0, 1, 0]])
        let joint = MetadataPipeline.TransportJoint(key: "a / b", panel: panel, agreedTurns: 5)
        guard case .priced(let outcome) = MetadataPipeline.conditioningRead(
            joint, confidence: .ninetyFive, budget: 400
        ) else {
            Issue.record("expected a priced outcome")
            return
        }
        let licensed = try #require(outcome.readings.first { $0.licensed })
        #expect(licensed.design == "both margins fixed")
        #expect(licensed.declinedMass == 0)
        #expect(licensed.exactCoverage == licensed.coverageAmongRead)
        #expect(outcome.readings.contains { !$0.licensed })
        #expect(outcome.totalFixedPriced)
        #expect(outcome.itemCount == 9)
        #expect(outcome.itemCount < panel.itemCount)
        for reading in outcome.readings {
            #expect(reading.exactCoverage >= 0.95, "\(reading.design) covered \(reading.exactCoverage)")
            #expect(reading.widthPremium > 1)
        }
    }

    @Test("a budget of nothing still prices the design that licenses conditioning")
    func licensedDesignIsAlwaysAffordable() throws {
        let panel = try ObservedPanel(counts: [[3, 2, 0], [2, 2, 1], [0, 1, 0]])
        let joint = MetadataPipeline.TransportJoint(key: "a / b", panel: panel, agreedTurns: 5)
        guard case .priced(let outcome) = MetadataPipeline.conditioningRead(
            joint, confidence: .ninetyFive, budget: 0
        ) else {
            Issue.record("expected a priced outcome")
            return
        }
        #expect(outcome.readings.count == 1)
        #expect(outcome.readings[0].licensed)
        #expect(!outcome.totalFixedPriced)
        #expect(outcome.budget == 0)
    }

    @Test("a panel with nothing readable is reported as having no assumption to price")
    func pinnedPanelIsNotPriced() throws {
        let panel = try ObservedPanel(counts: [[5, 0, 0], [3, 0, 0], [2, 0, 0]])
        let joint = MetadataPipeline.TransportJoint(key: "a / b", panel: panel, agreedTurns: 5)
        guard case .nothingToPrice(let reason) = MetadataPipeline.conditioningRead(
            joint, confidence: .ninetyFive, budget: 400
        ) else {
            Issue.record("expected nothing to price")
            return
        }
        #expect(reason.contains("pinned by a zero margin"))
    }

    /// The stage table has to name every package in the series, and this one is the reminder.
    @Test("the new stage names its package and its title")
    func catalogued() {
        #expect(PipelineStage.conditioningCost.package == "ConditioningCostKit")
        #expect(PipelineStage.conditioningCost.title == "Conditioning cost")
    }
}
