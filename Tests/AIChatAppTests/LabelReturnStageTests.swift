import ExplorationChannelKit
import Foundation
import GuardrailKit
import LabelReturnKit
import Testing
@testable import AIChatApp

/// The stage that closes the loop `explorationChannel` opened.
///
/// These exercise the stage rather than the stage table. `PipelineTraceTests` asserts that every
/// package has a case in `PipelineStage`, which is a claim about a switch statement — a stage can
/// sit in that table and be wired to nothing at all.
@Suite("Label return stage")
struct LabelReturnStageTests {
    private let gate = 0.30

    private func pipeline() -> PostModelPipeline {
        PostModelPipeline(guardrail: GuardrailPipeline(policy: GuardrailPolicy()))
    }

    private func admitted(_ ids: [String], into ledger: ExplorationLedger, depth: Double = 0.05) async {
        for id in ids {
            let candidate = ExplorationBudget.candidate(id: id, score: gate + depth, threshold: gate)
            await ledger.record(
                candidate,
                ruling: .admitted(cost: depth, admissionProbability: ExplorationBudget.frequency)
            )
        }
    }

    @Test("a turn that was not an exploration still reports what is outstanding")
    func notAnExploration() async {
        let ledger = ExplorationLedger()
        await admitted(["explore-0"], into: ledger)
        var trace = PipelineTrace()
        await pipeline().routeReturn(wasWrong: false, trace: &trace, ledger: ledger)

        let record = trace.records.first { $0.stage == .labelReturn }
        guard case let .ran(detail)? = record?.outcome else {
            Issue.record("expected the stage to run, got \(String(describing: record?.outcome))")
            return
        }
        #expect(detail.contains("not an exploration"))
        #expect(detail.contains("closing the books here reports 0.000"))
        #expect(detail.contains("100% of the explored population still unlabelled"))
    }

    @Test("with nothing ever explored the stage says so instead of reporting a rate of zero")
    func nothingExplored() async {
        var trace = PipelineTrace()
        await pipeline().routeReturn(wasWrong: true, trace: &trace, ledger: ExplorationLedger())

        let record = trace.records.first { $0.stage == .labelReturn }
        guard case let .noOp(reason)? = record?.outcome else {
            Issue.record("expected a no-op, got \(String(describing: record?.outcome))")
            return
        }
        #expect(reason.contains("nothing has been explored yet"))
    }

    @Test("a wrong verdict is routed to the admission that bought it")
    func routesAWrongVerdict() async {
        let ledger = ExplorationLedger()
        await admitted(["explore-0"], into: ledger)
        var trace = PipelineTrace()
        trace.noteExploration(id: "explore-0")
        await pipeline().routeReturn(wasWrong: true, trace: &trace, ledger: ledger)

        #expect(await ledger.labelledEntries.map(\.id) == ["explore-0"])
        #expect(await ledger.outstandingEntries.isEmpty)
        let record = trace.records.first { $0.stage == .labelReturn }
        guard case let .ran(detail)? = record?.outcome else {
            Issue.record("expected the stage to run")
            return
        }
        #expect(detail.contains("wrong, which is what buying it was for"))
        // One admission at p = 0.20, labelled a loss: the whole explored population is a loss.
        #expect(detail.contains("closing the books here reports 1.000"))
        #expect(detail.contains("0% of the explored population still unlabelled"))
        #expect(detail.contains("withdrawn"))
    }

    @Test("a right verdict is routed too, and says so")
    func routesARightVerdict() async {
        let ledger = ExplorationLedger()
        await admitted(["explore-0"], into: ledger)
        var trace = PipelineTrace()
        trace.noteExploration(id: "explore-0")
        await pipeline().routeReturn(wasWrong: false, trace: &trace, ledger: ledger)

        guard case let .ran(detail)? = trace.records.first(where: { $0.stage == .labelReturn })?.outcome else {
            Issue.record("expected the stage to run")
            return
        }
        #expect(detail.contains("this exploration was right"))
        #expect(detail.contains("closing the books here reports 0.000"))
        #expect(detail.contains("holds"))
    }

    @Test("an id the channel never admitted is a bookkeeping fault, not a quiet no-op")
    func unknownAdmission() async {
        let ledger = ExplorationLedger()
        await admitted(["explore-0"], into: ledger)
        var trace = PipelineTrace()
        trace.noteExploration(id: "explore-9")
        await pipeline().routeReturn(wasWrong: true, trace: &trace, ledger: ledger)

        guard case let .skipped(reason)? = trace.records.first(where: { $0.stage == .labelReturn })?.outcome else {
            Issue.record("expected a skip naming the missing admission")
            return
        }
        #expect(reason.contains("explore-9"))
        #expect(reason.contains("nowhere to go"))
    }

    @Test("the outstanding half widens the bracket rather than being counted clean")
    func outstandingWidensTheBracket() async {
        let ledger = ExplorationLedger()
        await admitted(["explore-0", "explore-1", "explore-2", "explore-3"], into: ledger)
        var trace = PipelineTrace()
        trace.noteExploration(id: "explore-0")
        await pipeline().routeReturn(wasWrong: true, trace: &trace, ledger: ledger)

        guard case let .ran(detail)? = trace.records.first(where: { $0.stage == .labelReturn })?.outcome else {
            Issue.record("expected the stage to run")
            return
        }
        // One loss back of four equally weighted admissions: floor 0.250, ceiling 1.000.
        #expect(detail.contains("closing the books here reports 0.250"))
        #expect(detail.contains("at most 1.000"))
        #expect(detail.contains("75% of the explored population still unlabelled"))
    }

    @Test("the audit reads the channel's own entries")
    func auditReadsEntries() async {
        let ledger = ExplorationLedger()
        await admitted(["explore-0", "explore-1"], into: ledger)
        await ledger.label("explore-0", loss: 1)
        guard let reading = await PostModelPipeline.audit(entries: await ledger.allEntries) else {
            Issue.record("expected a reading")
            return
        }
        #expect(reading.lower == 0.5)
        #expect(reading.upper == 1.0)
        #expect(reading.unobservedShare == 0.5)
        #expect(PostModelPipeline.describe(reading).contains("Re-audit at 0.05"))
    }

    @Test("an empty ledger produces no reading rather than an interval around zero")
    func emptyLedgerHasNoReading() async {
        #expect(await PostModelPipeline.audit(entries: []) == nil)
    }

    @Test("the stage belongs to its package and has a title")
    func tableEntry() {
        #expect(PipelineStage.labelReturn.package == "LabelReturnKit")
        #expect(PipelineStage.labelReturn.title == "Label return")
    }

    @Test("the trace carries the exploration id typed, not parsed back out of prose")
    func traceCarriesTheID() {
        var trace = PipelineTrace()
        #expect(trace.explorationID == nil)
        trace.noteExploration(id: "explore-7")
        #expect(trace.explorationID == "explore-7")
    }
}
