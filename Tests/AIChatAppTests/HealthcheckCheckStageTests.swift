import Foundation
import GuardrailKit
import ProviderGatewayKit
import Testing
@testable import AIChatApp

private let file = """
```yaml
services:
  api:
    image: myorg/api:2.4
    restart: always
    ports:
      - "8080:3000"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000/health", "||", "exit", "1"]
      interval: 10s
```
"""
private let question = "My `api` container stays unhealthy and Docker never restarts it. Why?\n" + file

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

private let wrongAnswer = "Your healthcheck is fine: Docker runs the test through a shell, so the `||` works. "
    + "With `restart: always`, Docker restarts the container when it becomes unhealthy, so give it a minute."
private let execNote = "The exec form (`[\"CMD\", ...]`) runs the program directly, with no shell: `||`, `&&` and "
    + "`$VAR` reach it as plain arguments. Use `CMD-SHELL` or a string `test:` for shell syntax."
private let restartNote = "Docker does not restart an unhealthy container, whatever the restart policy: it only "
    + "marks it `unhealthy`."

@Suite("HealthcheckClaimKit - what an answer says about a container healthcheck, by compose's and the engine's rules")
struct HealthcheckCheckStageTests {
    @Test("the exec form read as a shell and a restart that never happens get one note, last in review")
    func wrongAnswerGetsANote() async throws {
        let (reviewed, trace) = await review(wrongAnswer)
        #expect(reviewed.publishableText == wrongAnswer)
        let note = try #require(reviewed.healthcheckNote)
        #expect(note.hasPrefix("Healthcheck check: " + execNote))
        #expect(note.contains(restartNote))
        guard case let .ran(detail)? = trace.outcome(for: .healthcheckCheck) else {
            Issue.record("expected the stage to run")
            return
        }
        #expect(detail.hasPrefix("wrong: 2 claim(s), 2 wrong, 0 caution; "))
        let stages = trace.records.map(\.stage)
        let healthStage = try #require(stages.firstIndex(of: .healthcheckCheck))
        let commandStage = try #require(stages.firstIndex(of: .commandCheck))
        #expect(healthStage > commandStage)
        // One mistake, one note: every other stage reads the same answer and stays quiet.
        var bubble = ChatBubble(role: .assistant, text: reviewed.publishableText)
        bubble.applyReview(reviewed)
        #expect(bubble.healthcheckNote == reviewed.healthcheckNote)
        #expect(bubble.reviewNotes.map(\.id) == ["healthcheckNote"])
    }

    @Test("the fix with CMD-SHELL stays quiet")
    func fixIsQuiet() async {
        let answer = """
        The exec form runs `curl` directly, so no shell ever read the `||`. Use `CMD-SHELL`:
        ```yaml
        services:
          api:
            image: myorg/api:2.4
            restart: always
            ports:
              - "8080:3000"
            healthcheck:
              test: ["CMD-SHELL", "curl -f http://localhost:3000/health || exit 1"]
              interval: 10s
        ```
        A `CMD-SHELL` test is run by a shell. Docker never restarts an unhealthy container, even with \
        `restart: always`; it only marks it `unhealthy`.
        """
        let (reviewed, trace) = await review(answer)
        #expect(reviewed.healthcheckNote == nil)
        #expect(trace.outcome(for: .healthcheckCheck) == .noOp(reason: "verified: 2 claim(s), 0 wrong, 0 caution"))
        var bubble = ChatBubble(role: .assistant, text: reviewed.publishableText)
        bubble.applyReview(reviewed)
        #expect(bubble.reviewNotes.isEmpty)
    }

    @Test("an answer whose own Dockerfile puts || in the exec form gets the line in the note")
    func fileLineGetsTheFix() async {
        let answer = """
        Add this to the Dockerfile:
        ```dockerfile
        FROM python:3.13-slim
        HEALTHCHECK CMD ["curl", "-f", "http://localhost:8000/health", "||", "exit", "1"]
        ```
        """
        let (reviewed, _) = await review(answer, messages: [user("How do I add a healthcheck to my image?")])
        #expect(reviewed.healthcheckNote == "Healthcheck check: line 2: `||` in the exec form reaches the program "
            + "as an argument, not as a shell operator; use `CMD-SHELL` or a string `test:`.")
    }

    @Test("a test variable read from environment: gets a caution and a correction")
    func containerVariable() async {
        let answer = """
        ```yaml
        services:
          api:
            image: myorg/api:2.4
            environment:
              API_TOKEN: example-token
            healthcheck:
              test: ["CMD-SHELL", "curl -f -H 'Authorization: Bearer $API_TOKEN' http://localhost:3000/health"]
        ```
        Compose fills `$API_TOKEN` in the healthcheck from the container's environment.
        """
        let ask = "Can the healthcheck send the API token the service already has in `environment:`?"
        let (reviewed, trace) = await review(answer, messages: [user(ask)])
        #expect(reviewed.healthcheckNote?.contains("`api`, line 7: compose substitutes `$API_TOKEN` when it reads "
            + "the file") == true)
        guard case let .ran(detail)? = trace.outcome(for: .healthcheckCheck) else {
            Issue.record("expected the stage to run")
            return
        }
        #expect(detail.hasPrefix("wrong: 2 claim(s), 1 wrong, 1 caution; "))
    }

    @Test("history is replayed, and a claim stated again after a note is marked")
    func historyMarksRepeats() async {
        let first = "Docker restarts unhealthy containers on its own."
        let messages = [user("Does Docker restart my unhealthy container?"), assistant(first),
                        user("Are you sure?")]
        let (reviewed, trace) = await review("Yes: an unhealthy container is restarted by Docker.", messages: messages)
        #expect(reviewed.healthcheckNote?.hasSuffix("An earlier answer in this chat stated the same claim.") == true)
        if case .ran? = trace.outcome(for: .healthcheckCheck) {} else { Issue.record("expected the stage to run") }
    }

    @Test("Kubernetes probes, compose commands and other topics stay quiet")
    func otherTopicsAreQuiet() async {
        let answers = [
            "In Kubernetes a failing liveness probe restarts the container.",
            "Compose doesn't run `command` through a shell, so `&&` has no special meaning there.",
            "The capital of France is Paris."
        ]
        for answer in answers {
            let (reviewed, trace) = await review(answer, messages: [user("A question")])
            #expect(reviewed.healthcheckNote == nil, "\(answer)")
            #expect(trace.outcome(for: .healthcheckCheck) == .noOp(reason: "noClaims: 0 claim(s), 0 wrong, 0 caution"))
        }
    }

    @Test("a withheld answer is not checked")
    func withheldIsSkipped() async {
        let refusal = Refusal(stage: .guardrailOutput, headline: "Withheld", explanation: "x", recovery: nil)
        let withheld = AnswerReview(
            publishableText: "", wasModified: true, groundedFraction: nil, claimCount: 0, refusal: refusal
        )
        var trace = PipelineTrace()
        let result = await PostModelPipeline.checkHealthchecks(withheld, messages: [user(question)], trace: &trace)
        #expect(result == withheld)
        #expect(trace.outcome(for: .healthcheckCheck)
            == .skipped(reason: "the answer was withheld, so there is nothing to check"))
    }
}
