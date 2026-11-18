import Foundation
import GuardrailKit
import ProviderGatewayKit
import Testing
@testable import AIChatApp

private let question = "Write a Dockerfile for my Node app and tell me where the code ends up."

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

private func dockerfile(_ lines: String) -> String {
    "```dockerfile\n\(lines)\n```\n"
}

private let copyAnswer = dockerfile("FROM node:20-slim\nWORKDIR /app\nCOPY src /app")
    + "`src/index.js` ends up at `/app/src/index.js`."
private let copyWrong = "It does not hold that `src/index.js` ends up at `/app/src/index.js`: `COPY` of a directory "
    + "copies what is inside it, not the directory itself; Docker puts it at `/app/index.js`."

@Suite("DockerfileClaimKit - what an answer says about a Dockerfile, by Docker's own rules")
struct DockerfileCheckStageTests {
    @Test("a directory copy said to keep its folder gets a note with where Docker puts the file, last in review")
    func placementGetsANote() async throws {
        let (reviewed, trace) = await review(copyAnswer)
        #expect(reviewed.publishableText == copyAnswer)
        #expect(reviewed.dockerfileNote == "Dockerfile check: " + copyWrong)
        #expect(trace.outcome(for: .dockerfileCheck) == .ran(detail: "1 claim checked, 0 hold, 1 wrong; " + copyWrong))
        let stages = trace.records.map(\.stage)
        let file = try #require(stages.firstIndex(of: .dockerfileCheck))
        let ignore = try #require(stages.firstIndex(of: .dockerignoreCheck))
        #expect(file > ignore)
        var bubble = ChatBubble(role: .assistant, text: reviewed.publishableText)
        bubble.applyReview(reviewed)
        #expect(bubble.dockerfileNote == reviewed.dockerfileNote)
        #expect(bubble.reviewNotes.map(\.id).last == "dockerfileNote")
    }

