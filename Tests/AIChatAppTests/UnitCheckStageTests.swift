import Foundation
import GuardrailKit
import ProviderGatewayKit
import Testing
@testable import AIChatApp

private let question = "My recipe says 2 cups of flour and 350°F. What is that in grams and Celsius?"

private func user(_ text: String) -> LLMMessage {
    LLMMessage(role: .user, content: text)
}

private func review(
    _ answer: String,
    messages: [LLMMessage] = [user(question)]
) async -> (AnswerReview, PipelineTrace) {
    let pipeline = PostModelPipeline(guardrail: GuardrailPipeline(policy: GuardrailPolicy()))
    var trace = PipelineTrace()
    let reviewed = await pipeline.review(answer: answer, sources: [], messages: messages, trace: &trace)
    return (reviewed, trace)
}

@Suite("UnitClaimKit - unit conversions an answer makes on its own")
struct UnitCheckStageTests {
    @Test("a wrong conversion gets a note with the exact value, after arithmeticCheck, and the text is unchanged")
    func wrongConversionGetsANote() async throws {
        let answer = "Use 2 cups of flour (500 g) and bake at 350°F (175°C)."
        let (reviewed, trace) = await review(answer)
        let correction = "2 cups of flour is 237 to 284 g, not 500 g. 500 g weighs 2 cups of flour as if it were water."
        #expect(reviewed.publishableText == answer)
        #expect(reviewed.unitNote == "Unit check: " + correction)
        #expect(trace.outcome(for: .unitCheck)
            == .ran(detail: "2 conversions checked, 1 hold, 1 wrong; " + correction))
        let stages = trace.records.map(\.stage)
        let units = try #require(stages.firstIndex(of: .unitCheck))
        let arithmetic = try #require(stages.firstIndex(of: .arithmeticCheck))
        #expect(units > arithmetic)
        var bubble = ChatBubble(role: .assistant, text: reviewed.publishableText)
        bubble.applyReview(reviewed)
        #expect(bubble.unitNote == reviewed.unitNote)
    }

    @Test("another convention and misrounding are notes too")
    func cautionsGetANote() async {
        let (reviewed, trace) = await review("Add 1 cup of milk (250 ml). The shelf is 6 ft = 1.82 m high.")
        let corrections = "1 cup is 237 ml with the US cup; 250 ml holds only with the metric cup (250 mL). "
            + "6 ft is 1.8288 m, which rounds to 1.83 m, not 1.82 m."
        #expect(reviewed.unitNote == "Unit check: " + corrections)
        #expect(trace.outcome(for: .unitCheck)
            == .ran(detail: "2 conversions checked, 0 hold, 2 to check; " + corrections))
    }

    @Test("a wrong conversion the chat already stated is marked as said again")
    func repeatedConversionSaysSo() async {
        let messages = [
            user("Tomorrow is 10°C warmer. How much is that in Fahrenheit?"),
            LLMMessage(role: .assistant, content: "It will be 10°C (50°F) warmer."),
            user("Are you sure?")
        ]
        let (reviewed, trace) = await review("Yes: it will be 10°C (50°F) warmer.", messages: messages)
        let correction = "As a change, 10°C is 18°F, not 50°F. 50°F converts it as a reading, "
            + "adding the offset between the scales."
        #expect(reviewed.unitNote
            == "Unit check: " + correction + " An earlier answer in this chat stated the same conversion.")
        #expect(trace.outcome(for: .unitCheck)
            == .ran(detail: "1 conversion checked, 0 hold, 1 wrong, 1 repeated; " + correction))
    }

    @Test("conversions that hold, none, or one with no known density get no note")
    func quietWhenItHolds() async {
        let (held, heldTrace) = await review("Use 2 cups of flour (250 g) and bake at 350°F (175°C).")
        #expect(held.unitNote == nil)
        #expect(heldTrace.outcome(for: .unitCheck) == .noOp(reason: "2 conversions checked, 2 hold"))
        let (none, noneTrace) = await review("Weigh the flour rather than using cups.")
        #expect(none.unitNote == nil)
        #expect(noneTrace.outcome(for: .unitCheck) == .noOp(reason: "no conversions stated"))
        let (unknown, unknownTrace) = await review("Add 2 cups of stock (480 g).")
        #expect(unknown.unitNote == nil)
        #expect(unknownTrace.outcome(for: .unitCheck)
            == .noOp(reason: "1 conversion checked, 0 hold, 1 unchecked"))
    }

    @Test("a withheld answer is not checked")
    func withheldIsSkipped() async {
        let refusal = Refusal(stage: .guardrailOutput, headline: "Withheld", explanation: "x", recovery: nil)
        let withheld = AnswerReview(
            publishableText: "", wasModified: true, groundedFraction: nil, claimCount: 0, refusal: refusal
        )
        var trace = PipelineTrace()
        let result = await PostModelPipeline.checkUnits(withheld, messages: [user(question)], trace: &trace)
        #expect(result == withheld)
        #expect(trace.outcome(for: .unitCheck)
            == .skipped(reason: "the answer was withheld, so there is nothing to check"))
    }
}
