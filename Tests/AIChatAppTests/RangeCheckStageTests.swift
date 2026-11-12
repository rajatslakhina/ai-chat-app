import Foundation
import GuardrailKit
import ProviderGatewayKit
import Testing
@testable import AIChatApp

private let question = "How do I add tiny-parser 0.2.3 so we get its updates?"

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

private let caret = "With npm, `^0.2.3` allows 0.3.0."
private let caretWrong = "`^0.2.3` does not allow 0.3.0: in npm it means >=0.2.3 <0.3.0 (on 0.x a caret lets only "
    + "the patch number move, and ^0.0.x allows one release)."

@Suite("VersionRangeClaimKit - what an answer says about version ranges, by the package manager's rules")
struct RangeCheckStageTests {
    @Test("a misread caret on 0.x gets a note with what the range means, after sqlCheck")
    func caretOnZeroGetsANote() async throws {
        let (reviewed, trace) = await review(caret)
        #expect(reviewed.publishableText == caret)
        #expect(reviewed.rangeNote == "Version range check: " + caretWrong)
        #expect(trace.outcome(for: .rangeCheck) == .ran(detail: "1 claim checked, 0 hold, 1 wrong; " + caretWrong))
        let stages = trace.records.map(\.stage)
        let range = try #require(stages.firstIndex(of: .rangeCheck))
        let sql = try #require(stages.firstIndex(of: .sqlCheck))
        #expect(range > sql)
        var bubble = ChatBubble(role: .assistant, text: reviewed.publishableText)
        bubble.applyReview(reviewed)
        #expect(bubble.rangeNote == reviewed.rangeNote)
        #expect(bubble.reviewNotes.map(\.id).last == "rangeNote")
    }

    @Test("a caret in requirements.txt is refused by pip, and the note gives a rewrite")
    func manifestLineIsChecked() async {
        let answer = "Pin it in requirements.txt:\n```text\nrequests^2.31\nflask>=3.0\n```"
        let (reviewed, trace) = await review(answer)
        let invalid = "`requests^2.31` is not a valid pip requirement: pip has no ^ operator (that is npm or Poetry "
            + "syntax); write >=2.31,<3."
        #expect(reviewed.rangeNote == "Version range check: " + invalid)
        #expect(trace.outcome(for: .rangeCheck) == .ran(detail: "1 claim checked, 0 hold, 1 wrong; " + invalid))
    }

    @Test("a pre-release pip would skip without --pre is a second look, not a verdict")
    func preReleaseIsACaveat() async {
        let (reviewed, trace) = await review("In pip, `>=1.0` allows 2.0b1.")
        let caveat = "`>=1.0` admits 2.0b1, but pip installs a pre-release only with --pre or when no final release "
            + "matches."
        #expect(reviewed.rangeNote == "Version range check: " + caveat)
        #expect(trace.outcome(for: .rangeCheck) == .ran(detail: "1 claim checked, 0 hold, 1 to check; " + caveat))
    }

    @Test("a wrong claim the chat already gave is marked as said again")
    func repeatedClaimSaysSo() async {
        let messages = [user(question), LLMMessage(role: .assistant, content: caret), user("Are you sure?")]
        let (reviewed, trace) = await review(caret, messages: messages)
        #expect(reviewed.rangeNote
            == "Version range check: " + caretWrong + " An earlier answer in this chat stated the same claim.")
        #expect(trace.outcome(for: .rangeCheck)
            == .ran(detail: "1 claim checked, 0 hold, 1 wrong, 1 repeated; " + caretWrong))
    }

    @Test("a claim that holds, no range at all, or a range no package manager is named for get no note")
    func quietOtherwise() async {
        let (held, heldTrace) = await review("With npm, `^1.2.3` allows 1.9.0.")
        #expect(held.rangeNote == nil)
        #expect(heldTrace.outcome(for: .rangeCheck) == .noOp(reason: "1 claim checked, 1 hold"))
        let (none, noneTrace) = await review("Weigh the flour rather than using cups.")
        #expect(none.rangeNote == nil)
        #expect(noneTrace.outcome(for: .rangeCheck) == .noOp(reason: "no claims about version ranges"))
        let (unnamed, unnamedTrace) = await review("`~1.2` allows 1.5.0.")
        #expect(unnamed.rangeNote == nil)
        #expect(unnamedTrace.outcome(for: .rangeCheck) == .noOp(reason: "1 claim checked, 0 hold, 1 unchecked"))
    }

    @Test("a withheld answer is not checked")
    func withheldIsSkipped() async {
        let refusal = Refusal(stage: .guardrailOutput, headline: "Withheld", explanation: "x", recovery: nil)
        let withheld = AnswerReview(
            publishableText: "", wasModified: true, groundedFraction: nil, claimCount: 0, refusal: refusal
        )
        var trace = PipelineTrace()
        let result = await PostModelPipeline.checkRanges(withheld, messages: [user(question)], trace: &trace)
        #expect(result == withheld)
        #expect(trace.outcome(for: .rangeCheck)
            == .skipped(reason: "the answer was withheld, so there is nothing to check"))
    }
}
