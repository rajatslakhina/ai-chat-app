import EffectiveVoteKit
import EvalHarness
import Foundation
import SequentialBoundKit
import Testing
@testable import AIChatApp

/// The `sequentialBound` stage: whether this app's live gate-affirmation stream already has
/// enough evidence to call the session's affirm rate healthy or unhealthy, without waiting for a
/// fixed sample size.
@Suite("Sequential bound stage")
struct SequentialBoundStageTests {
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
        trace.records.first { $0.stage == .sequentialBound }?.outcome
    }

    private func detail(_ trace: PipelineTrace) -> String {
        if case let .ran(detail) = outcome(trace) { return detail }
        return ""
    }

    /// Builds a history where every observed turn carries the same one gate's verdict, `affirms`
    /// affirms followed by `denies` denies.
    private func history(affirms: Int, denies: Int, judge: JudgeIdentity = answerability) -> ObservationHistory {
        var observations: [PanelObservation] = []
        for index in 0..<(affirms + denies) {
            let verdict: Verdict = index < affirms ? .affirm : .deny
            observations.append(PanelObservation(id: "turn-\(index)", verdicts: [judge: verdict], truth: nil))
        }
        return ObservationHistory(observations)
    }

    @Test("an empty panel is skipped, not run")
    func emptyPanel() async {
        var trace = PipelineTrace()
        await pipeline().auditSequentialBound(trace: &trace, history: ObservationHistory([]))
        #expect(outcome(trace)?.isRefusal == false)
        if case .skipped = outcome(trace) {} else { Issue.record("expected skipped") }
    }

    @Test("a panel where every gate abstained is a no-op, not a stream of failures")
    func allAbstained() async {
        let observations = (0..<6).map { index in
            PanelObservation(id: "turn-\(index)", verdicts: [Self.answerability: .abstain], truth: nil)
        }
        var trace = PipelineTrace()
        await pipeline().auditSequentialBound(trace: &trace, history: ObservationHistory(observations))
        if case let .noOp(reason) = outcome(trace) {
            #expect(reason.contains("abstention is not a trial"))
        } else {
            Issue.record("expected noOp")
        }
    }

    @Test("a run of straight affirms crosses the boundary toward healthy")
    func straightAffirmsReachHealthy() async {
        let panel = history(affirms: 10, denies: 0)
        var trace = PipelineTrace()
        await pipeline().auditSequentialBound(trace: &trace, history: panel)
        #expect(outcome(trace)?.isRefusal == false)
        let text = detail(trace)
        #expect(text.contains("crossed the boundary in favor of healthy"))
    }

    @Test("a run of straight denials crosses the boundary toward unhealthy")
    func straightDenialsReachUnhealthy() async {
        let panel = history(affirms: 0, denies: 10)
        var trace = PipelineTrace()
        await pipeline().auditSequentialBound(trace: &trace, history: panel)
        let text = detail(trace)
        #expect(text.contains("crossed the boundary in favor of unhealthy"))
    }

    @Test("a single trial has not crossed anything and says so rather than guessing")
    func singleTrialStillWatches() async {
        let panel = history(affirms: 1, denies: 0)
        var trace = PipelineTrace()
        await pipeline().auditSequentialBound(trace: &trace, history: panel)
        #expect(outcome(trace)?.isRefusal == false)
        let text = detail(trace)
        #expect(text.contains("no boundary crossed after 1 trial(s); still watching"))
    }

    @Test("the detail carries the tested rates, the trial count and the design characteristics")
    func detailCarriesEveryFigure() async {
        let panel = history(affirms: 10, denies: 0)
        var trace = PipelineTrace()
        await pipeline().auditSequentialBound(trace: &trace, history: panel)
        let text = detail(trace)
        #expect(text.contains("tests healthy=0.70 against unhealthy=0.40"))
        #expect(text.contains("miss budget of 0.10"))
        #expect(text.contains("false-alarm budget of 0.05"))
        #expect(text.contains("cumulative log-likelihood ratio"))
        #expect(text.contains("by design, at a horizon of 50 trials"))
    }

    @Test("the stage raises no refusal on any ordinary path")
    func neverRefuses() async {
        let histories = [
            history(affirms: 1, denies: 0),
            history(affirms: 10, denies: 0),
            history(affirms: 0, denies: 10),
            history(affirms: 4, denies: 4)
        ]
        for panel in histories {
            var trace = PipelineTrace()
            await pipeline().auditSequentialBound(trace: &trace, history: panel)
            #expect(outcome(trace)?.isRefusal == false)
        }
    }

    @Test("a refusal to build the boundary reaches the trace as failed, not just the helper")
    func refusalReachesTheTrace() async {
        let panel = history(affirms: 4, denies: 4)
        var trace = PipelineTrace()
        // Equal rates give the two hypotheses nothing to distinguish.
        await pipeline().auditSequentialBound(
            trace: &trace, history: panel, unhealthyRate: 0.5, healthyRate: 0.5
        )
        if case let .failed(message) = outcome(trace) {
            #expect(message.contains("was declined"))
        } else {
            Issue.record("expected failed")
        }
    }

    @Test("indistinguishable hypotheses are declined rather than silently swapped for distinguishable ones")
    func refusedIndistinguishable() async {
        let result = await MetadataPipeline.sequentialBoundRead(
            [true, true, true],
            parameters: MetadataPipeline.SequentialBoundParameters(
                unhealthyRate: 0.5, healthyRate: 0.5, missBudget: 0.10, falseAlarmBudget: 0.05, horizon: 50
            )
        )
        if case let .refused(message) = result {
            #expect(message.contains("boundary for unhealthy=0.50 vs healthy=0.50"))
        } else {
            Issue.record("expected refused")
        }
    }

    @Test("a horizon below one is declined rather than characterised anyway")
    func refusedHorizon() async {
        let result = await MetadataPipeline.sequentialBoundRead(
            [true, false, true],
            parameters: MetadataPipeline.SequentialBoundParameters(
                unhealthyRate: 0.4, healthyRate: 0.7, missBudget: 0.10, falseAlarmBudget: 0.05, horizon: 0
            )
        )
        if case let .refused(message) = result {
            #expect(message.contains("operating characteristics"))
        } else {
            Issue.record("expected refused")
        }
    }

    @Test("the stream drops abstentions and orders by turn, then by judge")
    func streamDropsAbstentionsAndOrders() {
        let observations = [
            PanelObservation(
                id: "turn-0",
                verdicts: [Self.answerability: .affirm, Self.stability: .abstain],
                truth: nil
            ),
            PanelObservation(
                id: "turn-1",
                verdicts: [Self.answerability: .deny, Self.stability: .affirm],
                truth: nil
            )
        ]
        let stream = MetadataPipeline.sequentialBoundStream(ObservationHistory(observations))
        // turn-0: only `answerability` cast (affirm = true). turn-1: both judges cast, in
        // `history.judges`' sorted order (answerability, then "verdict stability" alphabetically
        // orders after "answerability").
        #expect(stream == [true, false, true])
    }

    @Test("the stage names its package and label in the catalog")
    func catalogEntry() {
        #expect(PipelineStage.sequentialBound.package == "SequentialBoundKit")
        #expect(PipelineStage.sequentialBound.title == "Sequential bound")
    }
}
