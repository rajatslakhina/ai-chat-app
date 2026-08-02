import Foundation
import Testing
@testable import AIChatApp

private func refusal(_ stage: PipelineStage) -> Refusal {
    Refusal(
        stage: stage,
        headline: "Out of budget",
        explanation: "the account has nothing left",
        recovery: .addCredit
    )
}

@Suite("Diagnostics report")
struct DiagnosticsReportTests {
    /// Before anything has been sent, every declared stage is unreached. That is the useful thing
    /// to say — an empty screen would leave a reader unable to tell "nothing has run" from "this
    /// screen is broken".
    @Test("an empty trace puts every declared stage in the unreached list")
    func emptyTrace() {
        let trace = PipelineTrace()
        #expect(DiagnosticsReport.sections(for: trace).isEmpty)
        #expect(trace.unreached.count == PipelineStage.allCases.count)

        let summary = DiagnosticsReport.summary(for: trace)
        #expect(summary.unreached == PipelineStage.allCases.count)
        #expect(summary.accountedFor == PipelineStage.allCases.count)
    }

    /// The invariant the screen claims: every stage appears exactly once, either with records or in
    /// the unreached section. A stage that fell out of both would be invisible, which is the exact
    /// failure `PipelineTrace.unreached` exists to prevent.
    @Test("every stage is accounted for exactly once, whatever the trace contains")
    func everyStageAccountedFor() {
        var trace = PipelineTrace()
        trace.record(.promptTemplate, .ran(detail: "chat.system v1"), durationMs: 3)
        trace.record(.guardrailInput, .noOp(reason: "no findings"))
        trace.record(.cacheLookup, .skipped(reason: "cache disabled in Settings"))
        trace.record(.budgetReserve, .refused(refusal(.budgetReserve)))
        trace.record(.metering, .failed(message: "boom"))

        let sections = DiagnosticsReport.sections(for: trace)
        let shown = Set(sections.map(\.stage)).union(trace.unreached)
        #expect(shown == Set(PipelineStage.allCases))
        #expect(sections.count + trace.unreached.count == PipelineStage.allCases.count)

        let summary = DiagnosticsReport.summary(for: trace)
        #expect(summary.ran == 1)
        #expect(summary.noOp == 1)
        #expect(summary.skipped == 1)
        #expect(summary.refused == 1)
        #expect(summary.failed == 1)
        #expect(summary.accountedFor == PipelineStage.allCases.count)
    }

    /// Declaration order *is* the architecture, so the screen reads in the same order as the
    /// pipeline diagram rather than in whatever order the stages happened to finish.
    @Test("sections follow pipeline order, not recording order")
    func pipelineOrder() {
        var trace = PipelineTrace()
        trace.record(.tracing, .ran(detail: "3 spans"))
        trace.record(.promptTemplate, .ran(detail: "chat.system v1"))
        trace.record(.budgetSettle, .ran(detail: "settled"))

        #expect(
            DiagnosticsReport.sections(for: trace).map(\.stage)
                == [.promptTemplate, .budgetSettle, .tracing]
        )
    }

    /// `PipelineTrace.outcome(for:)` returns the *first* record, which only makes sense if a second
    /// can exist. Collapsing to one here would hide the extra.
    @Test("a stage recorded twice shows both records")
    func repeatedStage() {
        var trace = PipelineTrace()
        trace.record(.providerRouting, .ran(detail: "answered by openai/gpt-4o"), durationMs: 900)
        trace.record(.providerRouting, .failed(message: "stream dropped"), durationMs: 12)

        let sections = DiagnosticsReport.sections(for: trace)
        #expect(sections.count == 1)
        #expect(sections.first?.records.count == 2)
        #expect(DiagnosticsReport.summary(for: trace).ran == 1)
        #expect(DiagnosticsReport.summary(for: trace).failed == 1)
    }

    @Test("total duration is the measured sum, reported as-is")
    func duration() {
        var trace = PipelineTrace()
        trace.record(.retrieval, .ran(detail: "2 passages"), durationMs: 14)
        trace.record(.grounding, .ran(detail: "3 of 4"), durationMs: 6)
        #expect(DiagnosticsReport.summary(for: trace).totalDurationMs == 20)
    }
}

@Suite("Outcome styling")
struct StageOutcomeStyleTests {
    /// A refusal is the system working and a failure is the system breaking. If they ever render
    /// identically, the distinction the type exists to preserve has been thrown away at the last
    /// possible moment.
    @Test("refused and failed never share a word, a colour or an icon")
    func refusalIsNotFailure() {
        let refused = StageOutcome.refused(refusal(.budgetReserve))
        let failed = StageOutcome.failed(message: "boom")

        #expect(refused.diagnosticsLabel != failed.diagnosticsLabel)
        #expect(refused.diagnosticsTint != failed.diagnosticsTint)
        #expect(refused.diagnosticsIcon != failed.diagnosticsIcon)
    }

    @Test("every outcome has a distinct label and icon")
    func distinctStyles() {
        let outcomes: [StageOutcome] = [
            .ran(detail: "a"),
            .noOp(reason: "b"),
            .skipped(reason: "c"),
            .refused(refusal(.semanticRoute)),
            .failed(message: "d")
        ]
        #expect(Set(outcomes.map(\.diagnosticsLabel)).count == outcomes.count)
        #expect(Set(outcomes.map(\.diagnosticsIcon)).count == outcomes.count)
        #expect(outcomes.allSatisfy { !$0.diagnosticsLabel.isEmpty })
    }

    /// A stage the user switched off must not read like a stage that quietly did nothing.
    @Test("skipped and no-op are visually different")
    func skippedIsNotNoOp() {
        let skipped = StageOutcome.skipped(reason: "cache disabled in Settings")
        let noOp = StageOutcome.noOp(reason: "miss")
        #expect(skipped.diagnosticsTint != noOp.diagnosticsTint)
        #expect(skipped.diagnosticsLabel != noOp.diagnosticsLabel)
    }
}
