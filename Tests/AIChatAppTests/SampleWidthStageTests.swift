import EffectiveVoteKit
import EvalHarness
import Foundation
import SampleWidthKit
import Testing
@testable import AIChatApp

/// The `sampleWidth` stage, which prices the two stages above it against the turn count.
///
/// `effectiveVote` publishes an interval per pair and refuses to publish a headline figure when the
/// panel is thin, and neither the interval nor the refusal says anything about the corpus. The
/// interval is clamped to `-1...1`, which is the bound on any correlation rather than the bound on
/// one those margins could produce, and the refusal names a withheld figure without ever naming a
/// number of turns. This suite pins both readings.
@Suite("Sample width stage")
struct SampleWidthStageTests {
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
        trace.records.first { $0.stage == .sampleWidth }?.outcome
    }

    /// A history whose gates fire on a minority of turns, which is what a chat client produces and
    /// what drives the margins lopsided enough for the feasible range to bind.
    private func history(count: Int) -> ObservationHistory {
        ObservationHistory((0..<count).map { index in
            let rare: Verdict = index.isMultiple(of: 7) ? .deny : .affirm
            let alsoRare: Verdict = index.isMultiple(of: 5) ? .deny : .affirm
            return PanelObservation(
                id: "turn-\(index)",
                verdicts: [
                    Self.answerability: rare,
                    Self.stability: index.isMultiple(of: 7) ? .deny : .affirm,
                    Self.independence: alsoRare,
                    Self.temporal: index.isMultiple(of: 3) ? .deny : .affirm
                ],
                truth: nil
            )
        })
    }

    /// A history whose gates each fire on exactly half the turns.
    ///
    /// With matched margins the feasible range is the full `-1...1` sweep, so nothing can reach
    /// past it. That contrast is the finding: overreach is a property of a panel whose gates fire
    /// rarely, which is every chat client, and not of the Fisher transform being wrong.
    private func balancedHistory(count: Int) -> ObservationHistory {
        ObservationHistory((0..<count).map { index in
            PanelObservation(
                id: "turn-\(index)",
                verdicts: [
                    Self.answerability: index % 4 < 2 ? .affirm : .deny,
                    Self.stability: (index + 1) % 4 < 2 ? .affirm : .deny,
                    Self.independence: index % 8 < 4 ? .affirm : .deny,
                    Self.temporal: (index + 2) % 8 < 4 ? .affirm : .deny
                ],
                truth: nil
            )
        })
    }

    @Test("a balanced panel publishes nothing its own margins cannot express")
    func balancedPanelDoesNotOverreach() async {
        var trace = PipelineTrace()
        await pipeline().auditSampleWidth(trace: &trace, history: balancedHistory(count: 40))
        guard case let .ran(detail) = outcome(trace) else {
            Issue.record("expected the stage to measure a balanced forty-turn panel")
            return
        }
        #expect(detail.contains("every published interval sits inside its own margin-feasible range"))
    }

    /// A history long enough, and one pair associated strongly enough, that the pair clears zero.
    ///
    /// Two hundred turns is far more than this app will hold for a long time, and that is the
    /// point of quoting counts: separation is reachable, just not at forty turns.
    private func separatingHistory(count: Int) -> ObservationHistory {
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

    @Test("a pair that clears zero is counted as separated, not as another wait")
    func separationIsCounted() async {
        var trace = PipelineTrace()
        await pipeline().auditSampleWidth(trace: &trace, history: separatingHistory(count: 200))
        guard case let .ran(detail) = outcome(trace) else {
            Issue.record("expected the stage to measure a two-hundred-turn panel")
            return
        }
        #expect(detail.contains("separate from zero"))
        #expect(!detail.contains("0 of"))
    }

    @Test("a panel nobody has observed is skipped with the turn count it is waiting for")
    func neverObserved() async {
        var trace = PipelineTrace()
        await pipeline().auditSampleWidth(trace: &trace, history: ObservationHistory())
        guard case let .skipped(reason) = outcome(trace) else {
            Issue.record("expected the stage to skip on an unobserved panel")
            return
        }
        #expect(reason.contains("0 observed turn(s), no pair measurable yet"))
        #expect(reason.contains("needs"))
        #expect(reason.contains("turns that each contribute a usable pair"))
    }

    @Test("the count it quotes is the count SampleWidthKit would quote")
    func quotedCountIsTheRealOne() async throws {
        var trace = PipelineTrace()
        await pipeline().auditSampleWidth(trace: &trace, history: ObservationHistory())
        let needed = try #require(
            try SampleSufficiency.requiredCount(toSeparate: MetadataPipeline.sampleWidthTarget, from: 0)
        )
        guard case let .skipped(reason) = outcome(trace) else {
            Issue.record("expected the stage to skip on an unobserved panel")
            return
        }
        #expect(reason.contains("needs \(needed) turns"))
    }

    @Test("a measured panel is reported with what its own margins can express")
    func measuredPanelIsPriced() async {
        var trace = PipelineTrace()
        await pipeline().auditSampleWidth(trace: &trace, history: history(count: 40))
        guard case let .ran(detail) = outcome(trace) else {
            Issue.record("expected the stage to measure a forty-turn panel")
            return
        }
        #expect(detail.contains("measured pair(s) over 40 turn(s)"))
        #expect(detail.contains("separate from zero"))
        #expect(detail.contains("bounds any correlation and not one this table could have produced"))
    }

    @Test("a lopsided panel is caught publishing intervals its margins cannot express")
    func overreachIsNamed() async {
        var trace = PipelineTrace()
        await pipeline().auditSampleWidth(trace: &trace, history: history(count: 40))
        guard case let .ran(detail) = outcome(trace) else {
            Issue.record("expected the stage to measure a forty-turn panel")
            return
        }
        #expect(detail.contains("reaching past their feasible range") || detail.contains("sits inside its own"))
    }

    @Test("the overreach it reports is real: the published interval leaves the attainable range")
    func overreachIsGenuine() throws {
        let table = try SampleWidthKit.ContingencyTable(
            bothTrue: 5, firstTrueOnly: 1, secondTrueOnly: 25, bothFalse: 29
        )
        let feasible = MarginFeasibleRange(table: table)
        let published = try #require(FisherInterval.interval(r: table.phi, sampleSize: table.total))
        #expect(published.upperBound > feasible.range.upperBound)
        #expect(feasible.reach < 1)
    }

    @Test("the stage runs on the metadata path without a title")
    func runsOnTheNoTitlePath() async {
        var trace = PipelineTrace()
        let metadata = await pipeline().generate(userText: "hello", assistantText: "  ", trace: &trace)
        #expect(metadata == nil)
        #expect(outcome(trace) != nil)
    }

    @Test("the stage is mapped to the package that implements it")
    func stageIsMapped() {
        #expect(PipelineStage.sampleWidth.package == "SampleWidthKit")
        #expect(PipelineStage.sampleWidth.title == "Sample width")
    }
}
