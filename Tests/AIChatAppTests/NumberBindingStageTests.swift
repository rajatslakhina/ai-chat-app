import GuardrailKit
import NumberBindingKit
import ProviderGatewayKit
import Testing
import ToolRegistryKit
@testable import AIChatApp

private let calculator = ToolOutput(tool: "calculator", text: #"{"expression":"2340*0.15","result":351}"#)
private let question = LLMMessage(role: .user, content: "What is 15% of 2,340?")

private func review(
    _ answer: String,
    messages: [LLMMessage] = [question],
    toolOutputs: [ToolOutput] = [calculator]
) async -> (AnswerReview, PipelineTrace) {
    let pipeline = PostModelPipeline(guardrail: GuardrailPipeline(policy: GuardrailPolicy()))
    var trace = PipelineTrace()
    let reviewed = await pipeline.review(
        answer: answer, sources: [], messages: messages, toolOutputs: toolOutputs, trace: &trace
    )
    return (reviewed, trace)
}

private func plain(_ text: String) -> AnswerReview {
    AnswerReview(publishableText: text, wasModified: false, groundedFraction: nil, claimCount: 0, refusal: nil)
}

@Suite("NumberBindingKit - every number in the answer bound to what the turn returned")
struct NumberBindingStageTests {
    @Test("an answer whose figures all come from the calculator and the question gets no note")
    func boundAnswerIsQuiet() async throws {
        let (reviewed, trace) = await review("15% of 2,340 is 351.")
        #expect(reviewed.numberNote == nil)
        #expect(trace.outcome(for: .numberBinding) == .noOp(reason: "allBound: checked 3, bound 3 [exact 3]"))
        let stages = trace.records.map(\.stage)
        let numbers = try #require(stages.firstIndex(of: .numberBinding))
        let stance = try #require(stages.firstIndex(of: .stanceGuard))
        #expect(numbers > stance)
    }

    @Test("a calculator result restated wrong is contradicted, under the bubble and not in the text")
    func restatedWrongGetsANote() async {
        let answer = "The result is 315."
        let (reviewed, trace) = await review(answer)
        #expect(reviewed.publishableText == answer)
        #expect(reviewed.numberNote == "Checked 1 number against what this turn returned. Doesn't match: 315 "
            + "(calculator says 351). Treat those figures as unchecked, or ask for them to be read back from "
            + "the tool or the source.")
        #expect(trace.outcome(for: .numberBinding) == .ran(detail: "contradicted: checked 1, bound 0; contradicted 315 vs 351"))
    }

    @Test("a figure that only repeats an earlier answer is echoed, not verified")
    func earlierAnswerIsNotEvidence() async {
        let earlier = LLMMessage(role: .assistant, content: "The standard card fee is 2.9%.")
        let (reviewed, trace) = await review(
            "At 2.9%, 351 dollars of fees.", messages: [question, earlier, question]
        )
        #expect(reviewed.numberNote?.contains("Only repeats an earlier answer: 2.9%.") == true)
        #expect(trace.outcome(for: .numberBinding) == .ran(
            detail: "unverified: checked 2, bound 1 [exact 1]; echoed 2.9%"
        ))
    }

    @Test("with no tool result and no retrieved source the stage skips, and says why")
    func noEvidenceSkips() async {
        let (reviewed, trace) = await review("Apollo 11 landed in 1969.", toolOutputs: [])
        #expect(reviewed.numberNote == nil)
        #expect(trace.outcome(for: .numberBinding)
            == .skipped(reason: "no tool result or retrieved source this turn, so nothing to bind to"))
    }

    @Test("a withheld answer is skipped; retrieved passages count as evidence")
    func refusalAndSources() {
        var trace = PipelineTrace()
        let refusal = Refusal(stage: .guardrailOutput, headline: "Withheld", explanation: "x", recovery: nil)
        let withheld = AnswerReview(publishableText: "", wasModified: true, groundedFraction: nil, claimCount: 0,
                                    refusal: refusal)
        let evidence = NumberEvidence(toolOutputs: [calculator], sources: [], messages: [])
        #expect(PostModelPipeline.bindNumbers(withheld, evidence: evidence, trace: &trace) == withheld)
        #expect(trace.outcome(for: .numberBinding)
            == .skipped(reason: "the answer was withheld, so there are no numbers"))
        let report = RetrievedSource(id: "q3", title: "Q3 report", snippet: "Q3 revenue was $1,234,567.",
                                     relevancePercent: 90)
        var sourced = PipelineTrace()
        let reviewed = PostModelPipeline.bindNumbers(
            plain("Revenue came in at $1.2 million."),
            evidence: NumberEvidence(toolOutputs: [], sources: [report], messages: []),
            trace: &sourced
        )
        #expect(reviewed.numberNote == nil)
        #expect(sourced.outcome(for: .numberBinding) == .noOp(reason: "allBound: checked 1, bound 1 [rounded 1]"))
    }

    @Test("evidence maps tools, passages and every user message; earlier answers only echo")
    func evidenceMapping() {
        let passage = RetrievedSource(id: "p1", title: "Doc", snippet: "7 days", relevancePercent: 50)
        let messages = [
            LLMMessage(role: .system, content: "Today is 2026-10-23."),
            question,
            LLMMessage(role: .assistant, content: "351."),
            LLMMessage(role: .user, content: "And 20%?")
        ]
        let sources = NumberEvidence(toolOutputs: [calculator], sources: [passage], messages: messages).numberSources
        #expect(sources.map(\.kind) == [.tool, .document, .user, .user, .assistant])
        #expect(sources.map(\.id) == ["tool:calculator", "p1", "user:0", "user:1", "answer:1"])
        #expect(sources[2].label == "your message")
    }

    @Test("a tool result becomes sorted JSON text; a failed call is not evidence")
    func toolOutputFromResult() {
        let result = ToolCallResult(id: "c1", toolName: "calculator",
                                    outcome: .success(.object(["result": .number(84), "expression": .string("6*14")])))
        #expect(ToolOutput(result) == ToolOutput(tool: "calculator", text: #"{"expression":"6*14","result":84}"#))
        let failed = ToolCallResult(id: "c2", toolName: "calculator", outcome: .failure(.unknownTool("nope")))
        #expect(ToolOutput(failed) == nil)
    }
}
