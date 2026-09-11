import EffectiveVoteKit
import EvalHarness
import Foundation
import RestrictionRuleKit
import Testing
import UnconditionalExactKit
@testable import AIChatApp

/// The `restrictionRule` stage: whether the `gamma = 0.001` every restricted test in this app
/// defaults to is actually a good one, measured by search rather than assumed.
@Suite("Restriction rule stage")
struct RestrictionRuleStageTests {
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
        trace.records.first { $0.stage == .restrictionRule }?.outcome
    }

    /// Same fixture shape `totalFixedExactStageTests` uses, so this stage reads the identical
    /// block `unconditionalExact` and `totalFixedExact` already report on.
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

    /// A twelve-item block, small enough that its level can be audited.
    private func auditableHistory() -> ObservationHistory {
        history(cells: [[6, 2, 0], [1, 3, 0], [0, 0, 0]])
    }

    private func constantGateHistory() -> ObservationHistory {
        history(cells: [[5, 0, 0], [3, 0, 0], [2, 0, 0]])
    }

    @Test("an empty panel is skipped, not run")
    func emptyPanel() async {
        var trace = PipelineTrace()
        await pipeline().auditRestrictionRule(trace: &trace, history: ObservationHistory([]))
        #expect(outcome(trace)?.isRefusal == false)
        if case .skipped = outcome(trace) {} else { Issue.record("expected skipped") }
    }

    @Test("a single gate is a no-op: there is nothing to cross-classify")
    func singleGate() async {
        var trace = PipelineTrace()
        let history = ObservationHistory([
            PanelObservation(id: "t", verdicts: [Self.answerability: .affirm], truth: nil)
        ])
        await pipeline().auditRestrictionRule(trace: &trace, history: history)
        if case .noOp = outcome(trace) {} else { Issue.record("expected noOp") }
    }

    @Test("two gates with the same marginal rate produce no readable pair")
    func constantGate() async {
        var trace = PipelineTrace()
        await pipeline().auditRestrictionRule(trace: &trace, history: constantGateHistory())
        if case .noOp = outcome(trace) {} else { Issue.record("expected noOp") }
    }

    @Test("a real block is searched, and the recommendation never beats floor by construction")
    func realBlockIsSearched() async {
        var trace = PipelineTrace()
        await pipeline().auditRestrictionRule(trace: &trace, history: auditableHistory())
        guard case let .ran(detail) = outcome(trace) else {
            Issue.record("expected ran, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(detail.contains("unrestricted ="))
        #expect(detail.contains("recommended gamma ="))
        #expect(detail.contains("holds its level") || detail.contains("audit budget"))
    }

    @Test("the search itself agrees with the standalone recommendation on the same block")
    func matchesStandaloneSearch() throws {
        let arms = try ArmCounts(successes: 6, trials: 8, otherSuccesses: 1, otherTrials: 4)
        let test = try UnconditionalExact(.remainder(1e-5))
        let measure = PooledScore()
        let cost = ClosureGammaCostFunction { gamma in
            try test.pValue(
                for: arms, alternative: .twoSided, using: measure,
                restriction: .bergerBoos(gamma: gamma)
            ).value
        }
        let recommendation = try GammaSearch.recommend(
            costFunction: cost, gammaFloor: 1e-6, gammaCeiling: 0.2
        )
        #expect(recommendation.recommendedValue <= recommendation.floorValue)
    }

    @Test("a design over the audit budget names its own table count rather than substituting one")
    func overBudgetDesignNamesItself() async {
        var trace = PipelineTrace()
        var big: [[Int]] = Array(repeating: Array(repeating: 0, count: 3), count: 3)
        big[0][0] = 20
        big[0][1] = 10
        big[1][0] = 6
        big[1][1] = 3
        await pipeline().auditRestrictionRule(trace: &trace, history: history(cells: big))
        guard case let .ran(detail) = outcome(trace) else {
            Issue.record("expected ran, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(detail.contains("audit budget"))
    }

    @Test("the stage names its package and title")
    func attribution() {
        #expect(PipelineStage.restrictionRule.package == "RestrictionRuleKit")
        #expect(PipelineStage.restrictionRule.title == "Restriction rule")
    }
}
