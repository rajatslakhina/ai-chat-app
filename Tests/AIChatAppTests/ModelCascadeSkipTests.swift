import Testing
@testable import AIChatApp

@Suite("ModelCascadeSkip")
struct ModelCascadeSkipTests {
    @Test("the stage belongs to ModelCascadeKit")
    func catalog() {
        #expect(PipelineStage.modelCascade.package == "ModelCascadeKit")
        #expect(PipelineStage.modelCascade.title == "Model cascade")
    }

    @Test("the skip explains itself")
    func outcomeIsAnExplainedSkip() {
        #expect(ModelCascadeSkip.outcome == .skipped(reason: ModelCascadeSkip.reason))
        #expect(ModelCascadeSkip.reason.contains("one model on the wire"))
    }

    @Test("without a confidence signal the linked package escalates, so a cascade here would always climb")
    func missingSignalEscalates() {
        #expect(ModelCascadeSkip.escalatesWithoutConfidence())
    }
}
