import ChanceAgreementKit
import EffectiveVoteKit
import EvalHarness
import Foundation
import Testing
@testable import AIChatApp

/// The `chanceAgreement` stage, which names the chance term its three siblings spend silently.
///
/// `effectiveVote` publishes a coefficient per pair, `sampleWidth` prices its interval and
/// `familyError` corrects the page for multiplicity. All of them subtract a chance term and none
/// of them says which one, or attaches the null's dispersion, or reports that unequal affirm-rates
/// cap the coefficient below one before either gate has spoken. The suite pins all four outcomes.
@Suite("Chance agreement stage")
struct ChanceAgreementStageTests {
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
        trace.records.first { $0.stage == .chanceAgreement }?.outcome
    }

    /// Four gates with genuinely different affirm-rates, so ceilings and coefficients both bite.
    private func spreadHistory(count: Int = 40) -> ObservationHistory {
        ObservationHistory((0..<count).map { index in
            PanelObservation(
                id: "turn-\(index)",
                verdicts: [
                    Self.answerability: index % 10 < 8 ? .affirm : .deny,
                    Self.stability: index % 10 < 7 ? .affirm : .deny,
                    Self.independence: index % 10 < 4 ? .affirm : .deny,
                    Self.temporal: index % 10 < 3 ? .affirm : .deny
                ],
                truth: nil
            )
        })
    }

    /// Two gates that affirmed every turn, which is the shape this app's panel really takes.
    private func constantHistory(count: Int = 20) -> ObservationHistory {
        ObservationHistory((0..<count).map { index in
            PanelObservation(
                id: "turn-\(index)",
                verdicts: [Self.answerability: .affirm, Self.stability: .affirm],
                truth: nil
            )
        })
    }

    @Test("a fresh install is quiet, and says why rather than reporting nothing")
    func skippedOnFreshInstall() async {
        var trace = PipelineTrace()
        await pipeline().auditChanceAgreement(trace: &trace, history: ObservationHistory([]))
        guard case let .skipped(reason) = outcome(trace) else {
            Issue.record("expected .skipped, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(reason.contains("no rate"))
    }

    @Test("one gate is not a pair, and agreement is a property of a pair")
    func noOpOnSingleGate() async {
        let history = ObservationHistory((0..<5).map {
            PanelObservation(id: "turn-\($0)", verdicts: [Self.answerability: .affirm], truth: nil)
        })
        var trace = PipelineTrace()
        await pipeline().auditChanceAgreement(trace: &trace, history: history)
        guard case let .noOp(reason) = outcome(trace) else {
            Issue.record("expected .noOp, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(reason.contains("there is no pair"))
    }

    @Test("gates that affirmed every turn admit no chance term, and that is the finding")
    func noOpWhenEveryGateIsConstant() async {
        var trace = PipelineTrace()
        await pipeline().auditChanceAgreement(trace: &trace, history: constantHistory())
        guard case let .noOp(reason) = outcome(trace) else {
            Issue.record("expected .noOp, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(reason.contains("always"))
        #expect(reason.contains("skill"))
    }

    @Test("a panel with spread prices every pair and reports the ceiling beside the coefficient")
    func ranOnSpreadPanel() async {
        var trace = PipelineTrace()
        await pipeline().auditChanceAgreement(trace: &trace, history: spreadHistory())
        guard case let .ran(detail) = outcome(trace) else {
            Issue.record("expected .ran, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(detail.contains("6 pair(s) priced"))
        #expect(detail.contains("item-permutation"))
        #expect(detail.contains("capping the coefficient below one"))
        #expect(detail.contains("strongest"))
    }

    @Test("matching affirm-rates leave a coefficient of one reachable, and it says so")
    func ranWithNoCeiling() async {
        let history = ObservationHistory((0..<20).map { index in
            PanelObservation(
                id: "turn-\(index)",
                verdicts: [
                    Self.answerability: index % 2 == 0 ? .affirm : .deny,
                    Self.stability: index % 4 < 2 ? .affirm : .deny
                ],
                truth: nil
            )
        })
        var trace = PipelineTrace()
        await pipeline().auditChanceAgreement(trace: &trace, history: history)
        guard case let .ran(detail) = outcome(trace) else {
            Issue.record("expected .ran, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(detail.contains("a coefficient of one is reachable"))
    }

    @Test("a level the ledger cannot use is the stage failing, not the panel being quiet")
    func failsOnUnusableLevel() async {
        var trace = PipelineTrace()
        await pipeline().auditChanceAgreement(trace: &trace, history: spreadHistory(), level: 1.5)
        guard case let .failed(message) = outcome(trace) else {
            Issue.record("expected .failed, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(message.contains("levelOutOfRange"))
    }

    @Test("the stage is in the table, mapped to its package and named for a reader")
    func catalogued() {
        #expect(PipelineStage.chanceAgreement.package == "ChanceAgreementKit")
        #expect(PipelineStage.chanceAgreement.title == "Chance agreement")
        #expect(PipelineStage.allCases.contains(.chanceAgreement))
    }

    @Test("the pairs it builds are the binary affirm grid, which is what makes prevalence askable")
    func pairsAreBinaryAffirmGrades() {
        let history = spreadHistory(count: 10)
        let pairs = MetadataPipeline.chancePairs(from: history, judges: history.judges)
        #expect(pairs.count == 6)
        for (_, pair) in pairs {
            #expect(pair.categoryCount == 2)
            #expect(pair.itemCount == 10)
            #expect(throws: Never.self) { _ = try ParadoxDiagnostics(pair: pair) }
        }
    }

    @Test("the term it spends is the exact mean of the scheme it names")
    func spentTermIsTheSchemeMean() throws {
        let history = spreadHistory()
        let pairs = MetadataPipeline.chancePairs(from: history, judges: history.judges)
        let pair = try #require(pairs.first?.1)
        let mean = ExactChanceMoments(scheme: .itemPermutation, pair: pair).mean
        let cohen = ClosedFormBaseline.cohen.expectedAgreement(for: pair)
        #expect(abs(cohen - mean) <= max(cohen.ulp, mean.ulp))
    }

    @Test("the metadata pipeline records the stage on the path that returns no metadata")
    func recordedWhenMetadataIsNil() async {
        var trace = PipelineTrace()
        let metadata = await pipeline().generate(userText: "hi", assistantText: "   ", trace: &trace)
        #expect(metadata == nil)
        #expect(trace.records.contains { $0.stage == .chanceAgreement })
    }
}
