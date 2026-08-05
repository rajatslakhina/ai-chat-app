import ClaimSegmenterKit
import Foundation
import GroundingKit
import GuardrailKit
import Testing
@testable import AIChatApp

/// The `claimSegmentation` stage, exercised through the real `PostModelPipeline`. The stage table
/// test only proves a case exists; a stage that is listed but never runs is exactly the gap this
/// suite is for.
@Suite("Claim segmentation stage")
struct ClaimSegmentationStageTests {
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

    @Test("the stage records an outcome on the verified path")
    func recordsWhenGroundingRuns() async {
        var trace = PipelineTrace()
        _ = await pipeline().review(
            answer: "The response cache is enabled by default, but it is not shared across sessions.",
            sources: sources,
            trace: &trace
        )
        let record = trace.records.first { $0.stage == .claimSegmentation }
        #expect(record != nil, "a stage with no record is indistinguishable from one not wired in")
        if case .ran(let detail)? = record?.outcome {
            #expect(detail.contains("2 claim"))
            #expect(detail.contains("subject carried in"))
        } else {
            Issue.record("expected the stage to have run, got \(String(describing: record?.outcome))")
        }
    }

    /// Cutting an answer up buys nothing when there is nothing to check it against, and the stage
    /// says so rather than going unrecorded.
    @Test("the stage records a skip when there are no sources")
    func recordsWhenThereIsNothingToVerifyAgainst() async {
        var trace = PipelineTrace()
        _ = await pipeline().review(answer: "The cache is warm.", sources: [], trace: &trace)
        let record = trace.records.first { $0.stage == .claimSegmentation }
        guard case .skipped? = record?.outcome else {
            Issue.record("expected a skip, got \(String(describing: record?.outcome))")
            return
        }
    }

    /// A refused split is reported, not silently absent. A reader comparing two turns needs to
    /// tell "this sentence could not be cut safely" from "this sentence had nothing to cut".
    @Test("a refused split is named in the stage detail")
    func reportsRefusedSplits() async {
        var trace = PipelineTrace()
        _ = await pipeline().review(
            answer: "The response cache is fast, and cheap.",
            sources: sources,
            trace: &trace
        )
        guard case .ran(let detail)? = trace.records.first(where: { $0.stage == .claimSegmentation })?
            .outcome else {
            Issue.record("expected the stage to have run")
            return
        }
        #expect(detail.contains("1 split(s) refused"))
        #expect(!detail.contains("carried in"), "nothing was repaired, so nothing should claim to be")
    }

    /// A sentence with no coordinator needs no repair and no refusal, and the detail should say
    /// neither rather than padding itself with zeroes.
    @Test("a plain sentence reports claims and nothing else")
    func reportsAPlainSentence() async {
        var trace = PipelineTrace()
        _ = await pipeline().review(
            answer: "The response cache is enabled by default.",
            sources: sources,
            trace: &trace
        )
        guard case .ran(let detail)? = trace.records.first(where: { $0.stage == .claimSegmentation })?
            .outcome else {
            Issue.record("expected the stage to have run")
            return
        }
        #expect(detail.contains("1 claim(s)"))
        #expect(!detail.contains("refused"))
        #expect(!detail.contains("carried in"))
    }

    /// An answer with nothing checkable is a no-op, not a failure — and grounding still runs,
    /// because the bridge hands it sentence boundaries rather than an empty list.
    @Test("an answer with no checkable claim is a no-op and grounding still runs")
    func recordsANoOp() async {
        var trace = PipelineTrace()
        _ = await pipeline().review(answer: "## Retry policy", sources: sources, trace: &trace)
        guard case .noOp(let reason)? = trace.records.first(where: { $0.stage == .claimSegmentation })?
            .outcome else {
            Issue.record("expected a no-op")
            return
        }
        #expect(reason.contains("sentence segmenter"))
        #expect(trace.records.contains { $0.stage == .grounding && !$0.outcome.isFailure })
    }

    /// The point of the stage: grounding must see two claims where it used to see one, so a
    /// sentence carrying one true and one false assertion cannot come back with a single verdict.
    @Test("grounding judges clauses, not sentences")
    func groundingSeesClauses() async throws {
        let answer = "The response cache is enabled by default, but it is not shared across sessions."
        let evidence = try EvidenceSet(
            sources.map { SourceDocument(id: SourceID($0.id), title: $0.title, text: $0.snippet) }
        )
        let coarse = try await GroundingVerifier()
            .verify(answer: answer, against: evidence, policy: GroundingPolicy(), at: 1)
        let fine = try await GroundingVerifier(segmenter: ClaimSegmenterBridge())
            .verify(answer: answer, against: evidence, policy: GroundingPolicy(), at: 1)
        #expect(coarse.verdicts.count == 1)
        #expect(fine.verdicts.count == 2)
        #expect(fine.verdicts[0].level == .supported)
        #expect(fine.verdicts[1].level == .contradicted)
    }

    /// An empty claim list would make a verifier report a clean sweep over nothing. The bridge
    /// stands aside to the coarser segmenter instead, so the answer is still checked.
    @Test("an answer with nothing checkable still reaches a segmenter")
    func fallsBackRatherThanReturningNothing() {
        let bridge = ClaimSegmenterBridge()
        #expect(bridge.claims(in: "# Heading").count == 1)
        #expect(bridge.claims(in: "The cache is warm.").count == 1)
    }

    /// Citation extraction stayed with `GroundingKit`; only the boundaries changed hands.
    @Test("citations survive the finer cut and land on the clause that made them")
    func citationsFollowTheClause() {
        let claims = ClaimSegmenterBridge().claims(
            in: "The cache is enabled [kb-cache], but it is not shared [kb-share]."
        )
        #expect(claims.count == 2)
        #expect(claims[0].citations.map(\.rawValue) == ["kb-cache"])
        #expect(claims[1].citations.map(\.rawValue) == ["kb-share"])
        #expect(claims[1].text.hasPrefix("The cache is not shared"))
    }
}
