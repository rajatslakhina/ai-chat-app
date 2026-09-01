import AbstentionPolicyKit
import EffectiveVoteKit
import EvalHarness
import Foundation
import Testing
@testable import AIChatApp

/// The `effectiveVote` stage, which audits the one number the arbiter is standing on.
///
/// `PreModelPipeline.dependenceGraph` declares that verdict stability derives from the
/// answerability gate and that source independence shares an input with temporal validity. Both
/// declarations change what the arbiter counts and neither has ever been measured. This suite pins
/// the three readings the stage can produce, the sentence that stops a vote-agreement number being
/// read as an error-agreement one, and the mapping from a gate's reading to a vote.
@Suite("Effective vote stage")
struct EffectiveVoteStageTests {
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

    private static let answerability = JudgeIdentity("answerability")
    private static let stability = JudgeIdentity("verdict stability")
    private static let independence = JudgeIdentity("source independence")
    private static let temporal = JudgeIdentity("temporal validity")

    /// A history where the two declared pairs behave differently from each other, so a reading
    /// that collapsed them into one number would be visibly wrong.
    private func history(count: Int, extraJudge: JudgeIdentity? = nil) -> ObservationHistory {
        ObservationHistory((0..<count).map { index in
            let base: Verdict = index.isMultiple(of: 2) ? .affirm : .deny
            let derived: Verdict = index % 7 == 0 ? flip(base) : base
            let independent: Verdict = index % 3 == 0 ? .deny : .affirm
            let dated: Verdict = index % 3 == 0 ? .deny : (index % 5 == 0 ? .deny : .affirm)
            var verdicts: [JudgeIdentity: Verdict] = [
                Self.answerability: base,
                Self.stability: derived,
                Self.independence: independent,
                Self.temporal: dated
            ]
            if let extraJudge {
                verdicts[extraJudge] = .affirm
            }
            return PanelObservation(id: "turn-\(index)", verdicts: verdicts, truth: nil)
        })
    }

    private func flip(_ verdict: Verdict) -> Verdict { verdict == .affirm ? .deny : .affirm }

    private func outcome(_ trace: PipelineTrace) -> StageOutcome? {
        trace.records.first { $0.stage == .effectiveVote }?.outcome
    }

