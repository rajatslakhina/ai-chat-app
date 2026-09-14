import EffectiveVoteKit
import EvalHarness
import Foundation
import RepeatedSuccessKit
import Testing
@testable import AIChatApp

/// The `repeatedSuccess` stage: whether this app's pooled gate affirm rate can answer a
/// question about more than one turn at a time.
@Suite("Repeated success stage")
struct RepeatedSuccessStageTests {
    private static let answerability = JudgeIdentity("answerability")
    private static let stability = JudgeIdentity("verdict stability")
    private static let grounding = JudgeIdentity("grounding")

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
        trace.records.first { $0.stage == .repeatedSuccess }?.outcome
    }

    private func detail(_ trace: PipelineTrace) -> String {
        if case let .ran(detail) = outcome(trace) { return detail }
        return ""
    }

    /// Builds a history where each gate affirms a stated number of the same turns.
    private func history(_ affirms: [JudgeIdentity: Int], turns: Int) -> ObservationHistory {
        var observations: [PanelObservation] = []
        for index in 0..<turns {
            var verdicts: [JudgeIdentity: Verdict] = [:]
            for (judge, count) in affirms {
                verdicts[judge] = index < count ? .affirm : .deny
            }
            observations.append(PanelObservation(id: "turn-\(index)", verdicts: verdicts, truth: nil))
        }
        return ObservationHistory(observations)
    }

    @Test("an empty panel is skipped, not run")
    func emptyPanel() async {
        var trace = PipelineTrace()
        await pipeline().auditRepeatedSuccess(trace: &trace, history: ObservationHistory([]))
        #expect(outcome(trace)?.isRefusal == false)
        if case .skipped = outcome(trace) {} else { Issue.record("expected skipped") }
    }

    @Test("a panel where every gate abstained is a no-op, not a panel of failures")
    func allAbstained() async {
        let observations = (0..<8).map { index in
            PanelObservation(
                id: "turn-\(index)",
                verdicts: [Self.answerability: .abstain, Self.stability: .abstain],
                truth: nil
            )
        }
        var trace = PipelineTrace()
        await pipeline().auditRepeatedSuccess(trace: &trace, history: ObservationHistory(observations))
        if case let .noOp(reason) = outcome(trace) {
            #expect(reason.contains("abstention is not a failed attempt"))
        } else {
            Issue.record("expected noOp")
        }
    }

    @Test("a panel too short for the run is a no-op rather than a shorter run silently answered")
    func tooShortForTheRun() async {
        let short = history([Self.answerability: 2, Self.stability: 1], turns: 3)
        var trace = PipelineTrace()
        await pipeline().auditRepeatedSuccess(trace: &trace, history: short, repetitions: 5)
        if case let .noOp(reason) = outcome(trace) {
            #expect(reason.contains("busiest cast 3 verdict"))
            #expect(reason.contains("run of 5"))
        } else {
            Issue.record("expected noOp")
        }
    }

    @Test("gates that behave alike report a gap within binomial noise")
    func homogeneousGates() async {
        let alike = history(
            [Self.answerability: 7, Self.stability: 6, Self.grounding: 7], turns: 10
        )
        var trace = PipelineTrace()
        await pipeline().auditRepeatedSuccess(trace: &trace, history: alike)
        #expect(outcome(trace)?.isRefusal == false)
        #expect(detail(trace).contains("safe to raise to a power here"))
    }

    @Test("gates that do not behave alike are reported as not one population")
    func heterogeneousGates() async {
        let split = history(
            [Self.answerability: 10, Self.stability: 1, Self.grounding: 10], turns: 10
        )
        var trace = PipelineTrace()
        await pipeline().auditRepeatedSuccess(trace: &trace, history: split)
        let text = detail(trace)
        #expect(text.contains("NOT one population"))
        #expect(text.contains("no single rate can stand in for them"))
    }

    @Test("the detail carries both questions and the panel bound")
    func detailCarriesEveryFigure() async {
        let split = history(
            [Self.answerability: 10, Self.stability: 2, Self.grounding: 9], turns: 10
        )
        var trace = PipelineTrace()
        await pipeline().auditRepeatedSuccess(trace: &trace, history: split)
        let text = detail(trace)
        #expect(text.contains("pooled affirm rate"))
        #expect(text.contains("naive all-of-5"))
        #expect(text.contains("naive any-of-5"))
        #expect(text.contains("distribution-free bound across gates"))
        #expect(text.contains("0.95 confidence"))
    }

    @Test("gates shorter than the run are dropped and counted, not folded in")
    func shortGatesAreDropped() async {
        var observations: [PanelObservation] = []
        for index in 0..<10 {
            var verdicts: [JudgeIdentity: Verdict] = [
                Self.answerability: index < 8 ? .affirm : .deny,
                Self.stability: index < 3 ? .affirm : .deny
            ]
            // The third gate only ruled on the first two turns at all.
            verdicts[Self.grounding] = index < 2 ? .affirm : .abstain
            observations.append(PanelObservation(id: "turn-\(index)", verdicts: verdicts, truth: nil))
        }
        var trace = PipelineTrace()
        await pipeline().auditRepeatedSuccess(trace: &trace, history: ObservationHistory(observations))
        #expect(detail(trace).contains("1 dropped"))
    }

    @Test("an unbalanced gate panel withholds the closed form rather than quoting it")
    func unbalancedWithholdsTheClosedForm() async {
        var observations: [PanelObservation] = []
        for index in 0..<12 {
            var verdicts: [JudgeIdentity: Verdict] = [Self.answerability: index < 9 ? .affirm : .deny]
            // A second gate that joined late, so the two have different attempt counts.
            if index >= 4 { verdicts[Self.stability] = index < 8 ? .affirm : .deny }
            observations.append(PanelObservation(id: "turn-\(index)", verdicts: verdicts, truth: nil))
        }
        var trace = PipelineTrace()
        await pipeline().auditRepeatedSuccess(trace: &trace, history: ObservationHistory(observations))
        #expect(detail(trace).contains("did not all rule on the same number of turns"))
    }

    @Test("the stage raises no refusal on any path")
    func neverRefuses() async {
        let histories = [
            ObservationHistory([]),
            history([Self.answerability: 2], turns: 3),
            history([Self.answerability: 10, Self.stability: 1], turns: 10)
        ]
        for panel in histories {
            var trace = PipelineTrace()
            await pipeline().auditRepeatedSuccess(trace: &trace, history: panel)
            #expect(outcome(trace)?.isRefusal == false)
        }
    }

    @Test("rows read abstentions out rather than scoring them as failures")
    func rowsDropAbstentions() {
        var observations: [PanelObservation] = []
        for index in 0..<6 {
            let verdict: Verdict = index < 2 ? .affirm : (index < 4 ? .deny : .abstain)
            observations.append(
                PanelObservation(id: "turn-\(index)", verdicts: [Self.answerability: verdict], truth: nil)
            )
        }
        let rows = MetadataPipeline.repeatedSuccessRows(ObservationHistory(observations))
        #expect(rows.count == 1)
        #expect(rows[0].attempts == 4)
        #expect(rows[0].successes == 2)
    }

    @Test("the stage names its package and label in the catalog")
    func catalogEntry() {
        #expect(PipelineStage.repeatedSuccess.package == "RepeatedSuccessKit")
        #expect(PipelineStage.repeatedSuccess.title == "Repeated success")
    }

    @Test("a refusal reaches the trace as failed, not just the helper that produced it")
    func refusalReachesTheTrace() async {
        let panel = history([Self.answerability: 8, Self.stability: 3], turns: 10)
        var trace = PipelineTrace()
        // A level of exactly 1.0 is outside the open interval the bound accepts.
        await pipeline().auditRepeatedSuccess(trace: &trace, history: panel, repetitions: 5, level: 1.0)
        if case let .failed(message) = outcome(trace) {
            #expect(message.contains("was declined"))
        } else {
            Issue.record("expected failed")
        }
    }

    @Test("a run longer than any gate is declined rather than answered")
    func refusedRun() async {
        let panel = history([Self.answerability: 6, Self.stability: 4], turns: 8)
        let rows = MetadataPipeline.repeatedSuccessRows(panel)
        let result = await MetadataPipeline.repeatedSuccessRead(rows, repetitions: 40, level: 0.95)
        if case let .refused(message) = result {
            #expect(message.contains("run of 40 was declined"))
        } else {
            Issue.record("expected refused")
        }
    }

    @Test("a level outside the open interval is declined rather than clamped")
    func refusedLevel() async {
        let panel = history([Self.answerability: 6, Self.stability: 4], turns: 8)
        let rows = MetadataPipeline.repeatedSuccessRows(panel)
        let result = await MetadataPipeline.repeatedSuccessRead(rows, repetitions: 5, level: 1.0)
        if case .refused = result {} else { Issue.record("expected refused") }
    }

    @Test("duplicate gate rows do not form a panel")
    func unbuildablePanel() async {
        let rows = [
            TaskAttempts(identifier: "same", attempts: 8, successes: 6),
            TaskAttempts(identifier: "same", attempts: 8, successes: 2)
        ]
        let result = await MetadataPipeline.repeatedSuccessRead(rows, repetitions: 5, level: 0.95)
        if case let .refused(reason) = result {
            #expect(reason.contains("share an identity"))
        } else {
            Issue.record("expected refused")
        }
    }
}
