import EvalHarness
import ExplorationChannelKit
import Foundation
import SplitContrastKit
import Testing
@testable import AIChatApp

/// The `splitContrast` stage: an anytime-valid audit of whether the exploration channel's draw
/// admits at the frequency every inverse-probability weight downstream assumes.
@Suite("Split contrast stage")
struct SplitContrastStageTests {
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
        trace.records.first { $0.stage == .splitContrast }?.outcome
    }

    private func detail(_ trace: PipelineTrace) -> String {
        if case let .ran(detail) = outcome(trace) { return detail }
        return ""
    }

    private func audit(_ draws: [Bool], declared: Double = ExplorationBudget.frequency) async -> PipelineTrace {
        var trace = PipelineTrace()
        await pipeline().auditSplitContrast(trace: &trace, draws: draws, declared: declared)
        return trace
    }

    @Test("no draw yet is skipped, not run")
    func nothingDrawn() async {
        let trace = await audit([])
        #expect(outcome(trace)?.isRefusal == false)
        if case let .skipped(reason) = outcome(trace) {
            #expect(reason.contains("this session has produced none"))
        } else {
            Issue.record("expected skipped")
        }
    }

    @Test("a channel drawing at its declared frequency is not contradicted")
    func consistentDraws() async {
        let trace = await audit((0..<20).map { $0 % 5 == 0 })
        let text = detail(trace)
        #expect(text.contains("reached its draw on 20 eligible turn(s) and admitted 4"))
        #expect(text.contains("a realised rate of 0.200000 against a declared frequency of 0.20"))
        #expect(text.contains("0.20 is still admissible after 20 draw(s)"))
        #expect(text.contains("there is no second arm with a pass rate to subtract"))
    }

    @Test("a channel that never admits is caught, and the detail names what that breaks")
    func starvedChannel() async {
        let text = detail(await audit(Array(repeating: false, count: 30)))
        #expect(text.contains("0.20 stopped being admissible at draw 29 of 30, and it is still excluded"))
        #expect(text.contains("rests on a frequency this channel did not deliver"))
        #expect(text.contains("[0.000000, "))
    }

    @Test("a later look that re-admits the declared frequency is reported, not hidden")
    func readmitted() async {
        let text = detail(await audit(Array(repeating: false, count: 29) + [true]))
        #expect(text.contains("stopped being admissible at draw 29 of 30, although the latest look re-admits it"))
    }

    @Test("a frequency the check cannot accept fails loudly rather than reading")
    func invalidDeclared() async {
        let trace = await audit([true, false], declared: 1)
        if case let .failed(message) = outcome(trace) {
            #expect(message.contains("was declined"))
            #expect(message.contains("declaredProbability 1.0 lies outside the open interval (0, 1)"))
        } else {
            Issue.record("expected failed")
        }
    }

    @Test("the draw log keeps only the rulings the draw produced")
    func drawLogFiltersRulings() async {
        let log = ExplorationDrawLog()
        await log.record(.admitted(cost: 0.1, admissionProbability: 0.2))
        await log.record(.notDrawn)
        await log.record(.tooCostly(cost: 1, remaining: 0))
        await log.record(.outsideRegion(depth: 1, maximumDepth: 0.15))
        await log.record(.notRefused)
        let draws = await log.draws
        #expect(draws == [true, false])
    }

    @Test("the log overload reads the log it is handed")
    func logOverload() async {
        let log = ExplorationDrawLog()
        await log.record(.notDrawn)
        var trace = PipelineTrace()
        await pipeline().auditSplitContrast(trace: &trace, log: log)
        #expect(detail(trace).contains("reached its draw on 1 eligible turn(s) and admitted 0"))
    }

    @Test("the stage belongs to SplitContrastKit and never refuses")
    func stageIdentity() async {
        #expect(PipelineStage.splitContrast.package == "SplitContrastKit")
        let trace = await audit(Array(repeating: false, count: 30))
        #expect(outcome(trace)?.isRefusal == false)
    }
}