    @Test("a panel nobody has observed is skipped with a reason, not silently passed")
    func neverObserved() async {
        var trace = PipelineTrace()
        await pipeline().auditEffectiveVote(trace: &trace, history: ObservationHistory())
        #expect(
            outcome(trace)
                == .skipped(
                    reason: "no turn has had a gate file a reading yet, "
                        + "so the panel has never been observed"
                )
        )
    }

    @Test("a history too thin to publish reports the figure it withheld, not just a refusal")
    func thinHistoryCarriesTheWithheldFigure() async throws {
        var trace = PipelineTrace()
        await pipeline().auditEffectiveVote(trace: &trace, history: history(count: 6))
        guard case let .noOp(reason)? = outcome(trace) else {
            Issue.record("a thin history should be a no-op, not \(String(describing: outcome(trace)))")
            return
        }
        #expect(reason.contains("6 observed turn(s)"))
        #expect(reason.contains("policy requires 30"))
        // The useful half of the refusal: a reader can tell a healthy panel from a collapsed one.
        #expect(reason.contains("the withheld figure was"))
        #expect(reason.contains("of 4 gates"))
    }

    @Test("an observed panel is measured and both declared edges are held against it")
    func publishesAndComparesDeclarations() async throws {
        var trace = PipelineTrace()
        await pipeline().auditEffectiveVote(trace: &trace, history: history(count: 60))
        guard case let .ran(detail)? = outcome(trace) else {
            Issue.record("60 turns should publish, not \(String(describing: outcome(trace)))")
            return
        }
        #expect(detail.contains("independent voices by vote agreement"))
        #expect(detail.contains("answerability x verdict stability declared"))
        #expect(detail.contains("source independence x temporal validity declared"))
        // The limit travels with the number rather than being left for a reader to infer.
        #expect(detail.contains("basis is vote agreement, not error agreement"))
    }

    @Test("a gate that never varies is reported unmeasurable, never scored as independent")
    func constantGateIsNotScoredZero() async {
        var trace = PipelineTrace()
        await pipeline().auditEffectiveVote(
            trace: &trace,
            // A fifth judge widens the interval, so this needs more turns than the four-gate
            // cases above before the same policy will publish anything at all.
            history: history(count: 200, extraJudge: JudgeIdentity("always-clear"))
        )
        guard case let .ran(detail)? = outcome(trace) else {
            Issue.record("expected a published reading, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(detail.contains("pair(s) unmeasurable, not scored as independent"))
    }

    @Test("a panel sharing no name with the declared graph says so rather than inventing an edge")
    func noDeclaredEdgeMeasurable() async {
        let anonymous = ObservationHistory((0..<60).map { index in
            PanelObservation(
                id: "turn-\(index)",
                verdicts: [
                    "gate-a": index.isMultiple(of: 2) ? .affirm : .deny,
                    "gate-b": index % 3 == 0 ? .deny : .affirm
                ],
                truth: nil
            )
        })
        var trace = PipelineTrace()
        await pipeline().auditEffectiveVote(trace: &trace, history: anonymous)
        guard case let .ran(detail)? = outcome(trace) else {
            Issue.record("expected a published reading, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(detail.contains("no declared edge could be measured over 60 turns"))
    }

    @Test("the stage reads the live store through its default entry point")
    func readsTheLiveStore() async {
        let store = PanelHistoryStore()
        var trace = PipelineTrace()
        await pipeline().auditEffectiveVote(trace: &trace, store: store)
        // An untouched store has observed nothing, which is a skip rather than a measurement.
        #expect(outcome(trace)?.isRefusal == false)
        guard case .skipped? = outcome(trace) else {
            Issue.record("an empty store should skip")
            return
        }
    }
}

@Suite("Panel history store")
struct PanelHistoryStoreTests {
    @Test("a clear gate votes to proceed, a concerned one votes against, an unavailable one abstains")
    func verdictMapping() {
        #expect(PanelHistoryStore.verdict(for: .clear) == .affirm)
        #expect(PanelHistoryStore.verdict(for: .concern(.low, "something")) == .deny)
        #expect(PanelHistoryStore.verdict(for: .refuse("no")) == .deny)
        #expect(PanelHistoryStore.verdict(for: .unavailable("did not run")) == .abstain)
    }

    @Test("a turn where no gate spoke is not an observation of the panel")
    func emptyTurnIsNotRecorded() async {
        let store = PanelHistoryStore()
        await store.record([])
        #expect(await store.history.isEmpty)
    }

    @Test("filed readings become one observation per turn, and gates that filed nothing are absent")
    func recordsFiledReadings() async {
        let store = PanelHistoryStore()
        await store.record([
            AbstentionSignal(origin: SignalOrigin("answerability"), reading: .clear),
            AbstentionSignal(origin: SignalOrigin("temporal validity"), reading: .concern(.low, "stale"))
        ])
        await store.record([
            AbstentionSignal(origin: SignalOrigin("answerability"), reading: .concern(.low, "thin"))
        ])
        let history = await store.history
        #expect(history.count == 2)
        #expect(history.judges == ["answerability", "temporal validity"])
        // The second turn never asked the temporal gate, so it holds no vote for it.
        #expect(history.observations[1].verdict(of: "temporal validity") == nil)
        #expect(history.observations[0].verdict(of: "answerability") == .affirm)
        #expect(history.observations[1].verdict(of: "answerability") == .deny)
    }

    @Test("declared strengths are read off the graph the arbiter actually uses")
    func declaredStrengthsComeFromTheLiveGraph() {
        let declared = PanelHistoryStore.declaredStrengths()
        #expect(declared.count == PreModelPipeline.dependenceGraph.edges.count)
        let sharedInput = JudgePair("source independence", "temporal validity")
        #expect(declared[sharedInput] != nil)
        let derived = JudgePair("answerability", "verdict stability")
        #expect(declared[derived] != nil)
    }
}
