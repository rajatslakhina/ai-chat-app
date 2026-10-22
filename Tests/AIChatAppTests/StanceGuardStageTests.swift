import GuardrailKit
import ProviderGatewayKit
import StanceGuardKit
import Testing
@testable import AIChatApp

private let question = LLMMessage(role: .user, content: "When did Apollo 11 land on the Moon?")
private let firstAnswer = LLMMessage(role: .assistant, content: "Apollo 11 landed on the Moon in 1969.")
private let pushback = LLMMessage(role: .user, content: "Are you sure? My teacher said it was 1968.")
private let system = LLMMessage(role: .system, content: "You are a helpful assistant.")

private func review(_ answer: String, messages: [LLMMessage]) async -> (AnswerReview, PipelineTrace) {
    let pipeline = PostModelPipeline(guardrail: GuardrailPipeline(policy: GuardrailPolicy()))
    var trace = PipelineTrace()
    let reviewed = await pipeline.review(answer: answer, sources: [], messages: messages, trace: &trace)
    return (reviewed, trace)
}

@Suite("StanceGuardKit - an answer that gives way under pushback")
struct StanceGuardStageTests {
    @Test("a change after doubt and an unverifiable authority is flagged, under the bubble and not in the text")
    func capitulationGetsANote() async throws {
        let answer = "You're right, I apologize. It was 1968."
        let (reviewed, trace) = await review(answer, messages: [system, question, firstAnswer, pushback])
        #expect(reviewed.publishableText == answer)
        #expect(reviewed.stanceNote == "This answer changes the earlier one (1969 to 1968) after a message that gave "
            + "no new evidence. Ask again for a check on the merits if you want a second look.")
        #expect(trace.outcome(for: .stanceGuard) == .ran(
            detail: "capitulated: 1969 -> 1968; turn pressureOnly [doubt+authority+insistence]; tone yielding"
        ))
        let stages = trace.records.map(\.stage)
        let stance = try #require(stages.firstIndex(of: .stanceGuard))
        let guardrail = try #require(stages.firstIndex(of: .guardrailOutput))
        #expect(stance > guardrail)
    }

    @Test("an answer that holds, and one revised on a cited source, get no note")
    func heldAndRevisedAreQuiet() async {
        let (held, heldTrace) = await review("I understand the doubt, but the answer remains 1969.",
                                             messages: [question, firstAnswer, pushback])
        #expect(held.stanceNote == nil)
        #expect(heldTrace.outcome(for: .stanceGuard)
            == .noOp(reason: "held: 1969 -> 1969; turn pressureOnly [doubt+authority+insistence]; tone firm"))
        let cited = LLMMessage(role: .user, content: "No: Collins (2001), p. 214, gives 1968.")
        let (revised, revisedTrace) = await review("Thanks for the source. It was 1968.",
                                                   messages: [question, firstAnswer, cited])
        #expect(revised.stanceNote == nil)
        #expect(revisedTrace.outcome(for: .stanceGuard)?.summary.hasPrefix("revisedWithEvidence") == true)
    }

    @Test("the first answer in a conversation has nothing to hold")
    func firstTurn() async {
        let (reviewed, trace) = await review("Apollo 11 landed on the Moon in 1969.", messages: [system, question])
        #expect(reviewed.stanceNote == nil)
        #expect(trace.outcome(for: .stanceGuard) == .noOp(reason: "no earlier answer in this conversation to compare"))
    }

    @Test("a withheld answer is skipped, with the reason")
    func withheldAnswer() {
        let withheld = AnswerReview(publishableText: "", wasModified: true, groundedFraction: nil, claimCount: 0,
                                    refusal: Refusal(stage: .guardrailOutput, headline: "Withheld",
                                                     explanation: "x", recovery: nil))
        var trace = PipelineTrace()
        let result = PostModelPipeline.checkStance(withheld, messages: [question, firstAnswer, pushback], trace: &trace)
        #expect(result.stanceNote == nil)
        #expect(trace.outcome(for: .stanceGuard) == .skipped(reason: "the answer was withheld, so there is no position"))
    }

    @Test("the exchange is read from the turn's messages; a question asked twice is not an objection")
    func exchangeFromMessages() throws {
        let repeated = LLMMessage(role: .user, content: "When did Apollo 11 land on the Moon?")
        let doubt = LLMMessage(role: .user, content: "Are you sure about that?")
        let reply = LLMMessage(role: .assistant, content: "Yes.")
        let exchange = try #require(StanceExchange(messages: [system, question, reply, doubt, firstAnswer, repeated]))
        #expect(exchange.previousAnswer == firstAnswer.content)
        #expect(exchange.userTurn == repeated.content)
        #expect(exchange.earlier == [system.content, question.content, reply.content, doubt.content])
        #expect(exchange.earlierObjections == [doubt.content])
        #expect(StanceExchange(messages: [system, question]) == nil)
        #expect(StanceExchange(messages: [firstAnswer]) == nil)
        #expect(PipelineStage.stanceGuard.package == "StanceGuardKit")
        #expect(PipelineStage.stanceGuard.title == "Answer held under pushback")
    }
}
