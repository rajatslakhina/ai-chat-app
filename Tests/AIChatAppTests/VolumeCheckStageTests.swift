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
    volumes:
      - pgdata:/var/lib/postgresql/data
  web:
    build: .
    volumes:
      - .:/app
      - /app/node_modules
volumes:
  pgdata:
```
"""
private let question = "Does `docker compose down` delete my Postgres data, and why don't new npm packages show up "
    + "after I rebuild?\n" + file

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

private let wrongAnswer = "Yes: `docker compose down` deletes the `pgdata` volume, so back it up first. After "
    + "`docker compose up --build`, the `node_modules` volume gets the new packages from the image."
private let downNote = "`docker compose down` removes the containers and networks and keeps named volumes; only "
    + "`down -v` (`--volumes`) deletes them."
private let rebuildNote = "Rebuilding or recreating keeps a volume, named or anonymous, and its content"

@Suite("ComposeVolumeClaimKit - what an answer says about compose volumes, by compose's and the engine's rules")
struct VolumeCheckStageTests {
    @Test("down said to delete a named volume and a rebuild said to refresh one get one note, last in review")
    func wrongAnswerGetsANote() async throws {
        let (reviewed, trace) = await review(wrongAnswer)
        #expect(reviewed.publishableText == wrongAnswer)
        let note = try #require(reviewed.volumeNote)
        #expect(note.hasPrefix("Volume check: " + downNote))
        #expect(note.contains(rebuildNote))
        guard case let .ran(detail)? = trace.outcome(for: .volumeCheck) else {
            Issue.record("expected the stage to run")
            return
        }
        #expect(detail.hasPrefix("wrong: 2 claim(s), 2 wrong, 0 caution; "))
        let stages = trace.records.map(\.stage)
        let volumeStage = try #require(stages.firstIndex(of: .volumeCheck))
        let healthStage = try #require(stages.firstIndex(of: .healthcheckCheck))
        #expect(volumeStage > healthStage)
        // One mistake, one note: every other stage reads the same answer and stays quiet.
        var bubble = ChatBubble(role: .assistant, text: reviewed.publishableText)
        bubble.applyReview(reviewed)
        #expect(bubble.volumeNote == reviewed.volumeNote)
        #expect(bubble.reviewNotes.map(\.id) == ["volumeNote"])
    }

    @Test("the corrected answer stays quiet")
    func fixIsQuiet() async {
        let answer = "No: named volumes such as `pgdata` survive `docker compose down`. The anonymous volume "
            + "survives `docker compose up --build`, so it still holds the old packages. Run "
            + "`docker compose up --build -V` to renew it."
        let (reviewed, trace) = await review(answer)
        #expect(reviewed.volumeNote == nil)
        #expect(trace.outcome(for: .volumeCheck) == .noOp(reason: "verified: 2 claim(s), 0 wrong, 0 caution"))
        var bubble = ChatBubble(role: .assistant, text: reviewed.publishableText)
        bubble.applyReview(reviewed)
        #expect(bubble.reviewNotes.isEmpty)
    }

    @Test("an answer whose own compose file uses an undeclared volume gets the line in the note")
    func fileLineGetsTheFix() async {
        let answer = """
        Here is the service:
        ```yaml
        services:
          db:
            image: postgres:18
            volumes:
              - db-data:/var/lib/postgresql/data
        ```
        """
        let (reviewed, _) = await review(answer, messages: [user("Add a database to my compose file.")])
        #expect(reviewed.volumeNote == "Volume check: `db`, line 5: `db-data` is not declared under the top-level "
            + "`volumes:` key, so compose refuses the file.")
    }

    @Test("history is replayed, and a claim stated again after a note is marked")
    func historyMarksRepeats() async {
        let first = "Named volumes are wiped by `docker compose down`."
        let messages = [user(question), assistant(first), user("Are you sure?")]
        let (reviewed, trace) = await review("Yes: `docker compose down` deletes named volumes.", messages: messages)
        #expect(reviewed.volumeNote?.hasSuffix("An earlier answer in this chat stated the same claim.") == true)
        if case .ran? = trace.outcome(for: .volumeCheck) {} else { Issue.record("expected the stage to run") }
    }

    @Test("docker run, Kubernetes and other topics stay quiet")
    func otherTopicsAreQuiet() async {
        let answers = [
            "`docker run -v data:/x alpine` creates the `data` volume on the fly; no declaration is needed.",
            "In Kubernetes the PersistentVolume is deleted when its claim is removed.",
            "The capital of France is Paris."
        ]
        for answer in answers {
            let (reviewed, trace) = await review(answer, messages: [user("A question")])
            #expect(reviewed.volumeNote == nil, "\(answer)")
            #expect(trace.outcome(for: .volumeCheck) == .noOp(reason: "noClaims: 0 claim(s), 0 wrong, 0 caution"))
        }
    }

    @Test("a withheld answer is not checked")
    func withheldIsSkipped() async {
        let refusal = Refusal(stage: .guardrailOutput, headline: "Withheld", explanation: "x", recovery: nil)
        let withheld = AnswerReview(
            publishableText: "", wasModified: true, groundedFraction: nil, claimCount: 0, refusal: refusal
        )
        var trace = PipelineTrace()
        let result = await PostModelPipeline.checkVolumes(withheld, messages: [user(question)], trace: &trace)
        #expect(result == withheld)
        #expect(trace.outcome(for: .volumeCheck)
            == .skipped(reason: "the answer was withheld, so there is nothing to check"))
    }
}
