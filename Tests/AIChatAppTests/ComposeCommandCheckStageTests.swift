import Foundation
import GuardrailKit
import ProviderGatewayKit
import Testing
@testable import AIChatApp

private let file = """
```yaml
services:
  web:
    image: node:20-alpine
    working_dir: /app
    command: npm install && npm start
```
"""
private let question = "My `web` service installs its dependencies but the server never starts. Why?\n" + file

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

private let shellClaim = "Compose runs `command` through a shell, so `web` runs `npm install && npm start`."
private let ruleNote = "Compose runs no shell for a `command:` or `entrypoint:` string: it splits the string into "
    + "words and stops at the first unquoted `;`, `&`, `|`, `<` or `>`. Shell features need `sh -c`."

@Suite("ComposeCommandClaimKit - what an answer says a compose service runs, by compose's reading of command:")
struct ComposeCommandCheckStageTests {
    @Test("a command string read as run through a shell gets one note, last in review")
    func shellReadingGetsANote() async throws {
        let (reviewed, trace) = await review(shellClaim)
        #expect(reviewed.publishableText == shellClaim)
        let note = try #require(reviewed.commandNote)
        #expect(note.hasPrefix("Compose command check: " + ruleNote))
        #expect(note.contains("then `npm install`: compose runs no shell for a `command:` string"))
        guard case let .ran(detail)? = trace.outcome(for: .commandCheck) else {
            Issue.record("expected the stage to run")
            return
        }
        #expect(detail.hasPrefix("2 claims checked, 0 hold, 2 wrong; "))
        let stages = trace.records.map(\.stage)
        let commandStage = try #require(stages.firstIndex(of: .commandCheck))
        let mergeStage = try #require(stages.firstIndex(of: .mergeCheck))
        #expect(commandStage > mergeStage)
        // One mistake, one note: the compose, merge, YAML and container-command stages read the same answer.
        #expect(reviewed.composeNote == nil && reviewed.mergeNote == nil && reviewed.yamlNote == nil
            && reviewed.entrypointNote == nil && reviewed.dockerfileNote == nil)
        var bubble = ChatBubble(role: .assistant, text: reviewed.publishableText)
        bubble.applyReview(reviewed)
        #expect(bubble.commandNote == reviewed.commandNote)
        #expect(bubble.reviewNotes.map(\.id) == ["commandNote"])
    }

    @Test("the fix with a shell started on purpose stays quiet")
    func fixIsQuiet() async {
        let answer = """
        Compose does not run a `command` string through a shell: it stops at `&&`, so the old file ran only \
        `npm install`. Start a shell yourself:
        ```yaml
        services:
          web:
            image: node:20-alpine
            working_dir: /app
            command: ["sh", "-c", "npm install && npm start"]
        ```
        Now `web` runs `npm install && npm start` inside `sh -c`.
        """
        let (reviewed, trace) = await review(answer)
        #expect(reviewed.commandNote == nil)
        #expect(trace.outcome(for: .commandCheck) == .noOp(reason: "2 claims checked, 2 hold"))
        #expect(reviewed.yamlNote == nil && reviewed.composeNote == nil)
    }

    @Test("an answer whose own file stops at && gets the fix in the note")
    func fileLineGetsTheFix() async {
        let answer = """
        Use this:
        ```yaml
        services:
          api:
            image: python:3.12-slim
            command: pip install -r requirements.txt && python app.py
        ```
        """
        let (reviewed, _) = await review(answer, messages: [user("How do I install and then start the API in compose?")])
        #expect(reviewed.commandNote?.contains("`command: [\"sh\", \"-c\", \"pip install -r requirements.txt && "
            + "python app.py\"]`") == true)
    }

    @Test("an entrypoint read as keeping the image's CMD")
    func tiniKeepsNoCmd() async {
        let answer = """
        ```dockerfile
        FROM node:20-alpine
        RUN apk add --no-cache tini
        CMD ["node", "server.js"]
        ```
        ```yaml
        services:
          web:
            build: .
            entrypoint: ["/sbin/tini", "--"]
        ```
        Setting `entrypoint` keeps the image's `CMD`, so `web` runs `/sbin/tini -- node server.js`.
        """
        let (reviewed, _) = await review(answer, messages: [user("Can I run it under tini in compose?")])
        #expect(reviewed.commandNote?.contains("`web` runs `/sbin/tini --`: an entrypoint set in compose drops the "
            + "image's CMD (`node server.js`).") == true)
        #expect(reviewed.dockerfileNote == nil && reviewed.entrypointNote == nil)
    }

    @Test("a later answer is read against a file shown earlier, and a repeated claim is marked")
    func historyCounts() async {
        let followUp = "Are you sure compose runs it through a shell?"
        let (reviewed, _) = await review(
            "Yes: `web` runs `npm install && npm start`.",
            messages: [user(question), assistant("Let me look at your file."), user(followUp)]
        )
        #expect(reviewed.commandNote?.contains("then `npm install`") == true)
        #expect(reviewed.commandNote?.hasSuffix("An earlier answer in this chat stated the same claim.") == false)
        let (repeated, trace) = await review(
            "Again: compose runs `command` through a shell.",
            messages: [user(question), assistant(shellClaim), user(followUp)]
        )
        #expect(repeated.commandNote?.hasSuffix("An earlier answer in this chat stated the same claim.") == true)
        if case .ran? = trace.outcome(for: .commandCheck) {} else { Issue.record("expected the stage to run") }
    }

    @Test("Kubernetes, Dockerfiles and other topics stay quiet")
    func otherDomainsQuiet() async {
        let answers = [
            "```yaml\napiVersion: v1\nkind: Pod\nspec:\n  containers:\n    - name: web\n      image: node:20\n"
                + "      command: [\"npm\"]\n```\nHere `command` replaces the image's `ENTRYPOINT`.",
            "The shell form of `CMD` in a Dockerfile runs through `/bin/sh -c`.",
            "In CSS, later rules override earlier ones, so the second `color` wins."
        ]
        for answer in answers {
            let (reviewed, trace) = await review(answer, messages: [user("How do I configure this?")])
            #expect(reviewed.commandNote == nil, "\(answer)")
            #expect(trace.outcome(for: .commandCheck) == .noOp(reason: "no claims about compose commands"))
        }
    }

    @Test("a withheld answer is not checked")
    func withheldIsSkipped() async {
        let refusal = Refusal(stage: .guardrailOutput, headline: "Withheld", explanation: "x", recovery: nil)
        let withheld = AnswerReview(
            publishableText: "", wasModified: true, groundedFraction: nil, claimCount: 0, refusal: refusal
        )
        var trace = PipelineTrace()
        let result = await PostModelPipeline.checkComposeCommands(withheld, messages: [user(question)], trace: &trace)
        #expect(result == withheld)
        #expect(trace.outcome(for: .commandCheck)
            == .skipped(reason: "the answer was withheld, so there is nothing to check"))
    }
}
