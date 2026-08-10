import ClaimConsistencyKit
import ClaimSegmenterKit
import Foundation
import GroundingKit
import GuardrailKit
import TraceKit

/// What the post-model stages decided about an answer.
struct AnswerReview: Sendable, Equatable {
    /// The text to actually show. Differs from the model's output when the guardrail redacted it
    /// or grounding stripped an unsupported claim.
    let publishableText: String
    /// True when the text on screen is not what the model produced.
    let wasModified: Bool
    /// Fraction of claims a source supported, 0...1, when grounding ran.
    let groundedFraction: Double?
    /// Claims checked, so the UI can say "3 of 4 verified" rather than a bare percentage.
    let claimCount: Int
    /// A refusal that must reach the user instead of the answer.
    let refusal: Refusal?
}

/// Runs everything that happens after the model answers.
///
/// Split from `TurnExecutor` because these stages judge an answer that already exists and has
/// already been paid for. Nothing here can save money; what it can do is stop a bad answer from
/// being shown as if it were a good one.
actor PostModelPipeline {
    private let guardrail: GuardrailPipeline
    private let verifier: GroundingVerifier
    /// Optional so a caller can build a pipeline without this stage. It is never silently
    /// absent: an unconfigured checker records `.skipped`, because a stage that quietly did
    /// not run reads exactly like a stage that ran and found nothing.
    /// Internal rather than private: the consistency stage lives in
    /// `PostModelPipeline+Consistency.swift`, and Swift's `private` is file-scoped.
    let consistencyChecker: ConsistencyChecker?
    private let tracer: Tracer
    private var tick = 0
    /// Spans this pipeline has closed. Counted here rather than read back from `Tracer`, whose
    /// only accessor wants a root id we do not hold — inventing one would report zero forever.
    private var closedSpans = 0

    init(
        guardrail: GuardrailPipeline,
        verifier: GroundingVerifier = GroundingVerifier(segmenter: ClaimSegmenterBridge()),
        consistencyChecker: ConsistencyChecker? = try? ConsistencyChecker(),
        tracer: Tracer = Tracer()
    ) {
        self.guardrail = guardrail
        self.verifier = verifier
        self.consistencyChecker = consistencyChecker
        self.tracer = tracer
    }

    /// Internal for the same reason as `consistencyChecker` — the stages that need a tick
    /// now live in sibling files.
    func nextTick() -> Int {
        tick += 1
        return tick
    }

    /// Screens, verifies and records one answer.
    ///
    /// `sources` are the passages retrieval injected. When there are none, grounding is skipped
    /// rather than run against nothing — an answer with no sources to check is not "ungrounded",
    /// it is unchecked, and reporting 0% grounded would be a claim the app cannot support.
    func review(
        answer: String,
        sources: [RetrievedSource],
        trace: inout PipelineTrace
    ) async -> AnswerReview {
        let spanID = await tracer.startSpan(
            name: "post-model",
            attributes: ["sources": "\(sources.count)"]
        )

        // 1. Output guardrail — the model can emit PII the user never typed.
        //
        // A `switch` rather than `guard case`: `ScreenOutcome` has exactly two cases, and the
        // `guard`-shaped version needed a second `guard` whose else-branch no answer could reach.
        var text: String
        var modified: Bool
        switch await screenOutput(answer, trace: &trace) {
        case let .passed(screened, wasRedacted):
            text = screened
            modified = wasRedacted
        case let .refused(refusal):
            await close(spanID, status: .error(refusal.explanation), trace: &trace)
            return AnswerReview(
                publishableText: "",
                wasModified: true,
                groundedFraction: nil,
                claimCount: 0,
                refusal: refusal
            )
        }

        // 2. Grounding, then whether the grounded claims actually agree with what they matched.
        let outcome = await ground(text: text, sources: sources, trace: &trace)
        if let stripped = outcome.text, stripped != text {
            text = stripped
            modified = true
        }
        // A refusal here outranks the answer: the text exists and is wrong about its own
        // sources, so publishing it with a warning would still put it on screen as prose.
        if let refusal = outcome.refusal {
            await close(spanID, status: .error(refusal.explanation), trace: &trace)
            return AnswerReview(
                publishableText: "",
                wasModified: true,
                groundedFraction: outcome.fraction,
                claimCount: outcome.claims,
                refusal: refusal
            )
        }

        await close(spanID, status: .ok, trace: &trace)
        return AnswerReview(
            publishableText: text,
            wasModified: modified,
            groundedFraction: outcome.fraction,
            claimCount: outcome.claims,
            refusal: nil
        )
    }

    /// Grounding is only meaningful when there were sources to check against.
    ///
    /// An answer with no sources is not "ungrounded", it is unchecked, and reporting 0% grounded
    /// would be a claim the app cannot support. Both stages say so explicitly rather than being
    /// absent from the trace, because an absent stage and a stage that found nothing look the
    /// same to a reader of Diagnostics.
    private func ground(
        text: String,
        sources: [RetrievedSource],
        trace: inout PipelineTrace
    ) async -> VerifyOutcome {
        guard !sources.isEmpty else {
            trace.record(.grounding, .skipped(reason: "no retrieved sources to verify against"))
            trace.record(
                .claimSegmentation,
                .skipped(reason: "nothing to verify against, so cutting the answer up buys nothing")
            )
            trace.record(.claimConsistency, .skipped(reason: "nothing was grounded, so nothing to compare"))
            trace.record(
                .citationBinding,
                .skipped(reason: "no retrieved sources, so there is nothing a citation could name")
            )
            trace.record(
                .claimDecontextualization,
                .skipped(reason: "nothing was grounded, so no verdict can overclaim")
            )
            return VerifyOutcome(text: nil, fraction: nil, claims: 0, refusal: nil)
        }
        return await verify(text: text, sources: sources, trace: &trace)
    }

    private enum ScreenOutcome {
        case passed(text: String, modified: Bool)
        case refused(Refusal)
    }

    private func screenOutput(
        _ answer: String,
        trace: inout PipelineTrace
    ) async -> ScreenOutcome {
        let screened = await guardrail.screenResponse(answer)
        switch screened.verdict {
        case .allow:
            trace.record(.guardrailOutput, .noOp(reason: "no findings"))
            return .passed(text: answer, modified: false)
        case .redacted:
            trace.record(
                .guardrailOutput,
                .ran(detail: "redacted \(screened.findings.count) span(s) from the answer")
            )
            return .passed(text: screened.sanitizedText, modified: true)
        case let .blocked(reason):
            let refusal = Refusal(
                stage: .guardrailOutput,
                headline: "Answer withheld",
                explanation: reason,
                recovery: nil
            )
            trace.record(.guardrailOutput, .refused(refusal))
            return .refused(refusal)
        }
    }

    private func close(
        _ spanID: UUID,
        status: SpanStatus,
        trace: inout PipelineTrace
    ) async {
        await tracer.endSpan(spanID, status: status)
        closedSpans += 1
        trace.record(.tracing, .ran(detail: "\(closedSpans) span(s) recorded this session"))
    }

    private struct VerifyOutcome {
        var text: String?
        var fraction: Double?
        var claims: Int
        var refusal: Refusal?
    }

    private func verify(
        text: String,
        sources: [RetrievedSource],
        trace: inout PipelineTrace
    ) async -> VerifyOutcome {
        do {
            let evidence = try EvidenceSet(
                sources.map {
                    SourceDocument(id: SourceID($0.id), title: $0.title, text: $0.snippet)
                }
            )
            // `.annotate` rather than `.refuse`: an unsupported sentence in an otherwise useful
            // answer is worth flagging, not worth throwing the whole answer away. A stricter
            // deployment can raise this to stripping.
            let policy = try GroundingPolicy(disposition: .annotate)
            let report = try await verifier.verify(
                answer: text,
                against: evidence,
                policy: policy,
                at: nextTick()
            )
            recordSegmentation(of: text, trace: &trace)
            let grounded = report.groundedFraction()
            let total = report.claimCount()
            let supported = Int((grounded * Double(total)).rounded())
            trace.record(
                .grounding,
                .ran(detail: "\(supported) of \(total) claim(s) supported by a source")
            )
            return await judge(report, against: evidence, grounded: grounded, total: total, trace: &trace)
        } catch {
            // A verifier that cannot run must not silently imply the answer was checked.
            trace.record(.grounding, .failed(message: "\(error)"))
            trace.record(.claimSegmentation, .skipped(reason: "grounding never ran, so nothing was cut"))
            trace.record(.claimConsistency, .skipped(reason: "grounding produced no claim/source pairs"))
            trace.record(
                .citationBinding,
                .skipped(reason: "grounding never ran, so there are no claims to attribute")
            )
            trace.record(
                .claimDecontextualization,
                .skipped(reason: "grounding never ran, so there are no claims to make standalone")
            )
            return VerifyOutcome(text: nil, fraction: nil, claims: 0, refusal: nil)
        }
    }

    /// The three questions asked of an answer grounding has already scored, in the order that
    /// makes each one worth asking.
    ///
    /// Attribution first: a claim credited to a document nobody retrieved is not worth asking
    /// anything else about. Readability second: whether a claim *agrees* with a passage assumes the
    /// claim says something, and one with no subject does not. Agreement last, on what survives.
    private func judge(
        _ report: GroundingReport,
        against evidence: EvidenceSet,
        grounded: Double,
        total: Int,
        trace: inout PipelineTrace
    ) async -> VerifyOutcome {
        if let refusal = bindCitations(of: report, against: evidence, trace: &trace) {
            return VerifyOutcome(text: nil, fraction: grounded, claims: total, refusal: refusal)
        }
        if let refusal = checkDecontextualization(of: report, trace: &trace) {
            return VerifyOutcome(text: nil, fraction: grounded, claims: total, refusal: refusal)
        }
        let refusal = await checkConsistency(of: report, against: evidence, trace: &trace)
        return VerifyOutcome(
            text: report.decision.publishableAnswer(),
            fraction: grounded,
            claims: total,
            refusal: refusal
        )
    }

    /// Records what the segmenter did to this answer.
    ///
    /// The work is repeated rather than threaded out of `ClaimSegmenterBridge`: segmentation is a
    /// pure function of the text and the policy, so the two passes cannot disagree, and one extra
    /// walk over a chat reply is not a cost worth an escape hatch through a `Sendable` protocol
    /// method that has nowhere to put one.
    ///
    /// This stage has no refusal, and that is deliberate rather than missing. Deciding where a
    /// claim ends is not a policy question — it has no opinion about whether the answer is any
    /// good. When it cannot improve on sentence boundaries it says so and grounding uses its own,
    /// which is a `.noOp`, not a `.refused`. The refusals this turn can raise belong to grounding
    /// and consistency, and this stage only changes what they are looking at.
    private func recordSegmentation(of text: String, trace: inout PipelineTrace) {
        guard let segmented = try? SynchronousClaimSegmenter().segment(text) else {
            trace.record(
                .claimSegmentation,
                .noOp(reason: "no checkable claim; grounding used its own sentence segmenter")
            )
            return
        }
        let repaired = segmented.repairedClaims.count
        let clauses = segmented.claims(of: .clause).count
        var detail = "\(segmented.claims.count) claim(s), \(clauses) from split sentences"
        if repaired > 0 {
            detail += ", \(repaired) with a subject carried in"
        }
        if !segmented.refusedSplits.isEmpty {
            detail += ", \(segmented.refusedSplits.count) split(s) refused"
        }
        trace.record(.claimSegmentation, .ran(detail: detail))
    }
}
