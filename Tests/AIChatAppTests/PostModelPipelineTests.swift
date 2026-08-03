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

@Suite("Post-model — claim consistency")
struct ClaimConsistencyStageTests {
    /// The case grounding structurally cannot reach: no negation, no differing numeral, and the
    /// answer still says the opposite of the passage it was drawn from.
    @Test("a quantifier widened past the source refuses instead of publishing")
    func widenedQuantifierRefuses() async throws {
        let (review, trace) = await run(
            makeReview(),
            answer: "All providers expose a token counting endpoint.",
            sources: [source(text: "Some providers expose a token counting endpoint.")]
        )

        let refusal = try #require(review.refusal)
        #expect(refusal.stage == .claimConsistency)
        #expect(refusal.headline == "Answer contradicts its own sources")
        #expect(refusal.explanation.contains("quantifier"))
        #expect(refusal.recoveryTitle == "Try again")
        #expect(review.publishableText.isEmpty, "a contradicted answer must not reach the screen")
        #expect(trace.outcome(for: .claimConsistency)?.isRefusal == true)
        #expect(trace.refusal == refusal, "the refusal has to survive the trace to reach the UI")
    }

    @Test("one member of a mutually exclusive pair swapped for the other refuses")
    func swappedExclusiveValueRefuses() async throws {
        let (review, _) = await run(
            makeReview(),
            answer: "Background refresh is disabled on watchOS.",
            sources: [source(text: "Background refresh is enabled on watchOS.")]
        )
        let refusal = try #require(review.refusal)
        #expect(refusal.explanation.contains("disabled"))
        #expect(refusal.explanation.contains("enabled"))
    }

    /// Grounding compares numeric terms as written, so it reads this as a conflict. It is a
    /// satisfied bound, and publishing a refusal for it would be a false alarm.
    @Test("a satisfied bound is agreement, not a contradiction")
    func satisfiedBoundIsNotAContradiction() async {
        let (review, trace) = await run(
            makeReview(),
            answer: "The client retries 5 times before failing.",
            sources: [source(text: "The client retries at least 3 times before failing.")]
        )
        #expect(review.refusal == nil)
        #expect(trace.outcome(for: .claimConsistency)?.summary.contains("positively agree") == true)
    }

    /// Absence of contradiction is not agreement, and the trace has to say which one it was.
    @Test("claims with nothing checkable in them record a no-op, not a pass")
    func unreadableClaimsAreNotAPass() async {
        let (review, trace) = await run(
            makeReview(),
            answer: "The router prefers whichever provider costs least.",
            sources: [source(text: "Routing selects a provider by cost and capability.")]
        )
        #expect(review.refusal == nil)
        #expect(trace.outcome(for: .claimConsistency)?.summary.contains("nothing") == false)
        let summary = trace.outcome(for: .claimConsistency)?.summary ?? ""
        #expect(summary.contains("no negation, number, quantifier or version"))
    }

    /// A checker that cannot run must not imply the answer was checked and found consistent.
    @Test("a source with no text is reported as a failure, not as agreement")
    func emptySourceIsAFailure() async {
        let (review, trace) = await run(
            makeReview(),
            answer: "All providers expose a token counting endpoint.",
            sources: [source(text: "")]
        )
        #expect(review.refusal == nil)
        #expect(trace.outcome(for: .claimConsistency)?.isFailure == true)
    }

    @Test("with no sources the stage is skipped rather than silently passing")
    func noSourcesIsSkipped() async {
        let (_, trace) = await run(makeReview(), answer: "Paris is the capital of France.")
        #expect(trace.outcome(for: .claimConsistency)?.summary.contains("nothing was grounded") == true)
    }

    /// A pipeline built without a checker must say so. A stage that quietly did not run reads
    /// exactly like a stage that ran and found nothing.
    @Test("an unconfigured checker records skipped rather than nothing at all")
    func unconfiguredCheckerIsVisible() async {
        let pipeline = PostModelPipeline(
            guardrail: GuardrailPipeline(policy: GuardrailPolicy()),
            consistencyChecker: nil
        )
        let (review, trace) = await run(
            pipeline,
            answer: "All providers expose a token counting endpoint.",
            sources: [source(text: "Some providers expose a token counting endpoint.")]
        )
        #expect(review.refusal == nil)
        #expect(trace.outcome(for: .claimConsistency)?.summary == "no consistency checker configured")
    }
}
