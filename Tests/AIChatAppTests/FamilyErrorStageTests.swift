import EffectiveVoteKit
import EvalHarness
import FamilyErrorKit
import Foundation
import Testing
@testable import AIChatApp

/// The `familyError` stage, which corrects the page the three stages above it write.
///
/// `effectiveVote`, `proxyLabel` and `sampleWidth` each publish a reading for every pair of the
/// four evidence gates. Six pairs, every reading at a nominal 95%, and nothing anywhere asks what
/// six of them hold at together. This suite pins the correction, the dependence count that makes
/// it necessary, and the one member of the family that cannot be re-quoted at all.
@Suite("Family error stage")
struct FamilyErrorStageTests {
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
        trace.records.first { $0.stage == .familyError }?.outcome
    }

    /// A panel where two gates move together strongly enough to clear an uncorrected threshold.
    ///
    /// `answerability` and `stability` agree on all but every tenth turn, which is the declared
    /// `derives` edge in `PreModelPipeline.dependenceGraph` behaving exactly as declared.
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

    /// A panel whose gates agree exactly, so one pair reaches `|phi| == 1`.
    private func perfectHistory(count: Int) -> ObservationHistory {
        ObservationHistory((0..<count).map { index in
            let even = index.isMultiple(of: 2)
            return PanelObservation(
                id: "turn-\(index)",
                verdicts: [
                    Self.answerability: even ? .affirm : .deny,
                    Self.stability: even ? .affirm : .deny,
                    Self.independence: index.isMultiple(of: 3) ? .affirm : .deny,
                    Self.temporal: index.isMultiple(of: 5) ? .affirm : .deny
                ],
                truth: nil
            )
        })
    }

    /// A panel where every gate wanders independently, so nothing clears 0.05 on its own.
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

    @Test("a panel nobody has observed is skipped, and still says what shape it will have")
    func neverObserved() async {
        var trace = PipelineTrace()
        await pipeline().auditFamilyError(trace: &trace, history: ObservationHistory())
        guard case let .skipped(reason) = outcome(trace) else {
            Issue.record("expected the stage to skip on an unobserved panel")
            return
        }
        #expect(reason.contains("0 observed turn(s), no pair measurable yet"))
        #expect(reason.contains("will have 6 pairs"))
        #expect(reason.contains("12 of the 15 pairings"))
        #expect(reason.contains("arbitrary"))
    }

    @Test("a page already saying nothing is a noOp, not a suppressed correction")
    func nothingToCorrect() async {
        var trace = PipelineTrace()
        await pipeline().auditFamilyError(trace: &trace, history: flatHistory(count: 12))
        guard case let .noOp(reason) = outcome(trace) else {
            Issue.record("expected a noOp on a panel where nothing clears uncorrected")
            return
        }
        #expect(reason.contains("none reaches 0.05 uncorrected"))
        #expect(reason.contains("the page is already saying nothing"))
    }

    @Test("a measured panel is corrected for six pairs, not for the pairs that produced numbers")
    func correctsForTheWholePanel() async {
        var trace = PipelineTrace()
        await pipeline().auditFamilyError(trace: &trace, history: associatedHistory(count: 200))
        guard case let .ran(detail) = outcome(trace) else {
            Issue.record("expected the stage to correct a two-hundred-turn panel")
            return
        }
        #expect(detail.contains("of 6 pair(s) measurable over 200 turn(s)"))
        #expect(detail.contains("clear 0.05 uncorrected"))
        #expect(detail.contains("survive Benjamini-Yekutieli over 6"))
    }

    @Test("the dependence it reports is counted from the panel's shape, not assumed")
    func dependenceIsCounted() async {
        var trace = PipelineTrace()
        await pipeline().auditFamilyError(trace: &trace, history: associatedHistory(count: 200))
        guard case let .ran(detail) = outcome(trace) else {
            Issue.record("expected the stage to correct a two-hundred-turn panel")
            return
        }
        #expect(detail.contains("12 of 15 pairings share a gate (80% overlap)"))
        #expect(detail.contains("independence is unavailable"))
        #expect(detail.contains("H(6) = 2.4500"))
    }

    @Test("it says what noise alone would have put at the top of the page")
    func selectionIsPriced() async {
        var trace = PipelineTrace()
        await pipeline().auditFamilyError(trace: &trace, history: associatedHistory(count: 200))
        guard case let .ran(detail) = outcome(trace) else {
            Issue.record("expected the stage to correct a two-hundred-turn panel")
            return
        }
        #expect(detail.contains("ceiling for the largest of 6"))
        #expect(detail.contains("a single reading would face"))
    }

    @Test("the strongest widenable interval is re-quoted for the whole page")
    func intervalIsWidened() async {
        var trace = PipelineTrace()
        await pipeline().auditFamilyError(trace: &trace, history: associatedHistory(count: 200))
        guard case let .ran(detail) = outcome(trace) else {
            Issue.record("expected the stage to correct a two-hundred-turn panel")
            return
        }
        #expect(detail.contains("holds across all 6 only as"))
        #expect(detail.contains("member level"))
    }

    @Test("a perfectly associated pair is named as unwidenable rather than dropped")
    func perfectPairIsNamed() async {
        var trace = PipelineTrace()
        await pipeline().auditFamilyError(trace: &trace, history: perfectHistory(count: 200))
        guard case let .ran(detail) = outcome(trace) else {
            Issue.record("expected the stage to correct a perfectly associated panel")
            return
        }
        #expect(detail.contains("sits at |phi| 1.0000 where atanh is unbounded"))
        #expect(detail.contains("cannot be re-quoted at all"))
    }

    @Test("the family it builds is sized by the panel and not by what was measurable")
    func familyIsSizedByThePanel() async {
        let estimator = EffectiveVoteEstimator(
            basis: .verdictAgreement,
            policy: MetadataPipeline.effectiveVotePolicy
        )
        let measured = estimator.estimate(associatedHistory(count: 200), stratum: .all)
            .measuredAssociations
        guard let family = MetadataPipeline.family(from: measured) else {
            Issue.record("expected a measurable family")
            return
        }
        #expect(family.size == 6)
        #expect(family.reportedCount <= 6)
        #expect(family.unreportedCount == 6 - family.reportedCount)
        #expect(family.isDeclared)
    }

    @Test("an unmeasurable panel builds no family at all")
    func noFamilyWithoutMeasurements() {
        #expect(MetadataPipeline.family(from: []) == nil)
    }

    @Test("the stage runs on the metadata path without a title")
    func runsOnTheNoTitlePath() async {
        var trace = PipelineTrace()
        let metadata = await pipeline().generate(userText: "hello", assistantText: "  ", trace: &trace)
        #expect(metadata == nil)
        #expect(outcome(trace) != nil)
    }

    @Test("a panel too small to have a pair is a recorded failure, not a silent fallback")
    func panelTooSmallToHaveAPair() async {
        var trace = PipelineTrace()
        await pipeline().auditFamilyError(
            trace: &trace, history: associatedHistory(count: 40), judgeCount: 1)
        guard case let .failed(message) = outcome(trace) else {
            Issue.record("expected a failure on a panel below two judges")
            return
        }
        #expect(message.contains("a panel needs at least two judges"))
    }

    @Test("a pair that produced no coefficient is left out of the family entirely")
    func unmeasurablePairIsExcluded() {
        let table = EffectiveVoteKit.ContingencyTable(
            bothTrue: 0, leftOnly: 0, rightOnly: 0, bothFalse: 0
        )
        let unmeasurable = PairwiseAssociation(
            pair: JudgePair(Self.answerability, Self.temporal),
            basis: .verdictAgreement,
            scorerName: "phi",
            table: table,
            coefficient: nil,
            interval: nil
        )
        #expect(MetadataPipeline.family(from: [unmeasurable]) == nil)
        #expect(MetadataPipeline.measuredPairs([unmeasurable]).isEmpty)
        #expect(MetadataPipeline.strongest(of: [unmeasurable])?.name == nil)
    }

    @Test("the stage is mapped to the package that implements it")
    func stageIsMapped() {
        #expect(PipelineStage.familyError.package == "FamilyErrorKit")
        #expect(PipelineStage.familyError.title == "Family error")
    }
}
