import Foundation
import GuardrailKit
import ProviderGatewayKit
import Testing
@testable import AIChatApp

private let question = "Our plan costs $480 a year. With a 15% discount, what do we pay per month?"

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

@Suite("ArithmeticClaimKit - arithmetic an answer works out on its own")
struct ArithmeticCheckStageTests {
    @Test("a wrong result gets a note with the exact value, after packageCheck, and the text is unchanged")
    func wrongResultGetsANote() async throws {
        let answer = "15% of $480 is $62, so the year costs $480 - $62 = $418, "
            + "which is $418 / 12 = $34.83 a month."
        let (reviewed, trace) = await review(answer)
        #expect(reviewed.publishableText == answer)
        #expect(reviewed.arithmeticNote == "Arithmetic check: 15% of $480 is $72, not $62.")
        #expect(trace.outcome(for: .arithmeticCheck)
            == .ran(detail: "3 results checked, 2 hold, 1 wrong; 15% of $480 is $72, not $62."))
        let stages = trace.records.map(\.stage)
        let arithmetic = try #require(stages.firstIndex(of: .arithmeticCheck))
        let packages = try #require(stages.firstIndex(of: .packageCheck))
        #expect(arithmetic > packages)
        var bubble = ChatBubble(role: .assistant, text: reviewed.publishableText)
        bubble.applyReview(reviewed)
        #expect(bubble.arithmeticNote == reviewed.arithmeticNote)
    }

    @Test("misrounding and percentage points written as a percent are notes too")
    func cautionsGetANote() async {
        let answer = "Split three ways, $100 / 3 = $33.34. Churn fell from 5% to 4%, a 1% decrease."
        let (reviewed, trace) = await review(answer)
        let corrections = "$100 / 3 is about $33.3333, which rounds to $33.33, not $33.34. from 5% to 4% is "
            + "1 percentage point but a 20% decrease; \"a 1% decrease\" reads the points as a percent."
        #expect(reviewed.arithmeticNote == "Arithmetic check: " + corrections)
        #expect(trace.outcome(for: .arithmeticCheck)
            == .ran(detail: "2 results checked, 0 hold, 2 to check; " + corrections))
    }

    @Test("a wrong result the chat already stated is marked as said again")
    func repeatedResultSaysSo() async {
        let earlier = "From $480 to $540 is a 15% increase."
        let messages = [
            user("How big a rise is $480 to $540?"),
            LLMMessage(role: .assistant, content: earlier),
            user("Are you sure?")
        ]
        let (reviewed, trace) = await review("Yes: from $480 to $540 is a 15% increase.", messages: messages)
        #expect(reviewed.arithmeticNote == "Arithmetic check: from $480 to $540 is a 12.5% increase, not a 15% "
            + "increase. An earlier answer in this chat stated the same result.")
        #expect(trace.outcome(for: .arithmeticCheck)
            == .ran(detail: "1 result checked, 0 hold, 1 wrong, 1 repeated; "
                + "from $480 to $540 is a 12.5% increase, not a 15% increase."))
    }

    @Test("arithmetic that holds, or none at all, gets no note")
    func quietWhenItHolds() async {
        let (held, heldTrace) = await review("15% of $480 is $72, so $480 - $72 = $408, or $408 / 12 = $34.")
        #expect(held.arithmeticNote == nil)
        #expect(heldTrace.outcome(for: .arithmeticCheck) == .noOp(reason: "3 results checked, 3 hold"))
        let (none, noneTrace) = await review("Ask your account manager about annual discounts.")
        #expect(none.arithmeticNote == nil)
        #expect(noneTrace.outcome(for: .arithmeticCheck) == .noOp(reason: "no arithmetic stated"))
    }

    @Test("a withheld answer is not checked")
    func withheldIsSkipped() async {
        let refusal = Refusal(stage: .guardrailOutput, headline: "Withheld", explanation: "x", recovery: nil)
        let withheld = AnswerReview(
            publishableText: "", wasModified: true, groundedFraction: nil, claimCount: 0, refusal: refusal
        )
        var trace = PipelineTrace()
        let result = await PostModelPipeline.checkArithmetic(withheld, messages: [user(question)], trace: &trace)
        #expect(result == withheld)
        #expect(trace.outcome(for: .arithmeticCheck)
            == .skipped(reason: "the answer was withheld, so there is nothing to check"))
    }
}
