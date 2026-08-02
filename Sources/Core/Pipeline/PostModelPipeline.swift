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
    private let tracer: Tracer
    private var tick = 0
    /// Spans this pipeline has closed. Counted here rather than read back from `Tracer`, whose
    /// only accessor wants a root id we do not hold — inventing one would report zero forever.
    private var closedSpans = 0

    init(
        guardrail: GuardrailPipeline,
        verifier: GroundingVerifier = GroundingVerifier(),
        tracer: Tracer = Tracer()
    ) {
        self.guardrail = guardrail
        self.verifier = verifier
        self.tracer = tracer
    }

    private func nextTick() -> Int {
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

        // 2. Grounding — only meaningful when there were sources to check against.
        var fraction: Double?
        var claims = 0
        if sources.isEmpty {
            trace.record(.grounding, .skipped(reason: "no retrieved sources to verify against"))
        } else {
            let outcome = await verify(text: text, sources: sources, trace: &trace)
            fraction = outcome.fraction
            claims = outcome.claims
            if let stripped = outcome.text, stripped != text {
                text = stripped
                modified = true
            }
        }

        await close(spanID, status: .ok, trace: &trace)
        return AnswerReview(
            publishableText: text,
            wasModified: modified,
            groundedFraction: fraction,
            claimCount: claims,
            refusal: nil
        )
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
            let grounded = report.groundedFraction()
            let total = report.claimCount()
            let supported = Int((grounded * Double(total)).rounded())
            trace.record(
                .grounding,
                .ran(detail: "\(supported) of \(total) claim(s) supported by a source")
            )
            return VerifyOutcome(
                text: report.decision.publishableAnswer(),
                fraction: grounded,
                claims: total
            )
        } catch {
            // A verifier that cannot run must not silently imply the answer was checked.
            trace.record(.grounding, .failed(message: "\(error)"))
            return VerifyOutcome(text: nil, fraction: nil, claims: 0)
        }
    }
}
