import Foundation
import GuardrailKit
import ProviderGatewayKit
import Testing
@testable import AIChatApp

private let question = "How do I turn on --debug when I run my API container?"

private func user(_ text: String) -> LLMMessage {
    LLMMessage(role: .user, content: text)
}

private func assistant(_ text: String) -> LLMMessage {
    LLMMessage(role: .assistant, content: text)
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

private func dockerfile(_ lines: String) -> String {
    "```dockerfile\n\(lines)\n```\n"
}

private let api = dockerfile("FROM python:3.12-slim\nWORKDIR /app\nCOPY . .\nENTRYPOINT [\"python\", \"app.py\"]\n"
    + "CMD [\"--port\", \"80\"]") + "Build it with `docker build -t api .`. "
private let debugAnswer = api + "Then `docker run api --debug` runs `python app.py --port 80 --debug`."
private let debugWrong = "`docker run api --debug` does not run `python app.py --port 80 --debug`: it runs "
    + "`python app.py --debug` (arguments after the image replace CMD; they are not added to it)."

@Suite("EntrypointClaimKit - what an answer says a container runs, by Docker's own rules")
struct EntrypointCheckStageTests {
    @Test("arguments said to be added to CMD get a note with what runs, last in review")
    func argumentsGetANote() async throws {
        let (reviewed, trace) = await review(debugAnswer)
        #expect(reviewed.publishableText == debugAnswer)
        #expect(reviewed.entrypointNote == "Container command check: " + debugWrong)
        #expect(trace.outcome(for: .entrypointCheck) == .ran(detail: "1 claim checked, 0 hold, 1 wrong; " + debugWrong))
        let stages = trace.records.map(\.stage)
        let command = try #require(stages.firstIndex(of: .entrypointCheck))
        let file = try #require(stages.firstIndex(of: .dockerfileCheck))
        #expect(command > file)
        var bubble = ChatBubble(role: .assistant, text: reviewed.publishableText)
        bubble.applyReview(reviewed)
        #expect(bubble.entrypointNote == reviewed.entrypointNote)
        #expect(bubble.reviewNotes.map(\.id).last == "entrypointNote")
    }

    @Test("bash handed to an exec-form ENTRYPOINT is caught; the same claim under a wrapper holds")
    func shellUnderEntrypoint() async {
        let (wrong, _) = await review(api + "For a shell, `docker run -it api bash` starts `bash`.")
        #expect(wrong.entrypointNote?.contains("it runs `python app.py bash`") == true)
        let wrapper = dockerfile("FROM postgres:16\nENTRYPOINT [\"/entrypoint.sh\"]\nCMD [\"postgres\"]")
            + "Build with `docker build -t db .`. `docker run -it db bash` starts `bash`."
        let (held, trace) = await review(wrapper)
        #expect(held.entrypointNote == nil)
        #expect(trace.outcome(for: .entrypointCheck) == .noOp(reason: "1 claim checked, 1 hold"))
    }

    @Test("the Dockerfile's own lines are judged: a shell-form ENTRYPOINT with a CMD, single quotes")
    func linesAreChecked() async {
        let answer = dockerfile("FROM node:20-slim\nENTRYPOINT node server.js\nCMD [\"--port\", \"3000\"]")
        let (reviewed, _) = await review(answer)
        #expect(reviewed.entrypointNote?.contains("Use `ENTRYPOINT [\"node\", \"server.js\"]`.") == true)
        let quoted = dockerfile("FROM node:20-slim\nCMD ['node', 'server.js']")
        let (broken, _) = await review(quoted)
        #expect(broken.entrypointNote?.contains("Use `CMD [\"node\", \"server.js\"]`.") == true)
    }

    @Test("a later turn is judged against the earlier Dockerfile and marked as said again")
    func historyIsReplayed() async {
        let messages = [user(question), assistant(debugAnswer), user("Are you sure?")]
        let (reviewed, trace) = await review("Yes: `docker run api --debug` runs `python app.py --port 80 --debug`.",
                                             messages: messages)
        #expect(reviewed.entrypointNote == "Container command check: " + debugWrong
            + " An earlier answer in this chat stated the same claim.")
        #expect(trace.outcome(for: .entrypointCheck).map { "\($0)" }?.contains("1 repeated") == true)
    }

    @Test("$VAR in an exec-form CMD is dockerfileCheck's note only: one mistake, one note")
    func variablesBelongToDockerfileCheck() async {
        let answer = dockerfile("FROM node:20\nENV PORT=3000\nCMD [\"node\", \"a.js\", \"--port\", \"$PORT\"]")
        let (reviewed, _) = await review(answer)
        #expect(reviewed.dockerfileNote != nil)
        #expect(reviewed.entrypointNote == nil)
    }

    @Test("a correct answer and answers about other things stay quiet")
    func quiet() async {
        let fine = api + "`docker run api --port 80 --debug` runs `python app.py --port 80 --debug`."
        let (held, heldTrace) = await review(fine)
        #expect(held.entrypointNote == nil)
        #expect(heldTrace.outcome(for: .entrypointCheck) == .noOp(reason: "1 claim checked, 1 hold"))
        for answer in ["In docker compose, `command:` replaces CMD.", "The `cron` job runs `backup.sh` nightly.",
                       "In Kubernetes, `args` overrides CMD and `command` overrides the ENTRYPOINT."] {
            let (none, noneTrace) = await review(answer)
            #expect(none.entrypointNote == nil, "\(answer)")
            #expect(noneTrace.outcome(for: .entrypointCheck) == .noOp(reason: "no claims about what a container runs"))
        }
    }

    @Test("a withheld answer is not checked")
    func withheldIsSkipped() async {
        let refusal = Refusal(stage: .guardrailOutput, headline: "Withheld", explanation: "x", recovery: nil)
        let withheld = AnswerReview(
            publishableText: "", wasModified: true, groundedFraction: nil, claimCount: 0, refusal: refusal
        )
        var trace = PipelineTrace()
        let result = await PostModelPipeline.checkEntrypoints(withheld, messages: [user(question)], trace: &trace)
        #expect(result == withheld)
        #expect(trace.outcome(for: .entrypointCheck)
            == .skipped(reason: "the answer was withheld, so there is nothing to check"))
    }
}
