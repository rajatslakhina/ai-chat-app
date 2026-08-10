import ClaimDecontextualizerKit
import Foundation
import GroundingKit
import GuardrailKit
import Testing
@testable import AIChatApp

/// The `claimDecontextualization` stage, exercised through the real `PostModelPipeline`.
///
/// The stage-table test only proves a case exists. This suite is what proves the case is reached,
/// which is the gap that test cannot see.
@Suite("Claim decontextualization stage")
struct DecontextualizationStageTests {
    private func pipeline() -> PostModelPipeline {
        PostModelPipeline(guardrail: GuardrailPipeline(policy: GuardrailPolicy()))
    }

    private func source(_ id: String, _ snippet: String) -> RetrievedSource {
        RetrievedSource(id: id, title: id, snippet: snippet, relevancePercent: 80)
    }

    private var sources: [RetrievedSource] {
        [
            source("kb-cache", "The response cache is enabled by default."),
            source("kb-share", "The response cache is shared across sessions.")
        ]
    }

    private func outcome(in trace: PipelineTrace) -> StageOutcome? {
        trace.records.first { $0.stage == .claimDecontextualization }?.outcome
    }

    @Test("an answer whose sentences already stand alone is a no-op, not a silent pass")
    func standaloneAnswerIsNoOp() async {
        var trace = PipelineTrace()
        _ = await pipeline().review(
            answer: "The response cache is enabled by default [kb-cache].",
            sources: sources,
            trace: &trace
        )
        guard case .noOp(let reason)? = outcome(in: trace) else {
            Issue.record("expected a no-op, got \(String(describing: outcome(in: trace)))")
            return
        }
        #expect(reason.contains("stood on its own"))
    }

    @Test("a pronoun with a decisive antecedent is resolved and the stage reports the rate")
    func resolvesDecisiveAntecedent() async {
        var trace = PipelineTrace()
        _ = await pipeline().review(
            answer: "The response cache is enabled by default [kb-cache]. "
                + "It is shared across sessions [kb-share].",
            sources: sources,
            trace: &trace
        )
        guard case .ran(let detail)? = outcome(in: trace) else {
            Issue.record("expected the stage to have run, got \(String(describing: outcome(in: trace)))")
            return
        }
        #expect(detail.contains("rewritten to stand alone"))
        #expect(detail.contains("resolution rate"))
    }

    @Test("the stage is skipped, with a reason, when there was nothing to ground against")
    func skippedWithoutSources() async {
        var trace = PipelineTrace()
        _ = await pipeline().review(answer: "The cache is on.", sources: [], trace: &trace)
        guard case .skipped(let reason)? = outcome(in: trace) else {
            Issue.record("expected a skip, got \(String(describing: outcome(in: trace)))")
            return
        }
        #expect(reason.contains("no verdict can overclaim"))
    }

    // MARK: - The refusal this stage owns

    /// A claim nobody could interpret, counted inside the verified total, is the app asserting in
    /// its own voice that it checked something it could not read.
    @Test("an unreadable claim that grounding vouched for refuses, with all three fields filled in")
    func refusesVouchedUnreadableClaim() {
        guard let refusal = PostModelPipeline.refusalForVouched(["c2"], claims: 3) else {
            Issue.record("expected a refusal")
            return
        }
        #expect(refusal.stage == .claimDecontextualization)
        #expect(refusal.headline == "Answer counts an unreadable statement as verified")
        #expect(refusal.explanation.contains("c2"))
        #expect(refusal.explanation.contains("1 of 3"))
        #expect(refusal.recovery != nil, "a refusal the user cannot act on is barely better than silence")
        #expect(refusal.recoveryTitle == "Try again")
    }

    @Test("nothing vouched for means nothing to refuse over")
    func noRefusalWithoutVouchedClaims() {
        #expect(PostModelPipeline.refusalForVouched([], claims: 3) == nil)
    }

    /// The same refusal, reached through a real send rather than by calling the builder.
    ///
    /// The fixture is the exact shape the gate exists for: a plural pronoun whose referent is only
    /// implied, in a corpus that contains a passage matching its wording. Grounding scores it
    /// `supported`; the resolver cannot say what "they" are. Without this stage the answer ships
    /// with that claim counted inside "N of M verified".
    @Test("the refusal reaches the user, and the answer does not")
    func refusalReachesTheUser() async {
        var trace = PipelineTrace()
        let review = await pipeline().review(
            answer: "The response cache is enabled by default. They expire after an hour.",
            sources: sources + [source("kb-expire", "They expire after an hour.")],
            trace: &trace
        )
        guard case .refused(let traced)? = outcome(in: trace) else {
            Issue.record("expected a refusal, got \(String(describing: outcome(in: trace)))")
            return
        }
        #expect(traced.stage == .claimDecontextualization)
        // Asserted on the review as well as the trace: the trace feeds Diagnostics, the review
        // feeds the banner, and a refusal that reaches only one of them reaches no user.
        #expect(review.refusal == traced)
        #expect(review.publishableText.isEmpty, "the answer must not ship alongside its own refusal")
        #expect(trace.refusal == traced)
    }

