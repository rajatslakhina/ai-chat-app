import AbstentionPolicyKit
import EffectiveVoteKit
import EvalHarness
import Foundation
import ProxyLabelKit
import Testing
@testable import AIChatApp

/// The `proxyLabel` stage, which answers the sentence the stage beside it ends on.
///
/// `effectiveVote` reports that this app has no label for which gate was right. It does have one —
/// `checkConsistency` decides, per turn, whether the answer contradicted its own sources. This
/// suite pins what that label is worth: the regime it lands in, the refusal that stops it being
/// used, and the fact that the stage says both out loud rather than quietly switching basis.
@Suite("Proxy label stage")
struct ProxyLabelStageTests {
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
        trace.records.first { $0.stage == .proxyLabel }?.outcome
    }

    private func proposals(turns: Int) -> [LabelProposal] {
        (0..<turns).flatMap { index in
            ["answerability", "verdict stability"].map { judge in
                LabelProposal(
                    judge: JudgeID(judge),
                    item: ItemID("turn-\(index)"),
                    label: index.isMultiple(of: 3) ? .incorrect : .correct,
                    derivedFrom: .laterContradiction,
                    scope: .item
                )
            }
        }
    }

    @Test("a turn nothing has come back about is skipped with the outcome count, not passed")
    func nothingLabelledYet() async {
        var trace = PipelineTrace()
        await pipeline().auditProxyLabel(trace: &trace, proposals: [], outcomes: 0)
        #expect(
            outcome(trace)
                == .skipped(
                    reason: "no turn has both a filed gate reading and a downstream outcome yet, "
                        + "so nothing has been labelled (0 outcome(s) recorded)"
                )
        )
    }

    @Test("labels that exist are reported with the regime they landed in")
    func regimeIsReported() async throws {
        var trace = PipelineTrace()
        await pipeline().auditProxyLabel(trace: &trace, proposals: proposals(turns: 9), outcomes: 9)
        guard case let .ran(detail)? = outcome(trace) else {
            Issue.record("labelled turns should run, not \(String(describing: outcome(trace)))")
            return
        }
        #expect(detail.contains("18 label(s) derived across 9 turn(s)"))
        #expect(detail.contains("6 call a gate wrong"))
        #expect(detail.contains("regime is sharedAcrossJudges"))
        #expect(detail.contains("not chosen"))
    }

    /// The whole point of the stage. Deriving the label is easy and using it is not, and the
    /// reading has to carry the second half or a reader takes the first for permission.
    @Test("the reading names the refusal that stops effectiveVote switching basis")
    func refusalIsQuoted() async throws {
        var trace = PipelineTrace()
        await pipeline().auditProxyLabel(trace: &trace, proposals: proposals(turns: 20), outcomes: 20)
        guard case let .ran(detail)? = outcome(trace) else {
            Issue.record("labelled turns should run, not \(String(describing: outcome(trace)))")
            return
        }
        #expect(detail.contains("not priced: audit too small: 0 audited labels against a required 30"))
        #expect(detail.contains("effectiveVote stays on vote agreement"))
        #expect(detail.contains("manufactures correlation"))
    }

    @Test("the stage belongs to its package and is named for a reader")
    func catalogued() {
        #expect(PipelineStage.proxyLabel.package == "ProxyLabelKit")
        #expect(PipelineStage.proxyLabel.title == "Proxy label")
        #expect(PipelineStage.allCases.contains(.proxyLabel))
    }
}

/// The half of `PanelHistoryStore` that this stage added: an id going out, an outcome coming back.
@Suite("Panel history outcomes")
struct PanelHistoryOutcomeTests {
    private func reading(_ origin: String, _ signal: SignalReading) -> AbstentionSignal {
        AbstentionSignal(origin: SignalOrigin(origin), reading: signal)
    }

    @Test("recording readings hands back the id those readings were filed under")
    func recordReturnsAnID() async {
        let store = PanelHistoryStore()
        let first = await store.record([reading("answerability", .clear)])
        let second = await store.record([reading("answerability", .clear)])
        #expect(first == "turn-1")
        #expect(second == "turn-2")
    }

    @Test("a turn where no gate spoke is not an observation and gets no id")
    func emptyReadingsAreNotATurn() async {
        let store = PanelHistoryStore()
        #expect(await store.record([]) == nil)
        #expect(await store.outcomeCount == 0)
    }

    @Test("an outcome filed against a turn labels every gate that ruled on it")
    func outcomeLabelsTheWholePanel() async throws {
        let store = PanelHistoryStore()
        let turn = try #require(
            await store.record([
                reading("answerability", .clear),
                reading("temporal validity", .refuse("expired"))
            ])
        )
        await store.recordOutcome(turn: turn, contradicted: true)
        let proposals = await store.labelProposals
        #expect(await store.outcomeCount == 1)
        #expect(proposals.count == 2)
        #expect(NoiseRegime.detect(in: proposals) == .sharedAcrossJudges)
        // The gate that admitted the turn was wrong; the one that objected was right.
        let byJudge = Dictionary(uniqueKeysWithValues: proposals.map { ($0.judge, $0.label) })
        #expect(byJudge[JudgeID("answerability")] == .incorrect)
        #expect(byJudge[JudgeID("temporal validity")] == .correct)
    }

    @Test("readings with no outcome produce no labels at all")
    func noOutcomeNoLabels() async {
        let store = PanelHistoryStore()
        await store.record([reading("answerability", .clear)])
        #expect(await store.labelProposals.isEmpty)
        #expect(NoiseRegime.detect(in: await store.labelProposals) == nil)
    }

    @Test("the trace carries the turn id between the two ends of the pipeline")
    func traceCarriesTheTurn() {
        var trace = PipelineTrace()
        #expect(trace.panelTurnID == nil)
        trace.notePanelTurn(id: "turn-7")
        #expect(trace.panelTurnID == "turn-7")
    }
}

/// The path this app cannot reach today and the stage is built to take the moment it can.
@Suite("Proxy label pricing")
struct ProxyLabelPricingTests {
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

    /// Somebody read forty turns and recorded which gate was actually right.
    private func audited(count: Int, wrong: Int) -> AuditSample {
        AuditSample(
            entries: (0..<count).map { index in
                let truth: Correctness = index.isMultiple(of: 2) ? .correct : .incorrect
                return AuditedLabel(
                    judge: JudgeID("answerability"),
                    item: ItemID("turn-\(index)"),
                    proxy: index < wrong ? truth.flipped : truth,
                    truth: truth
                )
            }
        )
    }

    @Test("this app supplies no audited turns, and that is the finding rather than an oversight")
    func appHasNoAudit() {
        #expect(MetadataPipeline.auditedTurns.count == 0)
    }

    @Test("given an audited subset the stage prices the label instead of refusing")
    func pricesWhenAudited() async throws {
        var trace = PipelineTrace()
        let proposals = (0..<9).map { index in
            LabelProposal(
                judge: JudgeID("answerability"),
                item: ItemID("turn-\(index)"),
                label: .correct,
                derivedFrom: .laterContradiction,
                scope: .item
            )
        }
        await pipeline().auditProxyLabel(
            trace: &trace,
            proposals: proposals,
            outcomes: 9,
            audited: audited(count: 40, wrong: 6)
        )
        guard case let .ran(detail)? = trace.records.first(where: { $0.stage == .proxyLabel })?.outcome else {
            Issue.record("an audited subset should price, not refuse")
            return
        }
        #expect(detail.contains("priced from 40 audited turn(s)"))
        #expect(detail.contains("n=40"))
        #expect(!detail.contains("not priced"))
    }
}
