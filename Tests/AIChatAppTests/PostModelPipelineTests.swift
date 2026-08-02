import Foundation
import GroundingKit
import GuardrailKit
import Testing
import TraceKit
@testable import AIChatApp

private func makeReview(contentRules: [any ContentPolicyRule] = []) -> PostModelPipeline {
    PostModelPipeline(
        guardrail: GuardrailPipeline(policy: GuardrailPolicy(contentPolicyRules: contentRules))
    )
}

private func source(
    id: String = "doc-1",
    title: String = "notes.md",
    text: String
) -> RetrievedSource {
    RetrievedSource(id: id, title: title, snippet: text, relevancePercent: 90)
}

private func run(
    _ pipeline: PostModelPipeline,
    answer: String,
    sources: [RetrievedSource] = []
) async -> (AnswerReview, PipelineTrace) {
    var trace = PipelineTrace()
    let review = await pipeline.review(answer: answer, sources: sources, trace: &trace)
    return (review, trace)
}

@Suite("Post-model — output guardrail")
struct OutputGuardrailTests {
    @Test("a clean answer passes through untouched")
    func cleanAnswer() async {
        let (review, trace) = await run(makeReview(), answer: "Paris is the capital of France.")
        #expect(review.publishableText == "Paris is the capital of France.")
        #expect(!review.wasModified)
        #expect(review.refusal == nil)
        #expect(trace.outcome(for: .guardrailOutput)?.summary.contains("no findings") == true)
    }

    /// The model can emit PII the user never typed — a hallucinated address, or a real one
    /// recalled from training data. Screening only the input would miss all of it.
    @Test("PII the model produced is redacted from what the user sees")
    func redactsModelEmittedPII() async {
        let answer = "Sure — you can reach the team at support@example.com any time."
        let (review, trace) = await run(makeReview(), answer: answer)

        #expect(review.wasModified)
        #expect(!review.publishableText.contains("support@example.com"))
        #expect(review.publishableText.contains("REDACTED"))
        #expect(trace.outcome(for: .guardrailOutput)?.summary.contains("redacted") == true)
    }

    @Test("a blocked answer is withheld entirely and refuses with a reason")
    func blockedAnswerIsWithheld() async throws {
        let rule = BannedPhraseRule(
            phrases: [BannedPhraseRule.Phrase("launch codes", severity: .block)]
        )
        let (review, trace) = await run(
            makeReview(contentRules: [rule]),
            answer: "The launch codes are 0000."
        )

        let refusal = try #require(review.refusal)
        #expect(refusal.stage == .guardrailOutput)
        #expect(!refusal.explanation.isEmpty)
        #expect(review.publishableText.isEmpty, "a blocked answer must not reach the screen")
        #expect(trace.outcome(for: .guardrailOutput)?.isRefusal == true)
        // The span still closes on the refusal path, so a withheld answer is still traced.
        #expect(trace.outcome(for: .tracing) != nil)
    }
}

@Suite("Post-model — grounding")
struct GroundingStageTests {
    /// Reporting "0% grounded" for an answer with nothing to check against would be a claim the
    /// app cannot support. Unchecked and ungrounded are different facts.
    @Test("no sources means grounding is skipped, not failed and not scored zero")
    func noSourcesSkips() async {
        let (review, trace) = await run(makeReview(), answer: "Swift actors isolate state.")
        #expect(review.groundedFraction == nil)
        #expect(review.claimCount == 0)
        #expect(trace.outcome(for: .grounding)?.summary.contains("no retrieved sources") == true)
    }

    @Test("an answer supported by its source is scored and reported")
    func supportedAnswerScores() async throws {
        let evidence = source(
            text: "Swift actors serialize access to mutable state and prevent data races."
        )
        let (review, trace) = await run(
            makeReview(),
            answer: "Swift actors serialize access to mutable state.",
            sources: [evidence]
        )

        #expect(review.claimCount > 0, "the answer has at least one claim to check")
        let fraction = try #require(review.groundedFraction)
        #expect(fraction > 0, "a claim quoting its source must score above zero")
        #expect(trace.outcome(for: .grounding)?.summary.contains("supported by a source") == true)
    }

    @Test("an answer with nothing to do with its source scores low rather than erroring")
    func unsupportedAnswerScoresLow() async throws {
        let evidence = source(text: "The build pipeline runs on macOS 26 with Xcode 26.3.")
        let (review, _) = await run(
            makeReview(),
            answer: "Octopuses have three hearts and blue blood.",
            sources: [evidence]
        )

        let fraction = try #require(review.groundedFraction)
        #expect(fraction < 1.0, "an unrelated claim must not read as fully supported")
        #expect(review.refusal == nil, "low grounding annotates; it does not refuse the turn")
    }

    @Test("grounding runs after redaction, so it verifies the text the user will see")
    func groundingSeesRedactedText() async {
        let evidence = source(text: "Contact details are withheld in published answers.")
        let (review, trace) = await run(
            makeReview(),
            answer: "Write to me at hello@example.com.",
            sources: [evidence]
        )
        #expect(review.wasModified)
        #expect(!review.publishableText.contains("hello@example.com"))
        #expect(trace.outcome(for: .grounding)?.isFailure == false)
    }
}

@Suite("Post-model — tracing")
struct TracingStageTests {
    @Test("every reviewed answer closes a span")
    func spansClose() async {
        let pipeline = makeReview()
        let (_, first) = await run(pipeline, answer: "one")
        #expect(first.outcome(for: .tracing)?.summary.contains("1 span") == true)

        let (_, second) = await run(pipeline, answer: "two")
        #expect(
            second.outcome(for: .tracing)?.summary.contains("2 span") == true,
            "the count accumulates across turns rather than resetting"
        )
    }

    @Test("all three post-model stages report on an ordinary answer")
    func allStagesReport() async {
        let evidence = source(text: "Actors serialize access to state.")
        let (_, trace) = await run(
            makeReview(),
            answer: "Actors serialize access to state.",
            sources: [evidence]
        )
        for stage in [PipelineStage.guardrailOutput, .grounding, .tracing] {
            #expect(trace.outcome(for: stage) != nil, "\(stage.rawValue) never reported")
        }
    }
}
