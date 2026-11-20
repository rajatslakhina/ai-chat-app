import Foundation
import GuardrailKit
import ProviderGatewayKit
import Testing
@testable import AIChatApp

private let question = "Our API can't reach Postgres under docker compose. How do I set DATABASE_URL?"

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

private func compose(_ databaseURL: String, extra: String = "") -> String {
    "```yaml\nservices:\n  api:\n    build: .\n    ports:\n      - \"8000:8000\"\n    environment:\n"
        + "      DATABASE_URL: \(databaseURL)\n\(extra)    depends_on:\n      - db\n  db:\n    image: postgres:16\n"
        + "    ports:\n      - \"5433:5432\"\n```\n"
}

private let wrongPort = compose("postgres://app:secret@db:5433/app")
    + "The `api` service connects to Postgres at `db:5433`."
private let portNote = "`db:5433` does not work from inside `api`: containers reach each other on the container "
    + "port, so use `db:5432` (the container port of `5433:5432`)."

@Suite("ComposeClaimKit - what an answer says about a compose project, by compose's own rules")
struct ComposeCheckStageTests {
    @Test("the published port used between containers gets one note, last in review")
    func publishedPortGetsANote() async throws {
        let (reviewed, trace) = await review(wrongPort)
        #expect(reviewed.publishableText == wrongPort)
        #expect(reviewed.composeNote == "Compose check: " + portNote)
        #expect(trace.outcome(for: .composeCheck) == .ran(detail: "1 claim checked, 0 hold, 1 wrong; " + portNote))
        let stages = trace.records.map(\.stage)
        let composeStage = try #require(stages.firstIndex(of: .composeCheck))
        let entrypoint = try #require(stages.firstIndex(of: .entrypointCheck))
        #expect(composeStage > entrypoint)
        // One mistake, one note: the YAML, Dockerfile and container-command stages read the same answer.
        #expect(reviewed.yamlNote == nil && reviewed.dockerfileNote == nil && reviewed.entrypointNote == nil)
        var bubble = ChatBubble(role: .assistant, text: reviewed.publishableText)
        bubble.applyReview(reviewed)
        #expect(bubble.composeNote == reviewed.composeNote)
        #expect(bubble.reviewNotes.map(\.id) == ["composeNote"])
    }

    @Test("localhost for another service in environment: is caught; a URL a browser reads stays quiet")
    func environmentAddresses() async {
        let (wrong, _) = await review(compose("postgres://app:secret@localhost:5432/app")
            + "This compose file runs the API and its database.")
        #expect(wrong.composeNote?.contains("inside a container `localhost` is that container itself") == true)
        let browser = compose("postgres://app:secret@db:5432/app", extra: "      CORS_ORIGIN: http://localhost:8000\n")
        let (quiet, trace) = await review(browser + "This compose file runs the API and its database.")
        #expect(quiet.composeNote == nil)
        #expect(trace.outcome(for: .composeCheck) == .noOp(reason: "no claims about a compose project"))
    }

    @Test("depends_on said to wait for readiness, and a substitution misread, get notes")
    func statementsAndSubstitutions() async {
        let (ready, _) = await review(compose("postgres://db:5432/app")
            + "`depends_on` makes sure the database is ready before the API starts.")
        #expect(ready.composeNote?.contains("waits only for the dependency's container to start") == true)
        let tag = "```yaml\nservices:\n  db:\n    image: \"postgres:${PG_TAG-16}\"\n```\nIn `.env`:\n\n```env\nPG_TAG=\n```\n"
            + "Because `PG_TAG` is empty, `postgres:${PG_TAG-16}` becomes `postgres:16`."
        let (substituted, _) = await review(tag, messages: [user("Pin the Postgres tag with docker compose.")])
        #expect(substituted.composeNote?.contains("it gives `postgres:`") == true)
    }

    @Test("a later turn is judged against the earlier compose file and marked as said again")
    func historyIsReplayed() async {
        let messages = [user(question), assistant(wrongPort), user("Are you sure about the port?")]
        let (reviewed, trace) = await review("Yes: the `api` service connects to Postgres at `db:5433`.",
                                             messages: messages)
        #expect(reviewed.composeNote == "Compose check: " + portNote
            + " An earlier answer in this chat stated the same claim.")
        #expect(trace.outcome(for: .composeCheck).map { "\($0)" }?.contains("1 repeated") == true)
    }

    @Test("a correct answer and answers about other things stay quiet")
    func quiet() async {
        let fine = compose("postgres://app:secret@db:5432/app")
            + "The `api` service connects to Postgres at `db:5432`. From your laptop, open `localhost:5433`."
        let (held, heldTrace) = await review(fine)
        #expect(held.composeNote == nil)
        #expect(heldTrace.outcome(for: .composeCheck) == .noOp(reason: "2 claims checked, 2 hold"))
        for answer in ["In bash, `${NAME:-guest}` gives `guest` when `NAME` is unset.",
                       "In Kubernetes, a sidecar reaches the app on `localhost:8000`.",
                       "Jetpack Compose's `remember` keeps state across recompositions."] {
            // A question that does not name compose: the default one does, and makes the bash sentence a claim.
            let (none, noneTrace) = await review(answer, messages: [user("How does this work?")])
            #expect(none.composeNote == nil, "\(answer)")
            #expect(noneTrace.outcome(for: .composeCheck) == .noOp(reason: "no claims about a compose project"))
        }
    }

    @Test("a withheld answer is not checked")
    func withheldIsSkipped() async {
        let refusal = Refusal(stage: .guardrailOutput, headline: "Withheld", explanation: "x", recovery: nil)
        let withheld = AnswerReview(
            publishableText: "", wasModified: true, groundedFraction: nil, claimCount: 0, refusal: refusal
        )
        var trace = PipelineTrace()
        let result = await PostModelPipeline.checkCompose(withheld, messages: [user(question)], trace: &trace)
        #expect(result == withheld)
        #expect(trace.outcome(for: .composeCheck)
            == .skipped(reason: "the answer was withheld, so there is nothing to check"))
    }
}
