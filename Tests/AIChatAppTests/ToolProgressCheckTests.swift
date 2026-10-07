import Foundation
import OutcomeMonitorKit
import ProgressGateKit
import Testing
@testable import AIChatApp

@Suite("Completion check")
struct ToolProgressCheckTests {
    private struct Broken: Error {}

    @Test("the stage belongs to ProgressGateKit and reads as a completion check")
    func catalog() {
        #expect(PipelineStage.progressGate.package == "ProgressGateKit")
        #expect(PipelineStage.progressGate.title == "Completion check")
    }

    @Test("the ladder runs from asked, to a tool ran, to results checked")
    func ladder() throws {
        let ladder = try ToolProgressCheck.ladder()
        #expect(ladder.names == ["asked", "tool ran", "results checked"])
        #expect(ladder.reading(for: Evidence()).missing == ["tool.dispatched ≥ 1"])
    }

    @Test("the ledger counts dispatched calls and keeps each tool's latest verdict")
    func ledger() {
        var ledger = ToolProgressCheck.Ledger()
        ledger.absorb(tool: "current_time", dispatched: true, keptContract: false)
        ledger.absorb(tool: "calculator", dispatched: true, keptContract: false)
        ledger.absorb(tool: "calculator", dispatched: true, keptContract: nil)
        #expect(ledger.broken == ["calculator", "current_time"], "an error result leaves the breach standing")
        ledger.absorb(tool: "calculator", dispatched: true, keptContract: true)
        ledger.absorb(tool: "calculator", dispatched: false, keptContract: nil)
        #expect(ledger.dispatched == 4)
        #expect(ledger.broken == ["current_time"])
        #expect(ledger.evidence == Evidence(["tool.dispatched": 4, "contracts.broken": 1]))
    }

    @Test("an answer is accepted only when the evidence reaches the final stage")
    func outcomes() {
        var kept = ToolProgressCheck.Ledger()
        kept.absorb(tool: "calculator", dispatched: true, keptContract: true)
        #expect(ToolProgressCheck.outcome(answeredWith: kept, toolsAvailable: true) == .ran(
            detail: "answer supported by evidence: 1 tool result(s), and every tool's latest result kept "
                + "its outcome contract"
        ))
        #expect(ToolProgressCheck.outcome(answeredWith: kept, toolsAvailable: false)
            == .skipped(reason: "no tools registered for this conversation"))
        #expect(ToolProgressCheck.outcome(answeredWith: .init(), toolsAvailable: true)
            == .noOp(reason: "model answered directly; no tool evidence to check the answer against"))

        var broken = ToolProgressCheck.Ledger()
        broken.absorb(tool: "current_time", dispatched: true, keptContract: false)
        broken.absorb(tool: "calculator", dispatched: true, keptContract: false)
        guard case let .refused(refusal) = ToolProgressCheck.outcome(answeredWith: broken, toolsAvailable: true) else {
            Issue.record("a breach the answer ignored must refuse")
            return
        }
        #expect(refusal.stage == .progressGate)
        #expect(refusal.explanation == "calculator and current_time returned results that broke their checks, "
            + "and the assistant answered without checking again. Treat the answer as unverified.")
        #expect(refusal.recovery == .retryLater(after: nil))
    }

    @Test("a ladder that cannot be built is a failure, not a pass")
    func ladderFailure() {
        var kept = ToolProgressCheck.Ledger()
        kept.absorb(tool: "calculator", dispatched: true, keptContract: true)
        let outcome = ToolProgressCheck.outcome(answeredWith: kept, toolsAvailable: true) { throw Broken() }
        guard case let .failed(message) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(message.hasPrefix("the completion ladder could not be built"))
    }

    @Test("a turn that never answered, or was replayed, records why there was nothing to check")
    func unansweredAndReplayed() {
        #expect(ToolProgressCheck.unanswered(toolsAvailable: true)
            == .skipped(reason: ToolProgressCheck.unansweredReason))
        #expect(ToolProgressCheck.unanswered(toolsAvailable: false)
            == .skipped(reason: "no tools registered for this conversation"))
        let replayed = ProviderEffectExecutor.replayedRecords().first { $0.stage == .progressGate }
        #expect(replayed?.outcome == .skipped(reason: ToolProgressCheck.replayReason))
    }

    @Test("only a violated contract counts against the answer")
    func keptContract() {
        #expect(ToolOutcomeCheck.keptContract(.conforms(tool: "calculator")))
        #expect(ToolOutcomeCheck.keptContract(.unmonitored(tool: "weather")))
    }
}
