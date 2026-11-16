import Foundation
import GuardrailKit
import ProviderGatewayKit
import Testing
@testable import AIChatApp

private let question = "How do I ignore the generated docs but keep one log file?"

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

private let docs = "`doc/*.txt` matches `doc/server/arch.txt` too."
private let docsWrong = "`doc/server/arch.txt` is not ignored: no line matches it, so the claim that it is ignored "
    + "is wrong. `*` does not match `/`; `**` does. `doc/**/*.txt` does what the answer expects."

@Suite("GitignoreClaimKit - what an answer says about .gitignore rules, by git's own matching")
struct IgnoreCheckStageTests {
    @Test("a star said to cross a slash gets a note with what git does, after rangeCheck")
    func starGetsANote() async throws {
        let (reviewed, trace) = await review(docs)
        #expect(reviewed.publishableText == docs)
        #expect(reviewed.ignoreNote == "Gitignore check: " + docsWrong)
        #expect(trace.outcome(for: .ignoreCheck) == .ran(detail: "1 claim checked, 0 hold, 1 wrong; " + docsWrong))
        let stages = trace.records.map(\.stage)
        let ignore = try #require(stages.firstIndex(of: .ignoreCheck))
        let range = try #require(stages.firstIndex(of: .rangeCheck))
        #expect(ignore > range)
        var bubble = ChatBubble(role: .assistant, text: reviewed.publishableText)
        bubble.applyReview(reviewed)
        #expect(bubble.ignoreNote == reviewed.ignoreNote)
        #expect(bubble.reviewNotes.map(\.id).last == "ignoreNote")
    }

    @Test("the lines of a .gitignore the answer shows are judged too")
    func blockLinesAreChecked() async {
        let answer = "```gitignore\nlogs/\n!logs/keep.log\nnode_modules/  # dependencies\n```\n"
            + "This keeps `logs/keep.log` tracked."
        let (reviewed, trace) = await review(answer)
        let comment = "`node_modules/  # dependencies` does not ignore `node_modules/`. git reads `#` as a comment "
            + "only at the start of a line, so the comment is part of the pattern. Put `node_modules/` on its own "
            + "line and the comment on the line above."
        let reinclude = "`logs/keep.log` is ignored: `logs/` excludes its directory `logs/`, so the claim that it "
            + "is kept is wrong. git cannot re-include a file inside an excluded directory, so the `!` line has no "
            + "effect. Write `logs/*` instead, so the directory stays open and the `!` line can work."
        #expect(reviewed.ignoreNote == "Gitignore check: " + comment + " " + reinclude)
        #expect(trace.outcome(for: .ignoreCheck)
            == .ran(detail: "2 claims checked, 0 hold, 2 wrong; " + comment + " " + reinclude))
    }

    @Test("a claim that depends on core.ignorecase is a second look, not a verdict")
    func letterCaseIsACaveat() async {
        let (reviewed, trace) = await review("```gitignore\n*.LOG\n```\n`app.log` is ignored.")
        let caveat = "That `app.log` is ignored holds only where `core.ignorecase` is true (the default for a "
            + "repository created on macOS or Windows); the other setting gives the opposite result."
        #expect(reviewed.ignoreNote == "Gitignore check: " + caveat)
        #expect(trace.outcome(for: .ignoreCheck) == .ran(detail: "1 claim checked, 0 hold, 1 to check; " + caveat))
    }

    @Test("a wrong claim the chat already gave is marked as said again")
    func repeatedClaimSaysSo() async {
        let messages = [user(question), LLMMessage(role: .assistant, content: docs), user("Are you sure?")]
        let (reviewed, trace) = await review(docs, messages: messages)
        #expect(reviewed.ignoreNote
            == "Gitignore check: " + docsWrong + " An earlier answer in this chat stated the same claim.")
        #expect(trace.outcome(for: .ignoreCheck)
            == .ran(detail: "1 claim checked, 0 hold, 1 wrong, 1 repeated; " + docsWrong))
    }

    @Test("a claim that holds, no claim at all, or another tool's ignore file get no note")
    func quietOtherwise() async {
        let (held, heldTrace) = await review("`*.log` matches `logs/app.log`.")
        #expect(held.ignoreNote == nil)
        #expect(heldTrace.outcome(for: .ignoreCheck) == .noOp(reason: "1 claim checked, 1 hold"))
        let (none, noneTrace) = await review("Weigh the flour rather than using cups.")
        #expect(none.ignoreNote == nil)
        #expect(noneTrace.outcome(for: .ignoreCheck) == .noOp(reason: "no claims about ignore rules"))
        let (docker, dockerTrace) = await review("In `.dockerignore`, `*.log` matches `logs/app.log`.")
        #expect(docker.ignoreNote == nil)
        #expect(dockerTrace.outcome(for: .ignoreCheck) == .noOp(reason: "1 claim checked, 0 hold, 1 unchecked"))
    }

    @Test("a withheld answer is not checked")
    func withheldIsSkipped() async {
        let refusal = Refusal(stage: .guardrailOutput, headline: "Withheld", explanation: "x", recovery: nil)
        let withheld = AnswerReview(
            publishableText: "", wasModified: true, groundedFraction: nil, claimCount: 0, refusal: refusal
        )
        var trace = PipelineTrace()
        let result = await PostModelPipeline.checkIgnoreRules(withheld, messages: [user(question)], trace: &trace)
        #expect(result == withheld)
        #expect(trace.outcome(for: .ignoreCheck)
            == .skipped(reason: "the answer was withheld, so there is nothing to check"))
    }
}