    @Test("an answer with no checkable claim is a no-op naming that, not a silent skip")
    func noClaimsIsNoOp() async {
        var trace = PipelineTrace()
        _ = await pipeline().review(answer: "Sure.", sources: sources, trace: &trace)
        guard case .noOp(let reason)? = outcome(in: trace) else {
            Issue.record("expected a no-op, got \(String(describing: outcome(in: trace)))")
            return
        }
        #expect(reason.contains("nothing to make standalone") || reason.contains("stood on its own"))
    }

    /// The narrowness is the design. An unresolvable claim grounding called unsupported overclaims
    /// nothing, so it must not fire the gate — a gate that fires on the ordinary case gets removed.
    @Test("only a supported verdict counts as vouched for")
    func onlySupportedCountsAsVouched() async throws {
        let report = try await GroundingVerifier().verify(
            answer: "The response cache is enabled by default. Nothing here matches any source.",
            against: try EvidenceSet(sources.map {
                SourceDocument(id: SourceID($0.id), title: $0.title, text: $0.snippet)
            }),
            policy: try GroundingPolicy(disposition: .annotate),
            at: 1
        )
        #expect(report.verdicts.map(\.level).contains(.supported), "fixture needs a supported claim")

        let supported = report.verdicts.indices.filter { report.verdicts[$0].level == .supported }
        let others = report.verdicts.indices.filter { report.verdicts[$0].level != .supported }
        #expect(!PostModelPipeline.vouchedFor(Array(supported), in: report).isEmpty)
        #expect(PostModelPipeline.vouchedFor(Array(others), in: report).isEmpty)
        #expect(PostModelPipeline.vouchedFor([99], in: report).isEmpty, "an index past the end is not a claim")
    }

    // MARK: - What the stage does with input a segmenter should never produce

    /// A real `GroundingReport` never carries these, which is exactly why they are worth asserting:
    /// the branches are unreachable through a send, so without a test their behaviour is a guess.
    private func groundedReport() async throws -> GroundingReport {
        try await GroundingVerifier().verify(
            answer: "The response cache is enabled by default.",
            against: try EvidenceSet(sources.map {
                SourceDocument(id: SourceID($0.id), title: $0.title, text: $0.snippet)
            }),
            policy: try GroundingPolicy(disposition: .annotate),
            at: 1
        )
    }

    @Test("no claims at all is a no-op that names the reason")
    func emptyClaimListIsNoOp() async throws {
        var trace = PipelineTrace()
        let refusal = await pipeline().checkDecontextualization(
            claims: [], against: try await groundedReport(), trace: &trace
        )
        #expect(refusal == nil)
        guard case .noOp(let reason)? = outcome(in: trace) else {
            Issue.record("expected a no-op, got \(String(describing: outcome(in: trace)))")
            return
        }
        #expect(reason.contains("grounding produced no claims"))
    }

    /// A blank claim is a wiring fault, not a model failure, so it is reported rather than allowed
    /// to look like a stage that ran and found nothing.
    @Test("a blank claim fails the stage rather than passing silently")
    func blankClaimFailsTheStage() async throws {
        var trace = PipelineTrace()
        let refusal = await pipeline().checkDecontextualization(
            claims: ["   "], against: try await groundedReport(), trace: &trace
        )
        #expect(refusal == nil, "a wiring fault is not a refusal the user can act on")
        guard case .failed(let message)? = outcome(in: trace) else {
            Issue.record("expected a failure, got \(String(describing: outcome(in: trace)))")
            return
        }
        #expect(message.contains("blankSentence"))
    }

    // MARK: - Reporting

    @Test("the detail line separates what was fixed from what was left alone")
    func detailSeparatesResolvedFromRefused() throws {
        let discourse = try Discourse([
            "The response cache is enabled by default.",
            "It is shared across sessions.",
            "They expire after an hour."
        ])
        let resolution = DecontextualizationEngine(
            policy: PostModelPipeline.decontextualizationPolicy
        ).report(for: discourse)
        let unresolved = PostModelPipeline.unresolvedIndices(in: resolution)

        #expect(unresolved == [2], "the plural pronoun has no antecedent that agrees with it")
        let detail = PostModelPipeline.detail(for: resolution, unresolved: unresolved)
        #expect(detail.contains("rewritten to stand alone"))
        #expect(detail.contains("no antecedent decisive enough"))
        #expect(detail.contains("resolution rate 50%"))
    }

    @Test("a passage that needed no work reports no rate rather than a perfect one")
    func noRateWhenNothingNeededResolving() throws {
        let resolution = DecontextualizationEngine(
            policy: PostModelPipeline.decontextualizationPolicy
        ).report(for: try Discourse(["The response cache is enabled by default."]))
        #expect(PostModelPipeline.unresolvedIndices(in: resolution).isEmpty)
        #expect(resolution.resolutionRate() == nil)
        #expect(!PostModelPipeline.detail(for: resolution, unresolved: []).contains("resolution rate"))
    }

    @Test("this app resolves leniently, and the policy says why in the type rather than a comment")
    func policyIsLenient() {
        #expect(PostModelPipeline.decontextualizationPolicy == .lenient)
        #expect(PostModelPipeline.decontextualizationPolicy.resolvesDefiniteDescriptions == false)
    }
}
