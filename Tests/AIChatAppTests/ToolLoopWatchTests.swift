import Foundation
import LoopGuardKit
import Testing
@testable import AIChatApp

@Suite("ToolLoopWatch")
struct ToolLoopWatchTests {
    private let signal = LoopSignal.exactRepeat(call: "calculator({})", count: 2)

    @Test("the stage belongs to LoopGuardKit")
    func catalog() {
        #expect(PipelineStage.loopGuard.package == "LoopGuardKit")
        #expect(PipelineStage.loopGuard.title == "Loop guard")
    }

    @Test("the policy can fire inside a three-hop turn")
    func policyFitsTheHopCap() async {
        let guardian = LoopGuard(policy: ToolLoopWatch.policy)
        let step = ToolLoopWatch.step(toolName: "calculator", argumentsJSON: Data(#"{"expression":"1+1"}"#.utf8),
                                      observation: "2")
        #expect(await guardian.record(step) == .proceed)
        #expect(await guardian.record(step) == .nudge(.exactRepeat(call: step.callKey, count: 2), nudgesRemaining: 0))
        #expect(await guardian.record(step) == .halt(.exactRepeat(call: step.callKey, count: 3)))
    }

    @Test("arguments are canonicalized and non-UTF-8 bytes fall back to an empty object")
    func stepArguments() {
        let reordered = ToolLoopWatch.step(toolName: "t", argumentsJSON: Data(#"{ "b":1, "a":2 }"#.utf8), observation: "x")
        #expect(reordered.arguments == #"{"a":2,"b":1}"#)
        let invalid = ToolLoopWatch.step(toolName: "t", argumentsJSON: Data([0xFF, 0xFE]), observation: "x")
        #expect(invalid.arguments == "{}")
    }

    @Test("observations differing only in JSON key order compare equal")
    func canonicalObservation() {
        let first = ToolLoopWatch.canonicalObservation(#"Tool "calculator" returned: {"expression":"1+1","result":2}"#)
        let second = ToolLoopWatch.canonicalObservation(#"Tool "calculator" returned: {"result":2,"expression":"1+1"}"#)
        #expect(first == second)
        #expect(ToolLoopWatch.canonicalObservation("no json here") == "no json here")
        #expect(ToolLoopWatch.canonicalObservation("list: [2, 1]") == "list: [2,1]")
        let data = Data(#"{"expression":"1+1"}"#.utf8)
        #expect(ToolLoopWatch.step(toolName: "calculator", argumentsJSON: data, observation: #"r: {"b":1,"a":2}"#)
            == ToolLoopWatch.step(toolName: "calculator", argumentsJSON: data, observation: #"r: {"a":2,"b":1}"#))
    }

    @Test("the observation is untouched unless the verdict is a nudge")
    func observationNudge() {
        #expect(ToolLoopWatch.observation("2", after: .proceed) == "2")
        #expect(ToolLoopWatch.observation("2", after: .halt(signal)) == "2")
        #expect(ToolLoopWatch.observation("2", after: .nudge(signal, nudgesRemaining: 0)) == "2\n\n" + signal.nudge)
    }

    @Test("the summary keeps the last nudge and the halt")
    func summaryAbsorb() {
        var summary = ToolLoopWatch.Summary()
        summary.absorb(.proceed)
        summary.absorb(.nudge(signal, nudgesRemaining: 0))
        #expect(summary.watched == 2)
        #expect(summary.nudged == signal)
        #expect(summary.halted == nil)
        summary.absorb(.halt(signal))
        #expect(summary.halted == signal)
    }

    @Test("every outcome the stage can report")
    func outcomes() {
        #expect(ToolLoopWatch.outcome(for: .init(), toolsAvailable: false)
            == .skipped(reason: "no tools registered for this conversation"))
        #expect(ToolLoopWatch.outcome(for: .init(), toolsAvailable: true)
            == .noOp(reason: "no tool call this turn; nothing to watch"))
        #expect(ToolLoopWatch.outcome(for: .init(watched: 2), toolsAvailable: true)
            == .ran(detail: "watched 2 tool step(s); no loop"))
        #expect(ToolLoopWatch.outcome(for: .init(watched: 3, nudged: signal), toolsAvailable: true)
            == .ran(detail: "nudged after \(signal.summary); the model changed course"))
        #expect(ToolLoopWatch.outcome(for: .init(watched: 3, nudged: signal, halted: signal), toolsAvailable: true)
            == .refused(ToolLoopWatch.refusal(for: signal)))
    }

    @Test("the refusal has a headline, an explanation and a recovery")
    func refusalShape() {
        let refusal = ToolLoopWatch.refusal(for: signal)
        #expect(refusal.stage == .loopGuard)
        #expect(refusal.headline == "Stopped a repeating tool call")
        #expect(refusal.explanation.contains(signal.summary))
        #expect(refusal.recovery == .switchModel)
        #expect(refusal.recoveryTitle == "Choose another model")
    }

    @Test("a replayed turn records the loop guard as skipped, ahead of the structural skips")
    func replayed() {
        let records = ProviderEffectExecutor.replayedRecords()
        let loop = records.first { $0.stage == .loopGuard }
        #expect(loop?.outcome == .skipped(reason: ToolLoopWatch.replayReason))
        #expect(records.suffix(2).map(\.stage) == [.scopeDrift, .toolCallScheduling])
    }
}
