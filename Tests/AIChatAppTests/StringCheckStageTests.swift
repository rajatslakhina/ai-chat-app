import Foundation
import GuardrailKit
import ProviderGatewayKit
import Testing
@testable import AIChatApp

private let question = "How many r's are in strawberry?"

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

private let doubled = "\"r\" occurs 3 times in \"strawberry\", not 2: the doubled \"rr\" was counted once."

@Suite("StringClaimKit - what an answer says about strings, run")
struct StringCheckStageTests {
    @Test("a wrong letter count gets a note naming the slip, after regexCheck, and the text is unchanged")
    func wrongCountGetsANote() async throws {
        let answer = "There are 2 r's in \"strawberry\"."
        let (reviewed, trace) = await review(answer)
        #expect(reviewed.publishableText == answer)
        #expect(reviewed.stringNote == "String check: " + doubled)
        #expect(trace.outcome(for: .stringCheck) == .ran(detail: "1 claim checked, 0 hold, 1 wrong; " + doubled))
        let stages = trace.records.map(\.stage)
        let strings = try #require(stages.firstIndex(of: .stringCheck))
        let regexes = try #require(stages.firstIndex(of: .regexCheck))
        #expect(strings > regexes)
        var bubble = ChatBubble(role: .assistant, text: reviewed.publishableText)
        bubble.applyReview(reviewed)
        #expect(bubble.stringNote == reviewed.stringNote)
        #expect(bubble.reviewNotes.map(\.id).last == "stringNote")
    }

    @Test("code results are checked by the language's own rules, and echo's newline is named")
    func codeAndShellAreRun() async {
        let python = "```python\n>>> len(\"café\")\n5\n```"
        let (counted, _) = await review(python)
        #expect(counted.stringNote == "String check: `len(\"café\")` gives 4 in Python, not 5: 5 counts UTF-8 bytes.")
        let shell = "```bash\n$ echo hello | base64\naGVsbG8=\n```"
        let (encoded, trace) = await review(shell)
        let correction = "`echo hello | base64` prints \"aGVsbG8K\", not \"aGVsbG8=\": that leaves out the newline "
            + "`echo` adds (`echo -n` or `printf` sends none)."
        #expect(encoded.stringNote == "String check: " + correction)
        #expect(trace.outcome(for: .stringCheck) == .ran(detail: "1 claim checked, 0 hold, 1 wrong; " + correction))
    }

    @Test("a value that holds only under another reading is noted, not called wrong")
    func otherReadingIsNoted() async {
        let (reviewed, _) = await review("\"hello world\" has 10 characters.")
        #expect(reviewed.stringNote
            == "String check: \"hello world\" has 11 characters (10 holds only if spaces are not counted).")
    }

    @Test("a wrong claim the chat already stated is marked as said again")
    func repeatedClaimSaysSo() async {
        let messages = [
            user(question),
            LLMMessage(role: .assistant, content: "There are 2 r's in \"strawberry\"."),
            user("Are you sure?")
        ]
        let (reviewed, trace) = await review("Yes, there are 2 r's in \"strawberry\".", messages: messages)
        #expect(reviewed.stringNote
            == "String check: " + doubled + " An earlier answer in this chat stated the same claim.")
        #expect(trace.outcome(for: .stringCheck)
            == .ran(detail: "1 claim checked, 0 hold, 1 wrong, 1 repeated; " + doubled))
    }

    @Test("claims that hold, no claims, or a claim that cannot be run get no note")
    func quietWhenItHolds() async {
        let (held, heldTrace) = await review("\"strawberry\" has 3 r's and 10 letters.")
        #expect(held.stringNote == nil)
        #expect(heldTrace.outcome(for: .stringCheck) == .noOp(reason: "1 claim checked, 1 hold"))
        let (none, noneTrace) = await review("Weigh the flour rather than using cups.")
        #expect(none.stringNote == nil)
        #expect(noneTrace.outcome(for: .stringCheck) == .noOp(reason: "no claims about strings"))
        let (gap, gapTrace) = await review("\"👍🏽\" is U+1F44D.")
        #expect(gap.stringNote == nil)
        #expect(gapTrace.outcome(for: .stringCheck) == .noOp(reason: "1 claim checked, 0 hold, 1 unchecked"))
    }

    @Test("a withheld answer is not checked")
    func withheldIsSkipped() async {
        let refusal = Refusal(stage: .guardrailOutput, headline: "Withheld", explanation: "x", recovery: nil)
        let withheld = AnswerReview(
            publishableText: "", wasModified: true, groundedFraction: nil, claimCount: 0, refusal: refusal
        )
        var trace = PipelineTrace()
        let result = await PostModelPipeline.checkStrings(withheld, messages: [user(question)], trace: &trace)
        #expect(result == withheld)
        #expect(trace.outcome(for: .stringCheck)
            == .skipped(reason: "the answer was withheld, so there is nothing to check"))
    }

    @Test("the string note comes last among the notes, after the regex note")
    func reviewNotesKeepTheirOrder() {
        var bubble = ChatBubble(role: .assistant, text: "x")
        bubble.stringNote = "t"
        bubble.regexNote = "r"
        #expect(bubble.reviewNotes == [ReviewNote(id: "regexNote", text: "r"), ReviewNote(id: "stringNote", text: "t")])
    }
}
