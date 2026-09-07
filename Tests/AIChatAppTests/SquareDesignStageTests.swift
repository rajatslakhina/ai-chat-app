import EffectiveVoteKit
import EvalHarness
import Foundation
import SquareDesignKit
import Testing
@testable import AIChatApp

/// The `squareDesign` stage, which audits the panel `panelDesign` collapses to two categories.
///
/// Every stage before it reads the gates as an affirm grid — affirmed, or not. The gates do not
/// produce one: they affirm, deny or abstain. Restoring the third case makes two questions
/// answerable that the binary panel cannot pose, and this suite pins both: which agreement counts
/// inside the attainable band no panel with these verdict rates reaches, and what a fixture built
/// to a target rate on those same rates would agree at.
@Suite("Square design stage")
struct SquareDesignStageTests {
    private static let answerability = JudgeIdentity("answerability")
    private static let stability = JudgeIdentity("verdict stability")
    private static let independence = JudgeIdentity("source independence")

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
        trace.records.first { $0.stage == .squareDesign }?.outcome
    }

    /// Twelve turns, three gates, and every verdict actually used.
    ///
    /// `answerability` and `stability` cast at identical rates — four of each verdict — and differ
    /// on exactly two turns, which puts their observed agreement one below a count that does not
    /// exist. `independence` never abstains, so the pair bands differ from each other.
    private func threeWayHistory(count: Int = 12) -> ObservationHistory {
        ObservationHistory((0..<count).map { index in
            let base: Verdict = index % 3 == 0 ? .affirm : (index % 3 == 1 ? .deny : .abstain)
            let swapped: Verdict = index == 0 ? .deny : (index == 1 ? .affirm : base)
            return PanelObservation(
                id: "turn-\(index)",
                verdicts: [
                    Self.answerability: base,
                    Self.stability: swapped,
                    Self.independence: index < 8 ? .affirm : .deny
                ],
                truth: nil
            )
        })
    }

    /// The same shape with the third verdict never used, which is the affirm grid restated.
    private func binaryHistory(count: Int = 12) -> ObservationHistory {
        ObservationHistory((0..<count).map { index in
            PanelObservation(
                id: "turn-\(index)",
                verdicts: [
                    Self.answerability: index % 3 == 0 ? .affirm : .deny,
                    Self.stability: index < 7 ? .affirm : .deny
                ],
                truth: nil
            )
        })
    }

    @Test("a fresh install is quiet, and says why rather than reporting nothing")
    func skippedOnFreshInstall() async {
        var trace = PipelineTrace()
        await pipeline().auditSquareDesign(trace: &trace, store: PanelHistoryStore())
        guard case let .skipped(reason) = outcome(trace) else {
            Issue.record("expected .skipped, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(reason.contains("no gate has cast one"))
    }

    @Test("one gate is not a pair, and the stage says so instead of failing")
    func noOpOnASingleGate() async {
        var trace = PipelineTrace()
        let history = ObservationHistory([
            PanelObservation(id: "t0", verdicts: [Self.answerability: .affirm], truth: nil),
            PanelObservation(id: "t1", verdicts: [Self.answerability: .abstain], truth: nil)
        ])
        await pipeline().auditSquareDesign(trace: &trace, history: history)
        guard case let .noOp(reason) = outcome(trace) else {
            Issue.record("expected .noOp, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(reason.contains("there is no pair"))
    }

    @Test("a single turn is fewer than any pair needs to have a count at all")
    func noOpOnOneTurn() async {
        var trace = PipelineTrace()
        let history = ObservationHistory([
            PanelObservation(
                id: "t0",
                verdicts: [Self.answerability: .affirm, Self.stability: .abstain],
                truth: nil
            )
        ])
        await pipeline().auditSquareDesign(trace: &trace, history: history)
        guard case let .noOp(reason) = outcome(trace) else {
            Issue.record("expected .noOp, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(reason.contains("fewer than the two any pair of gates needs"))
    }

    /// The honest skip. Gates that never abstained have not produced a square panel, and saying so
    /// is worth more than recomputing what `panelDesign` already reported under a new name.
    @Test("gates that never used the third verdict get an honest no-op, not a recomputation")
    func noOpWhenTheGatesAreStillBinary() async {
        var trace = PipelineTrace()
        await pipeline().auditSquareDesign(trace: &trace, history: binaryHistory())
        guard case let .noOp(reason) = outcome(trace) else {
            Issue.record("expected .noOp, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(reason.contains("used 2 of 3 verdicts"))
        #expect(reason.contains("nothing here is square yet"))
    }

    @Test("a three-way panel reports the counts inside its band that no panel reaches")
    func ranOnAThreeWayPanel() async {
        var trace = PipelineTrace()
        await pipeline().auditSquareDesign(trace: &trace, history: threeWayHistory())
        guard case let .ran(detail) = outcome(trace) else {
            Issue.record("expected .ran, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(detail.contains("12 turn(s), 3 pair(s) of gates over 3 verdicts"))
        #expect(detail.contains("no panel with these verdict rates reaches"))
        #expect(detail.contains("cannot move by a single turn"))
        #expect(detail.contains("forbids them differing on exactly one turn"))
        #expect(detail.contains("built to 0.6000"))
    }

    /// The repair target is a real policy input, so a target these rates forbid is a real failure.
    @Test("a target no panel with these verdict rates reaches is reported as failed")
    func failedOnAnUnreachableTarget() async {
        var trace = PipelineTrace()
        await pipeline().auditSquareDesign(
            trace: &trace, history: threeWayHistory(), rate: 11.0 / 12.0
        )
        guard case let .failed(message) = outcome(trace) else {
            Issue.record("expected .failed, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(message.contains("square repair preview refused"))
        #expect(message.contains("traceNotAttainable"))
    }

    /// The stage exists because the collapse to two categories loses this, not because it is new
    /// arithmetic. This pins that the discarded case is what makes the band gappy.
    @Test("the identical-margin pair cannot differ on exactly one turn, at three categories")
    func identicalMarginsForbidOneShort() {
        let history = threeWayHistory()
        let pairs = MetadataPipeline.squarePairs(
            history, judges: [Self.answerability, Self.stability]
        )
        guard let pair = pairs.first else {
            Issue.record("expected one pair")
            return
        }
        #expect(pair.priced.marginsAreIdentical)
        #expect(pair.observed == 10)
        #expect(pair.priced.admits(trace: 11) == false)
        #expect(pair.priced.admits(trace: 12))
        #expect(pair.priced.holes.isEmpty == false)
    }

    @Test("an absent verdict is an abstention, which is what an absent verdict means here")
    func absentVerdictsCodeAsAbstentions() {
        let history = ObservationHistory([
            PanelObservation(id: "t0", verdicts: [Self.answerability: .affirm], truth: nil),
            PanelObservation(id: "t1", verdicts: [Self.stability: .deny], truth: nil)
        ])
        let codes = MetadataPipeline.squareCodes(history, judge: Self.answerability)
        #expect(codes == [0, 2])
    }
}