    @Test("the Dockerfile's own lines are judged: RUN cd, an ARG above FROM, exec-form $PORT")
    func linesAreChecked() async {
        let answer = dockerfile("ARG V=1\nFROM node:20\nRUN cd /app\nRUN echo $V\nENV PORT=3000\n"
            + "CMD [\"node\", \"a.js\", \"$PORT\"]")
        let (reviewed, trace) = await review(answer)
        let note = reviewed.dockerfileNote ?? ""
        #expect(note.contains("write `WORKDIR /app` instead"))
        #expect(note.contains("write `ARG V` instead"))
        #expect(note.contains("write `CMD [\"sh\", \"-c\", \"node a.js $PORT\"]` instead"))
        #expect(trace.outcome(for: .dockerfileCheck).map { "\($0)" }?.contains("3 claims checked, 0 hold, 3 wrong")
            == true)
    }

    @Test("a claim that holds only if the base image has a directory is a second look")
    func setupIsACaveat() async {
        let answer = dockerfile("FROM node:20\nCOPY a.txt /data") + "This puts `a.txt` at `/data/a.txt`."
        let (reviewed, _) = await review(answer)
        #expect(reviewed.dockerfileNote?.hasPrefix(
            "Dockerfile check: It holds that `a.txt` ends up at `/data/a.txt`, but only if `/data` is already a directory")
            == true)
    }

    @Test("a wrong claim stated again in a later turn is judged against the earlier Dockerfile and marked")
    func repeatedClaimSaysSo() async {
        let messages = [user(question), LLMMessage(role: .assistant, content: copyAnswer), user("Are you sure?")]
        let again = "Yes, `src/index.js` ends up at `/app/src/index.js`."
        let (reviewed, trace) = await review(again, messages: messages)
        #expect(reviewed.dockerfileNote
            == "Dockerfile check: " + copyWrong + " An earlier answer in this chat stated the same claim.")
        #expect(trace.outcome(for: .dockerfileCheck)
            == .ran(detail: "1 claim checked, 0 hold, 1 wrong, 1 repeated; " + copyWrong))
    }

    @Test("a line only the classic builder stops on, and a file the .dockerignore keeps out, go to the trace only")
    func traceOnly() async {
        let (several, severalTrace) = await review(dockerfile("FROM node:20\nWORKDIR /app\nCOPY package.json package-lock.json ."))
        #expect(several.dockerfileNote == nil)
        #expect(severalTrace.outcome(for: .dockerfileCheck).map { "\($0)" }?.contains("not shown under the answer: "
            + "`COPY package.json package-lock.json .` stops the classic builder") == true)
        let ignored = dockerfile("FROM node:20\nWORKDIR /app\nCOPY . .")
            + "Add a `.dockerignore`:\n\n```\n**/*.log\n```\n\n"
            + "With that Dockerfile, `logs/build.log` ends up at `/app/logs/build.log`."
        let (once, onceTrace) = await review(ignored)
        #expect(once.dockerfileNote == nil, "one mistake, one note: dockerignoreCheck owns it")
        #expect(once.dockerignoreNote != nil)
        #expect(onceTrace.outcome(for: .dockerfileCheck).map { "\($0)" }?.contains("not shown under the answer") == true)
        let mixed = dockerfile("FROM node:20\nRUN cd /app\nCOPY a b .")
        let (both, _) = await review(mixed)
        #expect(both.dockerfileNote?.contains("WORKDIR /app") == true)
        #expect(both.dockerfileNote?.contains("classic builder") == false)
    }

    @Test("claims that hold, answers with no Dockerfile, and other copy tools get no note")
    func quietOtherwise() async {
        let held = dockerfile("FROM node:20\nWORKDIR /app\nCOPY src ./src") + "`src/index.js` lands at `/app/src/index.js`."
        let (fine, fineTrace) = await review(held)
        #expect(fine.dockerfileNote == nil)
        #expect(fineTrace.outcome(for: .dockerfileCheck) == .noOp(reason: "1 claim checked, 1 hold"))
        let quiet = [
            "Weigh the flour rather than using cups.",
            "`cp -r src /app` creates `/app/src` when `/app` exists.",
            "In compose, `volumes: - ./src:/app/src` mounts `src` at `/app/src`.",
            "`[a-z]+` matches `abc`, and `SELECT name FROM users` returns every user.",
            "In `.dockerignore`, `**/*.log` matches `logs/app.log`."
        ]
        for answer in quiet {
            let (none, noneTrace) = await review(answer)
            #expect(none.dockerfileNote == nil, "\(answer)")
            #expect(noneTrace.outcome(for: .dockerfileCheck) == .noOp(reason: "no claims about a Dockerfile"))
        }
    }

    @Test("correct answers a first version flagged stay quiet")
    func reviewProbesStayQuiet() async {
        let answers = [
            dockerfile("FROM nginx\nCOPY nginx.conf /etc/nginx/conf.d/default.conf")
                + "`nginx.conf` is copied to `/etc/nginx/conf.d/default.conf`.",
            dockerfile("FROM python:3.12 AS b\nENV PATH=\"/opt/venv/bin:$PATH\"\nFROM python:3.12-slim\n"
                + "ENV PATH=\"/opt/venv/bin:$PATH\""),
            dockerfile("FROM python:3.12\nWORKDIR /app\nCOPY requirements.txt .\nRUN pip install -r requirements.txt")
                + "`requirements.txt` is copied first, then `pip install` puts packages in `/usr/local/lib/python3.12`.",
            copyFix + "You can't override an `ARG` with `docker run -e`; pass `--build-arg`.",
            copyFix + "`COPY src /app/src` copies the folder itself to `/app/src`.",
            copyFix + "`COPY . .` copies the project directory, including the Dockerfile itself.",
            dockerfile("FROM alpine\nENV X=1\nENTRYPOINT [\"tini\", \"--\", \"sh\", \"-c\", \"echo $X\"]")
        ]
        for answer in answers {
            let (reviewed, _) = await review(answer)
            #expect(reviewed.dockerfileNote == nil, "\(answer)")
        }
    }

    @Test("a withheld answer is not checked")
    func withheldIsSkipped() async {
        let refusal = Refusal(stage: .guardrailOutput, headline: "Withheld", explanation: "x", recovery: nil)
        let withheld = AnswerReview(
            publishableText: "", wasModified: true, groundedFraction: nil, claimCount: 0, refusal: refusal
        )
        var trace = PipelineTrace()
        let result = await PostModelPipeline.checkDockerfile(withheld, messages: [user(question)], trace: &trace)
        #expect(result == withheld)
        #expect(trace.outcome(for: .dockerfileCheck)
            == .skipped(reason: "the answer was withheld, so there is nothing to check"))
    }
}

private let copyFix = "```dockerfile\nFROM node:20-slim\nWORKDIR /app\nCOPY src /app/src\n```\n"
