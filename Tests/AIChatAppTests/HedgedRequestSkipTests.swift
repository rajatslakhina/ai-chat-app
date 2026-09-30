import Testing
@testable import AIChatApp

@Suite("HedgedRequestSkip")
struct HedgedRequestSkipTests {
    @Test("the stage belongs to HedgedRequestKit")
    func catalog() {
        #expect(PipelineStage.hedgedRequest.package == "HedgedRequestKit")
        #expect(PipelineStage.hedgedRequest.title == "Hedged request")
    }

    @Test("the skip explains itself")
    func outcomeIsAnExplainedSkip() {
        #expect(HedgedRequestSkip.outcome == .skipped(reason: HedgedRequestSkip.reason))
        #expect(HedgedRequestSkip.reason.contains("backup"))
    }
}
