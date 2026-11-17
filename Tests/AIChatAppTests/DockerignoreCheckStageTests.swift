import Foundation
import GuardrailKit
import ProviderGatewayKit
import Testing
@testable import AIChatApp

private let question = "How should my .dockerignore keep node_modules and secrets out of the image?"

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

private let monorepo = "`node_modules` excludes `packages/api/node_modules/x.js`."
private let monorepoWrong = "`packages/api/node_modules/x.js` is sent: no line matches it, so the claim that it is "
    + "left out is wrong. Docker matches every pattern from the root of the build context; unlike .gitignore, a "
    + "pattern with no slash does not match in subdirectories. `**/node_modules` does what the answer expects."

@Suite("DockerignoreClaimKit - what an answer says about .dockerignore rules, by Docker's own matching")
struct DockerignoreCheckStageTests {
    @Test("a pattern said to match in every package gets a note with what Docker does, after ignoreCheck")
    func rootRelativeGetsANote() async throws {
        let (reviewed, trace) = await review(monorepo)
        #expect(reviewed.publishableText == monorepo)
        #expect(reviewed.dockerignoreNote == "Dockerignore check: " + monorepoWrong)
        #expect(trace.outcome(for: .dockerignoreCheck)
            == .ran(detail: "1 claim checked, 0 hold, 1 wrong; " + monorepoWrong))
        let stages = trace.records.map(\.stage)
        let docker = try #require(stages.firstIndex(of: .dockerignoreCheck))
        let ignore = try #require(stages.firstIndex(of: .ignoreCheck))
        #expect(docker > ignore)
        var bubble = ChatBubble(role: .assistant, text: reviewed.publishableText)
        bubble.applyReview(reviewed)
        #expect(bubble.dockerignoreNote == reviewed.dockerignoreNote)
        #expect(bubble.reviewNotes.map(\.id).last == "dockerignoreNote")
    }

    @Test("the lines of a .dockerignore the answer shows are judged too")
    func blockLinesAreChecked() async {
        let answer = "```dockerignore\nnode_modules\n.env   # secrets\n```\n"
            + "This keeps `packages/web/node_modules/a.js` out of the image."
        let (reviewed, trace) = await review(answer)
        let comment = "`.env   # secrets` does not exclude `.env`. Docker reads `#` as a comment only at the start of a "
            + "line, so the comment is part of the pattern. Put `.env` on its own line and the comment on the line above."
        let web = "`packages/web/node_modules/a.js` is sent: no line matches it, so the claim that it is left out is "
            + "wrong. Docker matches every pattern from the root of the build context; unlike .gitignore, a pattern "
            + "with no slash does not match in subdirectories. `**/node_modules` does what the answer expects."
        #expect(reviewed.dockerignoreNote == "Dockerignore check: " + comment + " " + web)
        #expect(trace.outcome(for: .dockerignoreCheck)
            == .ran(detail: "2 claims checked, 0 hold, 2 wrong; " + comment + " " + web))
    }

    @Test("a claim that holds under one builder only is a second look, not a verdict")
    func builderIsACaveat() async {
        let answer = "```dockerignore\nnode_modules\n!**/keep.txt\n```\n`node_modules/pkg/keep.txt` is sent."
        let (reviewed, trace) = await review(answer)
        let caveat = "That `node_modules/pkg/keep.txt` is sent with the build context holds only with BuildKit; the "
            + "classic builder skips the excluded directory above it and gives the opposite result."
        #expect(reviewed.dockerignoreNote == "Dockerignore check: " + caveat)
        #expect(trace.outcome(for: .dockerignoreCheck)
            == .ran(detail: "1 claim checked, 0 hold, 1 to check; " + caveat))
    }

    @Test("a wrong claim the chat already gave is marked as said again")
    func repeatedClaimSaysSo() async {
        let messages = [user(question), LLMMessage(role: .assistant, content: monorepo), user("Are you sure?")]
        let (reviewed, trace) = await review(monorepo, messages: messages)
        #expect(reviewed.dockerignoreNote
            == "Dockerignore check: " + monorepoWrong + " An earlier answer in this chat stated the same claim.")
        #expect(trace.outcome(for: .dockerignoreCheck)
            == .ran(detail: "1 claim checked, 0 hold, 1 wrong, 1 repeated; " + monorepoWrong))
    }

    @Test("a claim that holds, no claim, or a .gitignore claim get no note; ignoreCheck's unchecked case is checked")
    func quietOtherwise() async {
        let (held, heldTrace) = await review("In `.dockerignore`, `**/*.log` matches `logs/app.log`.")
        #expect(held.dockerignoreNote == nil)
        #expect(heldTrace.outcome(for: .dockerignoreCheck) == .noOp(reason: "1 claim checked, 1 hold"))
        let (none, noneTrace) = await review("Weigh the flour rather than using cups.")
        #expect(none.dockerignoreNote == nil)
        #expect(noneTrace.outcome(for: .dockerignoreCheck) == .noOp(reason: "no claims about .dockerignore rules"))
        let (git, gitTrace) = await review("In `.gitignore`, `*.log` matches `logs/app.log`.")
        #expect(git.dockerignoreNote == nil)
        #expect(gitTrace.outcome(for: .dockerignoreCheck) == .noOp(reason: "no claims about .dockerignore rules"))
        let (docker, dockerTrace) = await review("In `.dockerignore`, `*.log` matches `logs/app.log`.")
        #expect(dockerTrace.outcome(for: .ignoreCheck) == .noOp(reason: "1 claim checked, 0 hold, 1 unchecked"))
        #expect(docker.dockerignoreNote?.hasPrefix("Dockerignore check: `logs/app.log` is sent: no line matches it")
            == true)
    }

    @Test("a sentence about a regex is not a .dockerignore claim, even later in a chat that named one")
    func otherDomainsStayQuiet() async {
        let messages = [user("What does `[a-z]+` match, and what does compactMap do?")]
        let answer = "`[a-z]+` matches `abc`, and `compactMap` ignores `nil` values."
        let (reviewed, trace) = await review(answer, messages: messages)
        #expect(reviewed.dockerignoreNote == nil)
        #expect(trace.outcome(for: .dockerignoreCheck) == .noOp(reason: "no claims about .dockerignore rules"))
        let later = [user(question), LLMMessage(role: .assistant, content: monorepo),
                     user("Unrelated: what does `[a-z]+` match?")]
        let (moved, movedTrace) = await review("`[a-z]+` matches `abc`.", messages: later)
        #expect(moved.dockerignoreNote == nil)
        #expect(movedTrace.outcome(for: .dockerignoreCheck) == .noOp(reason: "no claims about .dockerignore rules"))
    }

    @Test("a withheld answer is not checked")
    func withheldIsSkipped() async {
        let refusal = Refusal(stage: .guardrailOutput, headline: "Withheld", explanation: "x", recovery: nil)
        let withheld = AnswerReview(
            publishableText: "", wasModified: true, groundedFraction: nil, claimCount: 0, refusal: refusal
        )
        var trace = PipelineTrace()
        let result = await PostModelPipeline.checkDockerignoreRules(withheld, messages: [user(question)], trace: &trace)
        #expect(result == withheld)
        #expect(trace.outcome(for: .dockerignoreCheck)
            == .skipped(reason: "the answer was withheld, so there is nothing to check"))
    }
}
