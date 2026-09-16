import ConfidenceSequenceKit
import EffectiveVoteKit
import EvalHarness
import Foundation
import Testing
@testable import AIChatApp

/// The `confidenceSequence` stage: a time-uniform interval for this app's own gate pass rate,
/// read off the same pooled stream `sequentialBound` runs its boundary over.
@Suite("Confidence sequence stage")
struct ConfidenceSequenceStageTests {
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
        trace.records.first { $0.stage == .confidenceSequence }?.outcome
    }

    private func detail(_ trace: PipelineTrace) -> String {
        if case let .ran(detail) = outcome(trace) { return detail }
        return ""
    }

    /// One gate ruling on every turn: `affirms` affirms, then `denies` denies.
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
        await pipeline().auditConfidenceSequence(trace: &trace, history: ObservationHistory([]))
        #expect(outcome(trace)?.isRefusal == false)
        if case let .skipped(reason) = outcome(trace) {
            #expect(reason.contains("this panel has produced none"))
        } else {
            Issue.record("expected skipped")
        }
    }

    @Test("a panel where every gate abstained is a no-op, not an interval around nothing")
    func allAbstained() async {
        let observations = (0..<6).map { index in
            PanelObservation(id: "turn-\(index)", verdicts: [Self.answerability: .abstain], truth: nil)
        }
        var trace = PipelineTrace()
        await pipeline().auditConfidenceSequence(trace: &trace, history: ObservationHistory(observations))
        if case let .noOp(reason) = outcome(trace) {
            #expect(reason.contains("abstention is not a trial"))
        } else {
            Issue.record("expected noOp")
        }
    }

    /// Ten straight affirms is not yet enough evidence to rule the advertised rate out, and the
    /// stage says the rate still holds rather than reading a high observed rate as a verdict.
    @Test("an advertised rate the evidence has not ruled out is reported as still admissible")
    func advertisedRateStillAdmissible() async {
        var trace = PipelineTrace()
        await pipeline().auditConfidenceSequence(trace: &trace, history: history(affirms: 10, denies: 0))
        #expect(outcome(trace)?.isRefusal == false)
        let text = detail(trace)
        #expect(text.contains("10 of 10 cast verdict(s) affirmed"))
        #expect(text.contains("the advertised rate of 0.70 is still admissible after 10 look(s)"))
    }

    /// Seventeen is not a round number, and that is the point: it is the trial the mixture
    /// martingale actually crossed `1 / alpha` at, and the stage names it rather than the trial
    /// the reader happened to look on.
    @Test("the trial the advertised rate stopped being admissible at is named, not the last one")
    func advertisedRateExcludedFromAbove() async {
        var trace = PipelineTrace()
        await pipeline().auditConfidenceSequence(trace: &trace, history: history(affirms: 20, denies: 0))
        let text = detail(trace)
        #expect(text.contains("stopped being admissible at trial 17 of 20"))
    }

    @Test("a run of straight denials rules the advertised rate out from below")
    func advertisedRateExcludedFromBelow() async {
        var trace = PipelineTrace()
        await pipeline().auditConfidenceSequence(trace: &trace, history: history(affirms: 0, denies: 10))
        let text = detail(trace)
        #expect(text.contains("0 of 10 cast verdict(s) affirmed"))
        #expect(text.contains("stopped being admissible at trial 4 of 10"))
    }

    @Test("the detail carries the interval, the budget, and both readings of the exact audit")
    func detailCarriesEveryFigure() async {
        var trace = PipelineTrace()
        await pipeline().auditConfidenceSequence(trace: &trace, history: history(affirms: 10, denies: 0))
        let text = detail(trace)
        #expect(text.contains("leaves the gate pass rate in [0.583120, 1.000000]"))
        #expect(text.contains("a width of 0.416880"))
        #expect(text.contains("a total miscoverage budget of 0.05 spent once across every look"))
        #expect(text.contains("by enumeration at a horizon of 10 trial(s) against 10 actually taken"))
        #expect(text.contains("exact miscoverage is"))
        #expect(text.contains("expected interval width there is"))
        #expect(text.contains("true rate of 0.40 reads as detection power ="))
    }

    /// The whole reason for the ceiling: the exact audit's cost grows as the square of the
    /// horizon, and a capped audit must never be reported as though it covered every look.
    @Test("a capped audit names the horizon it ran to and the looks actually taken")
    func cappedAuditIsReportedAsCapped() async {
        var trace = PipelineTrace()
        await pipeline().auditConfidenceSequence(
            trace: &trace, history: history(affirms: 12, denies: 8), auditCeiling: 5
        )
        let text = detail(trace)
        #expect(text.contains("at a horizon of 5 trial(s) against 20 actually taken"))
    }

    /// At a horizon of one trial no path can exclude anything, so there is no expected trial to
    /// quote — and quoting a zero would read as "caught immediately".
    @Test("a horizon nothing can be detected within says so rather than quoting a trial")
    func noExpectedTrialWithinHorizon() async {
        var trace = PipelineTrace()
        await pipeline().auditConfidenceSequence(
            trace: &trace, history: history(affirms: 6, denies: 2), auditCeiling: 1
        )
        let text = detail(trace)
        #expect(text.contains("no path within that horizon reaches it"))
    }

    @Test("the stage raises no refusal on any ordinary path")
    func neverRefuses() async {
        let histories = [
            history(affirms: 1, denies: 0),
            history(affirms: 20, denies: 0),
            history(affirms: 0, denies: 10),
            history(affirms: 4, denies: 4)
        ]
        for panel in histories {
            var trace = PipelineTrace()
            await pipeline().auditConfidenceSequence(trace: &trace, history: panel)
            #expect(outcome(trace)?.isRefusal == false)
        }
    }

    @Test("a configuration the construction declines reaches the trace as failed")
    func refusalReachesTheTrace() async {
        var trace = PipelineTrace()
        // A budget of 1 leaves no evidence level to cross: `log(1 / alpha)` is zero.
        await pipeline().auditConfidenceSequence(
            trace: &trace, history: history(affirms: 4, denies: 4), alpha: 1
        )
        if case let .failed(message) = outcome(trace) {
            #expect(message.contains("was declined"))
            #expect(message.contains("alpha=1.00"))
        } else {
            Issue.record("expected failed")
        }
    }

    @Test("a reference rate outside (0, 1) is declined rather than clamped into range")
    func refusedReferenceRate() async {
        let result = await MetadataPipeline.confidenceSequenceRead(
            [true, false, true],
            parameters: MetadataPipeline.ConfidenceSequenceParameters(
                alpha: 0.05, referenceRate: 1, degradedRate: 0.4, auditCeiling: 60
            )
        )
        if case let .refused(message) = result {
            #expect(message.contains("advertised rate of 1.00"))
            #expect(message.contains("no interval was published"))
        } else {
            Issue.record("expected refused")
        }
    }

    /// The same solver call is two different readings depending on what it was handed, and the
    /// package's own flag is what decides which — not this app's guess about the arguments.
    @Test("the label follows the package's own flag rather than the argument order")
    func labelFollowsTheFlag() {
        let coverage = ExactExclusionProfile(
            referenceRate: 0.7, trueRate: 0.7, horizon: 10,
            exclusionProbability: 0.01, expectedFirstExclusionTrial: 4
        )
        let power = ExactExclusionProfile(
            referenceRate: 0.7, trueRate: 0.4, horizon: 10,
            exclusionProbability: 0.3, expectedFirstExclusionTrial: 5
        )
        #expect(MetadataPipeline.confidenceSequenceLabel(coverage) == "miscoverage")
        #expect(MetadataPipeline.confidenceSequenceLabel(power) == "detection power")
    }

    /// The interval and the boundary must be answers about one session, so the stream is the
    /// boundary stage's own rather than a second pooling of the same panel.
    @Test("the stage reads the same pooled stream the sequential boundary does")
    func sharesTheSequentialBoundStream() async {
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
        let panel = ObservationHistory(observations)
        #expect(MetadataPipeline.sequentialBoundStream(panel) == [true, false, true])
        var trace = PipelineTrace()
        await pipeline().auditConfidenceSequence(trace: &trace, history: panel)
        #expect(detail(trace).contains("2 of 3 cast verdict(s) affirmed"))
    }

    @Test("the stage names its package and label in the catalog")
    func catalogEntry() {
        #expect(PipelineStage.confidenceSequence.package == "ConfidenceSequenceKit")
        #expect(PipelineStage.confidenceSequence.title == "Confidence sequence")
    }

    /// The two stages are configured off one pair of rates on purpose: a second pair here would
    /// make them a comparison of configurations rather than of methods.
    @Test("the advertised and degraded rates are the boundary stage's own")
    func ratesAreSharedWithTheBoundary() {
        #expect(MetadataPipeline.confidenceSequenceReferenceRate == MetadataPipeline.sequentialBoundHealthyRate)
        #expect(MetadataPipeline.confidenceSequenceDegradedRate == MetadataPipeline.sequentialBoundUnhealthyRate)
    }
}
