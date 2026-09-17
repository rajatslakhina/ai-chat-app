import EffectiveVoteKit
import EvalHarness
import Foundation
import SequentialContrastKit
import Testing
@testable import AIChatApp

/// The `sequentialContrast` stage: a time-uniform interval for the **difference** between two
/// gates' admit rates, read off the same panel its neighbours pool into one rate.
@Suite("Sequential contrast stage")
struct SequentialContrastStageTests {
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
        trace.records.first { $0.stage == .sequentialContrast }?.outcome
    }

    private func detail(_ trace: PipelineTrace) -> String {
        if case let .ran(detail) = outcome(trace) { return detail }
        return ""
    }

    /// Both gates ruling on every turn: `aOnly` turns A affirms alone, `agreed` turns both
    /// affirm, `bOnly` turns B affirms alone, and `neither` turns both deny.
    private func paired(agreed: Int, aOnly: Int, bOnly: Int, neither: Int) -> ObservationHistory {
        var observations: [PanelObservation] = []
        func append(_ left: Verdict, _ right: Verdict, _ count: Int) {
            for _ in 0..<count {
                observations.append(
                    PanelObservation(
                        id: "turn-\(observations.count)",
                        verdicts: [Self.answerability: left, Self.stability: right],
                        truth: nil
                    )
                )
            }
        }
        append(.affirm, .affirm, agreed)
        append(.affirm, .deny, aOnly)
        append(.deny, .affirm, bOnly)
        append(.deny, .deny, neither)
        return ObservationHistory(observations)
    }

    @Test("an empty panel is skipped, not run")
    func emptyPanel() async {
        var trace = PipelineTrace()
        await pipeline().auditSequentialContrast(trace: &trace, history: ObservationHistory([]))
        #expect(outcome(trace)?.isRefusal == false)
        if case let .skipped(reason) = outcome(trace) {
            #expect(reason.contains("this panel has produced none"))
        } else {
            Issue.record("expected skipped")
        }
    }

    @Test("a panel with only one gate has nothing to compare and is a no-op")
    func singleJudge() async {
        let observations = (0..<6).map { index in
            PanelObservation(id: "turn-\(index)", verdicts: [Self.answerability: .affirm], truth: nil)
        }
        var trace = PipelineTrace()
        await pipeline().auditSequentialContrast(trace: &trace, history: ObservationHistory(observations))
        if case let .noOp(reason) = outcome(trace) {
            #expect(reason.contains("no turn has two gates casting a verdict together"))
        } else {
            Issue.record("expected noOp")
        }
    }

    /// Two gates that never ruled on the same turn are not a comparison, and pairing an
    /// abstention against a cast verdict would invent a disagreement nobody expressed.
    @Test("two gates that never ruled on the same turn are a no-op, not a manufactured tie")
    func neverOverlapping() async {
        let observations = [
            PanelObservation(
                id: "turn-0",
                verdicts: [Self.answerability: .affirm, Self.stability: .abstain],
                truth: nil
            ),
            PanelObservation(
                id: "turn-1",
                verdicts: [Self.answerability: .abstain, Self.stability: .affirm],
                truth: nil
            )
        ]
        var trace = PipelineTrace()
        await pipeline().auditSequentialContrast(trace: &trace, history: ObservationHistory(observations))
        if case let .noOp(reason) = outcome(trace) {
            #expect(reason.contains("abstention is not a verdict"))
        } else {
            Issue.record("expected noOp")
        }
    }

    @Test("turns where either gate abstained are dropped and counted, not silently ignored")
    func abstentionsAreDroppedAndCounted() {
        var observations: [PanelObservation] = []
        observations.append(
            PanelObservation(
                id: "turn-0",
                verdicts: [Self.answerability: .affirm, Self.stability: .affirm],
                truth: nil
            )
        )
        observations.append(
            PanelObservation(
                id: "turn-1",
                verdicts: [Self.answerability: .affirm, Self.stability: .abstain],
                truth: nil
            )
        )
        observations.append(
            PanelObservation(
                id: "turn-2",
                verdicts: [Self.answerability: .abstain, Self.stability: .deny],
                truth: nil
            )
        )
        let pairing = MetadataPipeline.sequentialContrastPairing(ObservationHistory(observations))
        #expect(pairing?.stream.count == 1)
        #expect(pairing?.unpairedTurns == 2)
        #expect(pairing?.judgeA == "answerability")
        #expect(pairing?.judgeB == "verdict stability")
    }

    /// The reading the pooled stages cannot produce: the two gates' own rate intervals overlap
    /// for the whole run, and the difference interval rules zero out anyway.
    @Test("a one-sided disagreement excludes zero and names the turn it stopped holding at")
    func oneSidedDisagreementExcludesZero() async {
        var trace = PipelineTrace()
        await pipeline().auditSequentialContrast(
            trace: &trace, history: paired(agreed: 0, aOnly: 20, bOnly: 0, neither: 0)
        )
        #expect(outcome(trace)?.isRefusal == false)
        let text = detail(trace)
        #expect(text.contains("answerability against verdict stability over 20 turn(s) both ruled on"))
        #expect(text.contains("stopped being admissible at turn"))
    }

    @Test("two gates admitting at the same rate leave zero admissible")
    func indistinguishableGates() async {
        var trace = PipelineTrace()
        await pipeline().auditSequentialContrast(
            trace: &trace, history: paired(agreed: 6, aOnly: 2, bOnly: 2, neither: 6)
        )
        let text = detail(trace)
        #expect(text.contains("is still admissible after 16 look(s)"))
        #expect(text.contains("they agreed on 12 and disagreed on 4 of those turns"))
    }

    @Test("the detail carries both constructions, the agreement rate and the exact audit")
    func detailCarriesEveryFigure() async {
        var trace = PipelineTrace()
        await pipeline().auditSequentialContrast(
            trace: &trace, history: paired(agreed: 5, aOnly: 4, bOnly: 1, neither: 2)
        )
        let text = detail(trace)
        #expect(text.contains("(0 turn(s) had no paired verdict and were dropped)"))
        #expect(text.contains("leaves the difference in admit rates at ["))
        #expect(text.contains("an agreement rate of 0.583333"))
        #expect(text.contains("discarding that pairing widens the same reading to ["))
        #expect(text.contains("x wider"))
        #expect(text.contains("by enumeration at a horizon of 12 turn(s) against 12 actually paired"))
        #expect(text.contains("exact miscoverage is"))
        #expect(text.contains("detection power against the same horizon is"))
        #expect(text.contains("where the unpaired construction reads"))
        #expect(text.contains("a gain of"))
    }

    /// The whole reason for the ceiling: this solver's lattice is a full dimension worse than
    /// its neighbour's, and a capped audit must never be reported as though it covered every turn.
    @Test("a capped audit names the horizon it ran to and the turns actually paired")
    func cappedAuditIsReportedAsCapped() async {
        var trace = PipelineTrace()
        await pipeline().auditSequentialContrast(
            trace: &trace,
            history: paired(agreed: 6, aOnly: 4, bOnly: 2, neither: 8),
            auditCeiling: 6
        )
        #expect(detail(trace).contains("at a horizon of 6 turn(s) against 20 actually paired"))
    }

    @Test("the stage raises no refusal on any ordinary path")
    func neverRefuses() async {
        let panels = [
            paired(agreed: 1, aOnly: 0, bOnly: 0, neither: 0),
            paired(agreed: 0, aOnly: 10, bOnly: 0, neither: 0),
            paired(agreed: 0, aOnly: 0, bOnly: 10, neither: 0),
            paired(agreed: 4, aOnly: 2, bOnly: 2, neither: 4)
        ]
        for panel in panels {
            var trace = PipelineTrace()
            await pipeline().auditSequentialContrast(trace: &trace, history: panel)
            #expect(outcome(trace)?.isRefusal == false)
        }
    }

    @Test("a configuration the construction declines reaches the trace as failed")
    func refusalReachesTheTrace() async {
        var trace = PipelineTrace()
        // A budget of 1 leaves no evidence level to cross: `log(1 / alpha)` is zero.
        await pipeline().auditSequentialContrast(
            trace: &trace, history: paired(agreed: 3, aOnly: 2, bOnly: 1, neither: 2), alpha: 1
        )
        if case let .failed(message) = outcome(trace) {
            #expect(message.contains("was declined"))
            #expect(message.contains("comparing answerability against verdict stability"))
            #expect(message.contains("no interval was published"))
        } else {
            Issue.record("expected failed")
        }
    }

    @Test("a reference difference off the scale is declined rather than clamped into range")
    func refusedReferenceDifference() async {
        let pairing = MetadataPipeline.SequentialContrastPairing(
            judgeA: "a",
            judgeB: "b",
            stream: [PairedOutcome(systemA: true, systemB: false)],
            unpairedTurns: 0
        )
        let result = await MetadataPipeline.sequentialContrastRead(
            pairing,
            parameters: MetadataPipeline.SequentialContrastParameters(
                alpha: 0.05, referenceDifference: 2, auditCeiling: 30
            )
        )
        if case let .refused(message) = result {
            #expect(message.contains("comparing a against b over 1 paired turn(s)"))
        } else {
            Issue.record("expected refused")
        }
    }

    /// The audit path cannot produce an empty pairing, but a direct caller can, and a rate over
    /// no turns is absent rather than zero. Reporting it is what keeps the detail line's
    /// agreement figure free of a default no test could reach.
    @Test("a pairing carrying no turns is reported rather than defaulted to a zero rate")
    func emptyStreamIsReported() async {
        let pairing = MetadataPipeline.SequentialContrastPairing(
            judgeA: "answerability", judgeB: "verdict stability", stream: [], unpairedTurns: 4
        )
        let result = await MetadataPipeline.sequentialContrastRead(
            pairing,
            parameters: MetadataPipeline.SequentialContrastParameters(
                alpha: 0.05, referenceDifference: 0, auditCeiling: 30
            )
        )
        if case let .refused(message) = result {
            #expect(message.contains("over zero paired turn(s)"))
            #expect(message.contains("absent rather than zero"))
        } else {
            Issue.record("expected refused")
        }
    }

    @Test("the joint is derived from the observed tally rather than assumed")
    func jointComesFromTheTally() throws {
        let tally = try ContrastTally(
            bothSucceeded: 5, onlyASucceeded: 3, onlyBSucceeded: 1, neitherSucceeded: 1
        )
        let joint = try MetadataPipeline.sequentialContrastJoint(tally)
        #expect(abs(joint.bothSucceed - 0.5) < 1e-12)
        #expect(abs(joint.onlyASucceeds - 0.3) < 1e-12)
        #expect(abs(joint.onlyBSucceeds - 0.1) < 1e-12)
        #expect(abs(joint.difference - 0.2) < 1e-12)
    }

    /// The same solver call is two different readings depending on what it was handed, and the
    /// package's own flag is what decides which — not this app's guess about the arguments.
    @Test("the label follows the package's own flag rather than the argument order")
    func labelFollowsTheFlag() {
        let coverage = ExactContrastProfile(
            referenceDifference: 0.2, trueDifference: 0.2, horizon: 10,
            exclusionProbability: 0.01, expectedFirstExclusionTrial: 4
        )
        let power = ExactContrastProfile(
            referenceDifference: 0, trueDifference: 0.2, horizon: 10,
            exclusionProbability: 0.3, expectedFirstExclusionTrial: 5
        )
        #expect(MetadataPipeline.sequentialContrastLabel(coverage) == "miscoverage")
        #expect(MetadataPipeline.sequentialContrastLabel(power) == "detection power")
    }

    @Test("the stage names its package and label in the catalog")
    func catalogEntry() {
        #expect(PipelineStage.sequentialContrast.package == "SequentialContrastKit")
        #expect(PipelineStage.sequentialContrast.title == "Sequential contrast")
    }

    /// The budget is its neighbours' on purpose: a different one here would make the three
    /// stages a comparison of configurations rather than of methods.
    @Test("the budget matches the stages it is read beside")
    func budgetIsShared() {
        #expect(MetadataPipeline.sequentialContrastAlpha == MetadataPipeline.confidenceSequenceAlpha)
        #expect(MetadataPipeline.sequentialContrastReferenceDifference == 0)
    }

    /// The ceiling is lower than its neighbour's because this solver's lattice is a full
    /// dimension worse, and that relationship is asserted rather than left in a comment.
    @Test("the audit ceiling is below the confidence sequence stage's")
    func ceilingIsLowerThanItsNeighbours() {
        #expect(
            MetadataPipeline.sequentialContrastAuditCeiling
                < MetadataPipeline.confidenceSequenceAuditCeiling
        )
    }

    @Test("the formatters carry a sign only where a difference needs one")
    func formatters() {
        #expect(MetadataPipeline.sequentialContrastFormat(0.5, 2) == "0.50")
        #expect(MetadataPipeline.sequentialContrastSigned(-0.25, 2) == "-0.25")
        #expect(MetadataPipeline.sequentialContrastSigned(0.25, 2) == "+0.25")
    }
}
