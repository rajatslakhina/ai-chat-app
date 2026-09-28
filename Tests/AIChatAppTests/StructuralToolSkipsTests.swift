import Testing
@testable import AIChatApp

/// `scopeDrift` and `toolCallScheduling` are linked but honestly skipped. These tests pin that
/// the skip is recorded on every tool path, so neither package reads as silently unwired.
@Suite("Structural tool skips")
struct StructuralToolSkipsTests {
    @Test("each stage maps to its package and has a title")
    func catalog() {
        #expect(PipelineStage.scopeDrift.package == "ScopeDriftKit")
        #expect(PipelineStage.scopeDrift.title == "Scope drift")
        #expect(PipelineStage.toolCallScheduling.package == "ToolCallSchedulerKit")
        #expect(PipelineStage.toolCallScheduling.title == "Tool call scheduling")
    }

    @Test("the records are skips with the structural reasons, never ran or noOp")
    func records() {
        let records = StructuralToolSkips.records
        #expect(records.map(\.stage) == [.scopeDrift, .toolCallScheduling])
        #expect(records.map(\.outcome) == [
            .skipped(reason: StructuralToolSkips.scopeDriftReason),
            .skipped(reason: StructuralToolSkips.schedulingReason)
        ])
        #expect(StructuralToolSkips.schedulingReason.contains("one tool call per hop"))
    }

    @Test("turns with no tool call and replayed turns still record both skips",
          arguments: [true, false])
    func untouchedAndReplayed(toolsAvailable: Bool) {
        let untouched = ProviderEffectExecutor.untouchedRecords(toolsAvailable: toolsAvailable)
        #expect(untouched.suffix(2).map(\.stage) == [.scopeDrift, .toolCallScheduling])
        let replayed = ProviderEffectExecutor.replayedRecords()
        #expect(replayed.suffix(2).map(\.stage) == [.scopeDrift, .toolCallScheduling])
    }
}
