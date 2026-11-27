import Foundation
import GuardrailKit
import ProviderGatewayKit
import Testing
@testable import AIChatApp

private let file = """
```yaml
services:
  db:
    image: postgres:18
    environment:
      POSTGRES_PASSWORD_FILE: /run/secrets/db_password
    secrets:
      - db_password
secrets:
  db_password:
    file: ./db_password.txt
```
"""
private let question = "How does my postgres service get the password?\n" + file

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

private let wrongAnswer = "Compose exposes the secret as an environment variable named `DB_PASSWORD` inside the "
    + "container. Compose secrets are encrypted at rest on the host."
private let variableNote = "A compose secret reaches the container as a file (`/run/secrets/<name>`), not as an "
    + "environment variable"
private let encryptionNote = "Outside Swarm, compose does not encrypt secrets"

@Suite("ComposeSecretClaimKit - what an answer says about compose secrets, by plain compose's rules")
struct SecretCheckStageTests {
    @Test("a secret said to be an environment variable and to be encrypted gets one note, last in review")
    func wrongAnswerGetsANote() async throws {
        let (reviewed, trace) = await review(wrongAnswer)
        #expect(reviewed.publishableText == wrongAnswer)
        let note = try #require(reviewed.secretNote)
        #expect(note.hasPrefix("Secret check: " + variableNote))
        #expect(note.contains(encryptionNote))
        guard case let .ran(detail)? = trace.outcome(for: .secretCheck) else {
            Issue.record("expected the stage to run")
            return
        }
        #expect(detail.hasPrefix("wrong: 2 claim(s), 2 wrong, 0 caution; "))
        let stages = trace.records.map(\.stage)
        let secretStage = try #require(stages.firstIndex(of: .secretCheck))
        let volumeStage = try #require(stages.firstIndex(of: .volumeCheck))
        #expect(secretStage > volumeStage)
        // One mistake, one note: every other stage reads the same answer and stays quiet.
        var bubble = ChatBubble(role: .assistant, text: reviewed.publishableText)
        bubble.applyReview(reviewed)
        #expect(bubble.secretNote == reviewed.secretNote)
        #expect(bubble.reviewNotes.map(\.id) == ["secretNote"])
    }

    @Test("the corrected answer stays quiet")
    func fixIsQuiet() async {
        let answer = "Compose mounts the secret as a file at `/run/secrets/db_password`, and postgres reads it "
            + "through `POSTGRES_PASSWORD_FILE`. Compose secrets are not encrypted, so keep the file out of git."
        let (reviewed, trace) = await review(answer)
        #expect(reviewed.secretNote == nil)
        #expect(trace.outcome(for: .secretCheck) == .noOp(reason: "verified: 2 claim(s), 0 wrong, 0 caution"))
        var bubble = ChatBubble(role: .assistant, text: reviewed.publishableText)
        bubble.applyReview(reviewed)
        #expect(bubble.reviewNotes.isEmpty)
    }

    @Test("an answer whose own compose file puts content: under a secret gets the line in the note")
    func fileLineGetsTheFix() async {
        let answer = """
        Here is the service:
        ```yaml
        services:
          api:
            image: myorg/api:2
            secrets:
              - api_key
        secrets:
          api_key:
            content: "abc123"
        ```
        """
        let (reviewed, _) = await review(answer, messages: [user("Add an API key to my compose file.")])
        #expect(reviewed.secretNote == "Secret check: `api_key`, line 7: a secret cannot take `content:` (only "
            + "configs do); compose refuses the file. Use `file:` or `environment:`.")
    }

    @Test("history is replayed, and a claim stated again after a note is marked")
    func historyMarksRepeats() async {
        let first = "Each secret you list becomes an environment variable in the container."
        let messages = [user(question), assistant(first), user("Are you sure?")]
        let (reviewed, trace) = await review("Yes: the secret is exposed as an environment variable.",
                                             messages: messages)
        #expect(reviewed.secretNote?.hasSuffix("An earlier answer in this chat stated the same claim.") == true)
        if case .ran? = trace.outcome(for: .secretCheck) {} else { Issue.record("expected the stage to run") }
    }

    @Test("Swarm, Kubernetes and other topics stay quiet")
    func otherTopicsAreQuiet() async {
        let answers = [
            "In Swarm, secrets are encrypted at rest in the Raft log and mounted on a tmpfs.",
            "In Kubernetes, a Secret can be injected as environment variables with `envFrom`.",
            "The capital of France is Paris."
        ]
        for answer in answers {
            let (reviewed, trace) = await review(answer, messages: [user("A question about secrets")])
            #expect(reviewed.secretNote == nil, "\(answer)")
            #expect(trace.outcome(for: .secretCheck) == .noOp(reason: "noClaims: 0 claim(s), 0 wrong, 0 caution"))
        }
    }

    @Test("a correct healthcheck exec-form answer gets no command note (ComposeCommandClaimKit 1.0.2)")
    func healthcheckAnswerHasNoCommandNote() async {
        let healthQuestion = "My web container never turns healthy.\n```yaml\nservices:\n  web:\n    image: nginx:1.27\n"
            + "    healthcheck:\n      test: [\"CMD\", \"curl\", \"-f\", \"http://localhost\", \"||\", \"exit\", \"1\"]\n```"
        let answer = "The exec form runs `curl` directly, so the `||` reached it as an argument."
        let (reviewed, trace) = await review(answer, messages: [user(healthQuestion)])
        #expect(reviewed.commandNote == nil)
        if case .ran? = trace.outcome(for: .commandCheck) { Issue.record("the command stage flagged a healthcheck") }
    }

    @Test("a withheld answer is not checked")
    func withheldIsSkipped() async {
        let refusal = Refusal(stage: .guardrailOutput, headline: "Withheld", explanation: "x", recovery: nil)
        let withheld = AnswerReview(
            publishableText: "", wasModified: true, groundedFraction: nil, claimCount: 0, refusal: refusal
        )
        var trace = PipelineTrace()
        let result = await PostModelPipeline.checkSecrets(withheld, messages: [user(question)], trace: &trace)
        #expect(result == withheld)
        #expect(trace.outcome(for: .secretCheck)
            == .skipped(reason: "the answer was withheld, so there is nothing to check"))
    }
}
