import EffectiveComparisonKit
import EffectiveVoteKit
import EvalHarness
import Foundation
import Testing
@testable import AIChatApp

/// The `effectiveComparison` stage, which measures the denominator `familyError` had to assume.
///
/// `familyError` corrects the panel's six readings under Benjamini-Yekutieli, paying `H(6)` for
/// arbitrary dependence because it has nothing to measure the real dependence with. This stage
/// derives the dependence from the panel's shape and prices it. The suite pins the price, the
/// distinction between the rank and the tail count, and the two things the stage says even when
/// there is nothing yet to correct.
@Suite("Effective comparison stage")
struct EffectiveComparisonStageTests {
    private static let answerability = JudgeIdentity("answerability")
    private static let stability = JudgeIdentity("verdict stability")
    private static let independence = JudgeIdentity("source independence")
    private static let temporal = JudgeIdentity("temporal validity")

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
        trace.records.first { $0.stage == .effectiveComparison }?.outcome
    }

    /// Two gates that move together strongly enough for a reading to clear an uncorrected 0.05.
    private func associatedHistory(count: Int) -> ObservationHistory {
        ObservationHistory((0..<count).map { index in
            let even = index.isMultiple(of: 2)
            return PanelObservation(
                id: "turn-\(index)",
                verdicts: [
                    Self.answerability: even ? .affirm : .deny,
                    Self.stability: even && !index.isMultiple(of: 10) ? .affirm : .deny,
                    Self.independence: index.isMultiple(of: 3) ? .affirm : .deny,
                    Self.temporal: index.isMultiple(of: 5) ? .affirm : .deny
                ],
                truth: nil
            )
        })
    }

    /// A panel whose strongest pair lands between the two thresholds.
    ///
    /// Twenty-four turns with the agreement broken every fourth gives a reading that Sidak over
    /// the calibrated `4.8912` publishes and Benjamini-Yekutieli over six does not. It is the
    /// only fixture here where the two corrections disagree, which is the whole reason the stage
    /// reports which of them it is quoting.
    private func borderlineHistory(count: Int = 24) -> ObservationHistory {
        ObservationHistory((0..<count).map { index in
            let even = index.isMultiple(of: 2)
            return PanelObservation(
                id: "turn-\(index)",
                verdicts: [
                    Self.answerability: even ? .affirm : .deny,
                    Self.stability: even && !index.isMultiple(of: 4) ? .affirm : .deny,
                    Self.independence: index.isMultiple(of: 3) ? .affirm : .deny,
                    Self.temporal: index.isMultiple(of: 5) ? .affirm : .deny
                ],
                truth: nil
            )
        })
    }

    /// Gates that wander independently, so nothing on the page clears 0.05 on its own.
    private func flatHistory(count: Int) -> ObservationHistory {
        ObservationHistory((0..<count).map { index in
            PanelObservation(
                id: "turn-\(index)",
                verdicts: [
                    Self.answerability: index.isMultiple(of: 2) ? .affirm : .deny,
                    Self.stability: index.isMultiple(of: 3) ? .affirm : .deny,
                    Self.independence: index.isMultiple(of: 5) ? .affirm : .deny,
                    Self.temporal: index.isMultiple(of: 7) ? .affirm : .deny
                ],
                truth: nil
            )
        })
    }

    @Test("an unobserved panel is skipped, and still knows what its shape is worth")
    func knownBeforeAnyData() async {
        var trace = PipelineTrace()
        await pipeline().auditEffectiveComparison(trace: &trace, history: ObservationHistory())
        guard case let .skipped(reason) = outcome(trace) else {
            Issue.record("expected the stage to skip on an unobserved panel")
            return
        }
        #expect(reason.contains("0 observed turn(s), no pair measurable yet"))
        #expect(reason.contains("6 comparisons"))
        #expect(reason.contains("12 of 15 pairings"))
        #expect(reason.contains("4.8912"))
        #expect(reason.contains("4.0000"))
    }

    @Test("a page saying nothing is a noOp that still reports where the threshold moved to")
    func nothingToReprice() async {
        var trace = PipelineTrace()
        await pipeline().auditEffectiveComparison(trace: &trace, history: flatHistory(count: 12))
        guard case let .noOp(reason) = outcome(trace) else {
            Issue.record("expected a noOp on a panel where nothing clears uncorrected")
            return
        }
        #expect(reason.contains("none reaches"))
        #expect(reason.contains("changes nothing"))
    }

    @Test("a measured panel is re-priced against the dependence its shape actually has")
    func repricesAMeasuredPanel() async {
        var trace = PipelineTrace()
        await pipeline().auditEffectiveComparison(trace: &trace, history: associatedHistory(count: 200))
        guard case let .ran(detail) = outcome(trace) else {
            Issue.record("expected the stage to re-price a two-hundred-turn panel")
            return
        }
        #expect(detail.contains("12 of 15 pairings share a gate (80% overlap)"))
        #expect(detail.contains("Benjamini-Yekutieli charges 14.7000x"))
        #expect(detail.contains("this shape is worth 4.7930x"))
        #expect(detail.contains("survive Benjamini-Yekutieli"))
    }

    @Test("the tail count is spent and the rank is quoted beside it, never instead of it")
    func spendsTheTailAndNamesTheRank() async {
        var trace = PipelineTrace()
        await pipeline().auditEffectiveComparison(trace: &trace, history: associatedHistory(count: 200))
        guard case let .ran(detail) = outcome(trace) else {
            Issue.record("expected the stage to run")
            return
        }
        #expect(detail.contains("spending the tail count 4.8912 of 6"))
        #expect(detail.contains("not the rank 4.0000"))
    }

    @Test("a panel too small to have a family is a real failure, not a silent fallback")
    func panelTooSmall() async {
        var trace = PipelineTrace()
        await pipeline().auditEffectiveComparison(
            trace: &trace, history: associatedHistory(count: 20), judgeCount: 1
        )
        guard case let .failed(message) = outcome(trace) else {
            Issue.record("expected a failure on a panel below two judges")
            return
        }
        #expect(message.contains("judgeCountTooSmall"))
    }

    @Test("the stage reports honestly when re-pricing changed nothing")
    func saysSoWhenNothingChanged() async {
        var trace = PipelineTrace()
        await pipeline().auditEffectiveComparison(trace: &trace, history: associatedHistory(count: 200))
        guard case let .ran(detail) = outcome(trace) else {
            Issue.record("expected the stage to run")
            return
        }
        let changed = detail.contains("measuring the shape publishes")
        let unchanged = detail.contains("the same set either way")
        #expect(changed != unchanged, "the stage must say one or the other, never neither or both")
    }

    @Test("a reading between the two thresholds is named as bought, not just counted")
    func namesWhatTheCalibrationBought() async {
        var trace = PipelineTrace()
        await pipeline().auditEffectiveComparison(trace: &trace, history: borderlineHistory())
        guard case let .ran(detail) = outcome(trace) else {
            Issue.record("expected the stage to run on a borderline panel")
            return
        }
        #expect(detail.contains("measuring the shape publishes"))
        #expect(!detail.contains("the same set either way"))
        #expect(detail.contains("survive Benjamini-Yekutieli"))
    }

    @Test("the package refuses a rank as a denominator, which is why the stage quotes both")
    func rankIsNotSpendable() throws {
        let design = try PanelDesign(judgeCount: MetadataPipeline.comparisonJudgeCount)
        let matrix = try design.correlationMatrix()
        let rank = try LiJi().checkedEstimate(for: matrix)
        let tail = try PermutationEffectiveCount.standard.estimate(for: matrix)
        #expect(rank.question == .rank)
        #expect(tail.question == .tail)
        #expect(throws: EffectiveComparisonError.rankSpentAsThreshold(estimator: "Li-Ji")) {
            _ = try MultiplicityBudget(count: rank)
        }
        let budget = try MultiplicityBudget(count: tail, level: MetadataPipeline.comparisonAlpha)
        #expect(budget.effectiveThreshold > budget.sidakThreshold)
    }

    @Test("the panel this stage derives is the panel familyError counts")
    func agreesWithItsSibling() throws {
        let design = try PanelDesign(judgeCount: MetadataPipeline.comparisonJudgeCount)
        #expect(MetadataPipeline.comparisonJudgeCount == MetadataPipeline.familyJudgeCount)
        #expect(design.comparisonCount == 6)
        #expect(design.overlappingPairings == 12)
        #expect(design.totalPairings == 15)
    }
}
