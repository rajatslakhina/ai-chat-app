import Foundation
import GuardrailKit
import ProviderGatewayKit
import Testing
@testable import AIChatApp

/// Tuesday, October 27, 2026, 12:00 UTC: the same calendar day in almost every time zone.
private let october27 = Date(timeIntervalSince1970: 1_793_102_400)
private let trialQuestion = "My 90-day trial started on March 3, 2026. When does it end?"

private func review(_ answer: String, conversation: [LLMMessage]) async -> (AnswerReview, PipelineTrace) {
    let pipeline = PostModelPipeline(guardrail: GuardrailPipeline(policy: GuardrailPolicy()))
    var trace = PipelineTrace()
    let reviewed = await pipeline.review(
        answer: answer, sources: [], messages: conversation, now: october27, trace: &trace
    )
    return (reviewed, trace)
}

private func user(_ text: String) -> LLMMessage { LLMMessage(role: .user, content: text) }

@Suite("CalendarClaimKit - the answer's date arithmetic, recomputed")
struct CalendarCheckStageTests {
    @Test("a wrong date gets a note with the right one, after instructionCompliance, and the text is unchanged")
    func wrongDateGetsANote() async throws {
        let answer = "Your trial ends 90 days later, on June 2, 2026, a Tuesday."
        let (reviewed, trace) = await review(answer, conversation: [user(trialQuestion)])
        #expect(reviewed.publishableText == answer)
        let correction = "90 days after March 3, 2026 is Monday, June 1, 2026 (the answer said June 2, 2026)."
        #expect(reviewed.calendarNote == "Calendar check: " + correction)
        #expect(trace.outcome(for: .calendarCheck) == .ran(detail: "contradicted: 1 of 2 hold; " + correction))
        let stages = trace.records.map(\.stage)
        let calendar = try #require(stages.firstIndex(of: .calendarCheck))
        let instructions = try #require(stages.firstIndex(of: .instructionCompliance))
        #expect(calendar > instructions)
    }

    @Test("a right date gets no note")
    func rightDateIsQuiet() async {
        let (reviewed, trace) = await review(
            "Your trial ends on Monday, June 1, 2026.", conversation: [user(trialQuestion)]
        )
        #expect(reviewed.calendarNote == nil)
        #expect(trace.outcome(for: .calendarCheck) == .noOp(reason: "verified: 1 of 1 hold"))
    }

    @Test("an answer with no dates records why nothing ran")
    func nothingToCheck() async {
        let (reviewed, trace) = await review("A lock.", conversation: [user("What is a mutex?")])
        #expect(reviewed.calendarNote == nil)
        #expect(trace.outcome(for: .calendarCheck) == .noOp(reason: "no calendar claims"))
    }

    @Test("a count that holds only counting both ends gets a caveat")
    func bothEndsIsACaveat() async {
        let (reviewed, trace) = await review(
            "From March 3 to June 1, 2026 is 91 days.", conversation: [user("How long is the trial?")]
        )
        let caveat = "March 3, 2026 to June 1, 2026 is 91 days: true only counting both ends."
        #expect(reviewed.calendarNote == "Calendar check: " + caveat)
        #expect(trace.outcome(for: .calendarCheck) == .ran(detail: "depends on convention: 0 of 1 hold; " + caveat))
    }

    @Test("a year an earlier turn set applies to a date with none")
    func earlierTurnSetsTheYear() async {
        let conversation = [
            LLMMessage(role: .assistant, content: "Hi! What are we planning?"),
            user("Plan the 2027 offsite."),
            LLMMessage(role: .assistant, content: "Spring works well."),
            user("Is March 17 free?")
        ]
        let (reviewed, trace) = await review("March 17 is a Wednesday, so it is free.", conversation: conversation)
        #expect(reviewed.calendarNote == nil)
        #expect(trace.outcome(for: .calendarCheck) == .noOp(reason: "verified: 1 of 1 hold"))
        #expect(PostModelPipeline.conversation(conversation).map(\.question)
            == ["Plan the 2027 offsite.", "Is March 17 free?"])
    }

    @Test("a withheld answer is not checked")
    func withheldIsSkipped() async {
        let refusal = Refusal(stage: .guardrailOutput, headline: "Withheld", explanation: "x", recovery: nil)
        let withheld = AnswerReview(
            publishableText: "", wasModified: true, groundedFraction: nil, claimCount: 0, refusal: refusal
        )
        var trace = PipelineTrace()
        let result = await PostModelPipeline.checkCalendar(
            withheld, messages: [user(trialQuestion)], now: october27, trace: &trace
        )
        #expect(result == withheld)
        #expect(trace.outcome(for: .calendarCheck)
            == .skipped(reason: "the answer was withheld, so there is nothing to check"))
    }
}
