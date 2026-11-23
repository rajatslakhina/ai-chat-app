import Foundation
import GuardrailKit
import ProviderGatewayKit
import Testing
@testable import AIChatApp

private let question = "In development I want the API on port 8081 with debug logging. How do I use a docker "
    + "compose override file?"

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

private let files = """
`docker-compose.yml`:
```yaml
services:
  api:
    image: shop-api:1.4
    ports:
      - "8080:8000"
    environment:
      LOG_LEVEL: info
      DEBUG: "0"
```

`docker-compose.override.yml`:
```yaml
services:
  api:
    build: .
    ports:
      - "8081:8000"
    environment:
      DEBUG: "1"
```

"""

private let replaced = files + "With both files, `api` publishes `8081` instead of `8080`."
private let portNote = "With these files, `api` publishes ports `8080` and `8081`. A later file's lists are appended "
    + "to the earlier ones (`ports` and `volumes` merge items with the same key); tag the list `!override` to "
    + "replace it."

@Suite("ComposeMergeClaimKit - what an answer says merged compose files do, by compose's merge rules")
struct ComposeMergeCheckStageTests {
    @Test("the override's ports read as replacing the base ones get one note, last in review")
    func replacedPortsGetANote() async throws {
        let (reviewed, trace) = await review(replaced)
        #expect(reviewed.publishableText == replaced)
        #expect(reviewed.mergeNote == "Compose merge check: " + portNote)
        #expect(trace.outcome(for: .mergeCheck) == .ran(detail: "1 claim checked, 0 hold, 1 wrong; " + portNote))
        let stages = trace.records.map(\.stage)
        let mergeStage = try #require(stages.firstIndex(of: .mergeCheck))
        let composeStage = try #require(stages.firstIndex(of: .composeCheck))
        #expect(mergeStage > composeStage)
        // One mistake, one note: the compose, YAML and container-command stages read the same answer.
        #expect(reviewed.composeNote == nil && reviewed.yamlNote == nil && reviewed.entrypointNote == nil)
        var bubble = ChatBubble(role: .assistant, text: reviewed.publishableText)
        bubble.applyReview(reviewed)
        #expect(bubble.mergeNote == reviewed.mergeNote)
        #expect(bubble.reviewNotes.map(\.id) == ["mergeNote"])
    }

    @Test("a correct description of the merge stays quiet, and so does the compose stage")
    func correctMergeIsQuiet() async {
        let answer = files + "Run `docker compose up`. With both files, `api` publishes both `8080` and `8081`, "
            + "`DEBUG` is `1` and `LOG_LEVEL` stays `info`. From your laptop, `api` is reachable on "
            + "`localhost:8080` and `localhost:8081`."
        let (reviewed, trace) = await review(answer)
        #expect(reviewed.mergeNote == nil)
        #expect(reviewed.composeNote == nil, "\(reviewed.composeNote ?? "")")
        #expect(trace.outcome(for: .mergeCheck) == .noOp(reason: "4 claims checked, 4 hold"))
    }

    @Test("the environment read as replaced whole, and the override read as applying with -f")
    func otherSlips() async {
        let (gone, _) = await review(files + "With both files, `LOG_LEVEL` is gone.")
        #expect(gone.mergeNote?.contains("merged key by key") == true)
        let production = files + "Run `docker compose -f docker-compose.yml up -d`; the override is still applied, "
            + "so `DEBUG` stays `1`."
        let (withFile, _) = await review(production)
        #expect(withFile.mergeNote?.contains("With `-f`, compose reads only the files named") == true)
    }

    @Test("a later answer is read against files shown earlier, and a repeated claim is marked")
    func historyCounts() async {
        let followUp = "Are you sure about the ports with the docker compose override?"
        let later = "As I said, with both files `api` publishes only `8081`."
        let (reviewed, _) = await review(later, messages: [user(question), assistant(files), user(followUp)])
        #expect(reviewed.mergeNote?.contains("publishes ports `8080` and `8081`") == true)
        #expect(reviewed.mergeNote?.hasSuffix("An earlier answer in this chat stated the same claim.") == false)
        let same = "With both files, `api` publishes `8081` instead of `8080`."
        let (repeated, trace) = await review(same, messages: [user(question), assistant(replaced), user(followUp)])
        #expect(repeated.mergeNote?.hasSuffix("An earlier answer in this chat stated the same claim.") == true)
        if case .ran? = trace.outcome(for: .mergeCheck) {} else { Issue.record("expected the stage to run") }
    }

    @Test("other domains and single compose files stay quiet")
    func otherDomainsQuiet() async {
        let answers = [
            "In Helm, lists in a values override file replace the chart defaults.",
            "In CSS, later rules override earlier ones, so the second `color` wins.",
            "```yaml\nservices:\n  web:\n    image: nginx:1.27\n    ports:\n      - \"8080:80\"\n```\n"
                + "Run `docker compose up -d` and open `http://localhost:8080`."
        ]
        for answer in answers {
            let (reviewed, trace) = await review(answer, messages: [user("How do I configure this?")])
            #expect(reviewed.mergeNote == nil, "\(answer)")
            #expect(trace.outcome(for: .mergeCheck) == .noOp(reason: "no claims about merging compose files"))
        }
    }

    @Test("a withheld answer is not checked")
    func withheldIsSkipped() async {
        let refusal = Refusal(stage: .guardrailOutput, headline: "Withheld", explanation: "x", recovery: nil)
        let withheld = AnswerReview(
            publishableText: "", wasModified: true, groundedFraction: nil, claimCount: 0, refusal: refusal
        )
        var trace = PipelineTrace()
        let result = await PostModelPipeline.checkComposeMerge(withheld, messages: [user(question)], trace: &trace)
        #expect(result == withheld)
        #expect(trace.outcome(for: .mergeCheck)
            == .skipped(reason: "the answer was withheld, so there is nothing to check"))
    }
}
