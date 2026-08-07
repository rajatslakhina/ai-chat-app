import CitationBindingKit
import Foundation
import GroundingKit
import GuardrailKit
import Testing
@testable import AIChatApp

/// The `citationBinding` stage, exercised through the real `PostModelPipeline`. The stage table
/// test only proves a case exists; a stage that is listed but never runs is exactly the gap this
/// suite is for.
@Suite("Citation binding stage")
struct CitationBindingStageTests {
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
        trace.records.first { $0.stage == .citationBinding }?.outcome
    }

    @Test("a cited answer binds to what it cited and the stage says so")
    func bindsCitedClaims() async {
        var trace = PipelineTrace()
        _ = await pipeline().review(
            answer: "The response cache is enabled by default [kb-cache].",
            sources: sources,
            trace: &trace
        )
        guard case .ran(let detail)? = outcome(in: trace) else {
            Issue.record("expected the stage to have run, got \(String(describing: outcome(in: trace)))")
            return
        }
        #expect(detail.contains("bound to a source the answer cited"))
    }

    /// The refusal this stage owns. A citation naming a document nobody retrieved is invented
    /// provenance — there is no version of that a reader can evaluate.
    @Test("an invented citation refuses with a headline, an explanation and a recovery")
    func refusesInventedProvenance() async {
        var trace = PipelineTrace()
        let review = await pipeline().review(
            answer: "The response cache is enabled by default [kb-nonexistent].",
            sources: sources,
            trace: &trace
        )
        guard case .refused(let refusal)? = outcome(in: trace) else {
            Issue.record("expected a refusal, got \(String(describing: outcome(in: trace)))")
            return
        }
        #expect(refusal.headline == "Answer cites a source that does not exist")
        #expect(refusal.explanation.contains("kb-nonexistent"))
        #expect(refusal.explanation.contains("never retrieved"))

        // The refusal must reach the user, not just the trace — the trace is what feeds the banner.
        #expect(review.refusal?.headline == refusal.headline)
        #expect(review.publishableText.isEmpty, "a fabricated provenance must not reach the screen")
    }

    /// An answer that cites nothing is ordinary rather than dishonest: this app asks for citations
    /// but cannot compel them. The binding is inferred, and the detail says it was inferred.
    @Test("an uncited answer is inferred and labelled as inferred")
    func labelsInferredBindings() async {
        var trace = PipelineTrace()
        _ = await pipeline().review(
            answer: "The response cache is enabled by default.",
            sources: sources,
            trace: &trace
        )
        guard case .ran(let detail)? = outcome(in: trace) else {
            Issue.record("expected the stage to have run")
            return
        }
        #expect(detail.contains("inferred from overlap alone"))
    }

    /// There is nothing a citation could name, and the stage says so rather than going unrecorded.
    @Test("the stage records a skip when there are no sources")
    func skipsWithoutSources() async {
        var trace = PipelineTrace()
        _ = await pipeline().review(answer: "The cache is warm.", sources: [], trace: &trace)
        guard case .skipped(let reason)? = outcome(in: trace) else {
            Issue.record("expected a skip, got \(String(describing: outcome(in: trace)))")
            return
        }
        #expect(reason.contains("nothing a citation could name"))
    }

    /// Connective prose asserts nothing a citation could support, so demanding one would be a
    /// false accusation — a no-op, not a refusal.
    ///
    /// `## Retry policy` is deliberately *not* the example here: it carries two topical terms
    /// (`retry`, `policy`) and so is checkable, which is the right call and was not the obvious one.
    @Test("an answer with nothing checkable is a no-op")
    func noOpsOnUncheckableProse() async {
        var trace = PipelineTrace()
        _ = await pipeline().review(answer: "There you have it.", sources: sources, trace: &trace)
        guard case .noOp(let reason)? = outcome(in: trace) else {
            Issue.record("expected a no-op, got \(String(describing: outcome(in: trace)))")
            return
        }
        #expect(reason.contains("citation could support"))
    }

    /// The stage runs on every verified turn, so a reader of Diagnostics never sees a gap where a
    /// wired stage should be.
    @Test("the stage records an outcome on every path through review")
    func alwaysRecords() async {
        let answers = [
            "The response cache is enabled by default [kb-cache].",
            "The response cache is enabled by default.",
            "There you have it."
        ]
        for answer in answers {
            var trace = PipelineTrace()
            _ = await pipeline().review(answer: answer, sources: sources, trace: &trace)
            #expect(outcome(in: trace) != nil, "no record for: \(answer)")
        }
    }

    /// The property the package exists for, asserted directly: the citation decides the binding,
    /// and an uncited source that aligns better does not get substituted for it.
    @Test("the citation wins over a better-aligned uncited source")
    func honoursTheCitationOverTheScore() throws {
        let evidence = try CitationBindingKit.EvidenceSet([
            CitationBindingKit.SourceDocument(
                id: CitationBindingKit.SourceID("kb-stream"),
                text: "Streaming responses are enabled for chat models."
            ),
            CitationBindingKit.SourceDocument(
                id: CitationBindingKit.SourceID("kb-cache"),
                text: "The response cache is enabled by default for streaming turns."
            )
        ])
        let binder = SynchronousCitationBinder(
            evidence: evidence,
            policy: PostModelPipeline.citationPolicy
        )
        let binding = binder.bind(
            CitedClaim(
                id: "c1",
                text: "Streaming is enabled by default",
                citations: [CitationBindingKit.SourceID("kb-stream")]
            )
        )
        #expect(binding.source() == CitationBindingKit.SourceID("kb-stream"))
        #expect(binding.basis() == .cited)
    }

    // MARK: - Paths that `review` cannot reach

    /// Builds a `GroundingReport` directly, so the stage's own defensive and reporting branches can
    /// be exercised without inventing a model answer that happens to produce them.
    private func verdict(
        id: String,
        text: String,
        citing citation: String,
        matched: String
    ) -> ClaimVerdict {
        ClaimVerdict(
            claim: GroundingKit.Claim(
                id: id,
                text: text,
                rawText: text,
                citations: [GroundingKit.SourceID(citation)],
                span: GroundingKit.TextSpan(offset: 0, length: text.count, text: text)
            ),
            level: .supported,
            support: SourceAssessment(
                sourceID: GroundingKit.SourceID(matched),
                score: 1,
                span: nil,
                conflict: nil
            ),
            citationIssues: []
        )
    }

    private func report(_ verdicts: [ClaimVerdict]) -> GroundingReport {
        GroundingReport(
            verdicts: verdicts,
            violations: [],
            decision: .accepted,
            usedSources: [],
            unusedSources: []
        )
    }

    /// Binding is local computation, so a throw here is a wiring fault rather than a network one —
    /// but it must still be reported instead of taking down a turn already paid for.
    @Test("a duplicate claim id is reported as a stage failure, not a crash")
    func reportsAWiringFault() async throws {
        let evidence = try GroundingKit.EvidenceSet(
            sources.map {
                GroundingKit.SourceDocument(
                    id: GroundingKit.SourceID($0.id),
                    title: $0.title,
                    text: $0.snippet
                )
            }
        )
        var trace = PipelineTrace()
        let duplicated = report([
            verdict(id: "c1", text: "The cache is enabled", citing: "kb-cache", matched: "kb-cache"),
            verdict(id: "c1", text: "The cache is shared", citing: "kb-share", matched: "kb-share")
        ])
        let refusal = await pipeline().bindCitations(
            of: duplicated,
            against: evidence,
            trace: &trace
        )

        #expect(refusal == nil, "a wiring fault must not refuse the answer")
        guard case .failed(let message)? = outcome(in: trace) else {
            Issue.record("expected a failure, got \(String(describing: outcome(in: trace)))")
            return
        }
        #expect(message.contains("duplicateClaimID"))
    }

    /// The divergence the package exists to report, named in the stage detail so it reaches
    /// Diagnostics rather than living only inside the binding report.
    @Test("a decisively stronger uncited source is named in the stage detail")
    func namesTheDivergenceInTheDetail() async throws {
        let evidence = try GroundingKit.EvidenceSet([
            GroundingKit.SourceDocument(
                id: GroundingKit.SourceID("kb-stream"),
                title: "kb-stream",
                text: "Streaming responses are enabled for chat models."
            ),
            GroundingKit.SourceDocument(
                id: GroundingKit.SourceID("kb-cache"),
                title: "kb-cache",
                text: "The response cache is enabled by default for streaming turns."
            )
        ])
        var trace = PipelineTrace()
        _ = await pipeline().bindCitations(
            of: report([
                verdict(
                    id: "c1",
                    text: "Streaming is enabled by default",
                    citing: "kb-stream",
                    matched: "kb-cache"
                )
            ]),
            against: evidence,
            trace: &trace
        )

        guard case .ran(let detail)? = outcome(in: trace) else {
            Issue.record("expected the stage to have run")
            return
        }
        #expect(detail.contains("an uncited one beats"))
        #expect(detail.contains("c1"))
    }
}
