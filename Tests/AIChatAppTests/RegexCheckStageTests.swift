import Foundation
import GuardrailKit
import ProviderGatewayKit
import Testing
@testable import AIChatApp

private let question = "Give me a regex for a 5-digit ZIP code, with examples."

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

private let unanchored = "`\\d{5}` matches `12345` inside `123456`, though the answer says it does not: "
    + "the pattern has no `^` and `$` anchors, so a match anywhere in the input counts."

@Suite("RegexClaimKit - what an answer says its regular expressions match")
struct RegexCheckStageTests {
    @Test("a claim that does not hold gets a note naming the slip, after unitCheck, and the text is unchanged")
    func wrongClaimGetsANote() async throws {
        let answer = "Use `\\d{5}` for a ZIP code. It matches `12345` but not `123456`."
        let (reviewed, trace) = await review(answer)
        #expect(reviewed.publishableText == answer)
        #expect(reviewed.regexNote == "Regex check: " + unanchored)
        #expect(trace.outcome(for: .regexCheck)
            == .ran(detail: "1 pattern, 2 claims run, 1 hold, 1 wrong; " + unanchored))
        let stages = trace.records.map(\.stage)
        let regexes = try #require(stages.firstIndex(of: .regexCheck))
        let units = try #require(stages.firstIndex(of: .unitCheck))
        #expect(regexes > units)
        var bubble = ChatBubble(role: .assistant, text: reviewed.publishableText)
        bubble.applyReview(reviewed)
        #expect(bubble.regexNote == reviewed.regexNote)
        #expect(bubble.reviewNotes.map(\.id).last == "regexNote")
    }

    @Test("a commented line of code is run, so a replace without g is caught")
    func codeLinesAreRun() async {
        let (reviewed, trace) = await review("```js\n\"a-b-c\".replace(/-/, \"+\") // \"a+b+c\"\n```")
        let correction = "`\"a-b-c\".replace(/-/, \"+\")` gives `\"a+b-c\"`, not `\"a+b+c\"`: without the `g` flag "
            + "only the first match counts, and `replaceAll()` throws."
        #expect(reviewed.regexNote == "Regex check: " + correction)
        #expect(trace.outcome(for: .regexCheck)
            == .ran(detail: "1 pattern, 1 claim run, 0 hold, 1 wrong; " + correction))
    }

    @Test("a wrong claim the chat already stated is marked as said again")
    func repeatedClaimSaysSo() async {
        let messages = [
            user(question),
            LLMMessage(role: .assistant, content: "Use `\\d{5}`. It matches `12345` but not `123456`."),
            user("Are you sure?")
        ]
        let (reviewed, trace) = await review("Yes: `\\d{5}` matches `12345` but not `123456`.", messages: messages)
        #expect(reviewed.regexNote
            == "Regex check: " + unanchored + " An earlier answer in this chat stated the same claim.")
        #expect(trace.outcome(for: .regexCheck)
            == .ran(detail: "1 pattern, 2 claims run, 1 hold, 1 wrong, 1 repeated; " + unanchored))
    }

    @Test("a pattern that can backtrack without end is a note even with no examples")
    func nestedRepetitionGetsANote() async {
        let (reviewed, _) = await review("Use `^(\\w+\\s?)+$` to validate a sentence.")
        #expect(reviewed.regexNote == "Regex check: `^(\\w+\\s?)+$` repeats a repetition, `(\\w+\\s?)+`; "
            + "input that almost matches can make it backtrack for a very long time.")
    }

    @Test("claims that hold, no regex, or a pattern this engine cannot run get no note")
    func quietWhenItHolds() async {
        let (held, heldTrace) = await review("Use `^\\d{5}$`. It matches `12345` but not `123456`.")
        #expect(held.regexNote == nil)
        #expect(heldTrace.outcome(for: .regexCheck) == .noOp(reason: "1 pattern, 2 claims run, 2 hold"))
        let (none, noneTrace) = await review("Weigh the flour rather than using cups.")
        #expect(none.regexNote == nil)
        #expect(noneTrace.outcome(for: .regexCheck) == .noOp(reason: "no regular expressions"))
        let (gap, gapTrace) = await review("```regex\na\\Kb\n```")
        #expect(gap.regexNote == nil)
        #expect(gapTrace.outcome(for: .regexCheck) == .noOp(reason: "1 pattern, 0 claims run, 0 hold, 1 unchecked"))
    }

    @Test("a withheld answer is not checked")
    func withheldIsSkipped() async {
        let refusal = Refusal(stage: .guardrailOutput, headline: "Withheld", explanation: "x", recovery: nil)
        let withheld = AnswerReview(
            publishableText: "", wasModified: true, groundedFraction: nil, claimCount: 0, refusal: refusal
        )
        var trace = PipelineTrace()
        let result = await PostModelPipeline.checkRegexes(withheld, messages: [user(question)], trace: &trace)
        #expect(result == withheld)
        #expect(trace.outcome(for: .regexCheck)
            == .skipped(reason: "the answer was withheld, so there is nothing to check"))
    }

    @Test("every note a stage leaves is listed once, in pipeline order")
    func reviewNotesKeepTheirOrder() {
        var bubble = ChatBubble(role: .assistant, text: "x")
        #expect(bubble.reviewNotes.isEmpty)
        bubble.unitNote = "u"
        bubble.stanceNote = "s"
        bubble.regexNote = "r"
        #expect(bubble.reviewNotes == [
            ReviewNote(id: "stanceNote", text: "s"), ReviewNote(id: "unitNote", text: "u"),
            ReviewNote(id: "regexNote", text: "r")
        ])
    }
}
