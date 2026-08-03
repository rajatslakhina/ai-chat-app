import ClaimConsistencyKit
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
    private let consistencyChecker: ConsistencyChecker?
    private let tracer: Tracer
    private var tick = 0
    /// Spans this pipeline has closed. Counted here rather than read back from `Tracer`, whose
    /// only accessor wants a root id we do not hold — inventing one would report zero forever.
    private var closedSpans = 0

    init(
        guardrail: GuardrailPipeline,
        verifier: GroundingVerifier = GroundingVerifier(),
        consistencyChecker: ConsistencyChecker? = try? ConsistencyChecker(),
        tracer: Tracer = Tracer()
    ) {
        self.guardrail = guardrail
        self.verifier = verifier
        self.consistencyChecker = consistencyChecker
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
            trace.record(.claimConsistency, .skipped(reason: "nothing was grounded, so nothing to compare"))
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

    /// Asks whether each claim *agrees* with the passage grounding matched it to.
    ///
    /// Grounding scores overlap and, above a threshold, checks polarity and quantity. That leaves
    /// a real gap: a claim that widens "some" to "all", swaps one member of a mutually exclusive
    /// pair for another, or names a different version carries neither a negation nor a differing
    /// numeral, so an overlap score cannot see it. Those answers reach the user reading as
    /// verified, which is worse than reaching them unverified.
    ///
    /// The pairs are grounding's own — re-matching here would answer a question the pipeline
    /// never asked. Nothing is re-retrieved and no model is called; every finding comes from
    /// reading two sentences, so this stage cannot fail for a network reason.
    ///
    /// A contradiction refuses. An answer that states the opposite of the app's own retrieved
    /// source is not worth annotating and showing, and the recovery is a regeneration: the
    /// contradiction is in this answer, not in the question.
    private func checkConsistency(
        of report: GroundingReport,
        against evidence: EvidenceSet,
        trace: inout PipelineTrace
    ) async -> Refusal? {
        let pairs: [ClaimPair] = report.verdicts.compactMap { verdict in
            guard let document = evidence.document(verdict.support.sourceID) else { return nil }
            return ClaimPair(
                claim: ClaimConsistencyKit.Claim(id: verdict.claim.id, text: verdict.claim.text),
                passage: SourcePassage(id: document.id.rawValue, text: document.text)
            )
        }
        guard let consistencyChecker else {
            trace.record(.claimConsistency, .skipped(reason: "no consistency checker configured"))
            return nil
        }
        // No `pairs.isEmpty` guard: grounding always returns at least one verdict for a
        // non-blank answer, so the empty case is unreachable from here. If it ever became
        // reachable the checker refuses it by name, and the catch below reports that rather
        // than a branch nothing can execute.
        do {
            let consistency = try await consistencyChecker.check(pairs, policy: .standard, at: nextTick())
            let contradicted = consistency.count(of: .contradicts)
            guard contradicted > 0 else {
                return recordAgreement(consistency, pairs: pairs.count, trace: &trace)
            }
            let detail = consistency.contradictions.map(\.summary).prefix(2).joined(separator: "; ")
            let refusal = Refusal(
                stage: .claimConsistency,
                headline: "Answer contradicts its own sources",
                explanation: "\(contradicted) of \(pairs.count) statement(s) disagree with the passage "
                    + "they were drawn from — \(detail).",
                recovery: .retryLater(after: nil)
            )
            trace.record(.claimConsistency, .refused(refusal))
            return refusal
        } catch {
            trace.record(.claimConsistency, .failed(message: "\(error)"))
            return nil
        }
    }

    /// Absence of contradiction is not agreement, and the trace says which one it was. Reporting
    /// "no rule could read these claims" as a pass is how a check becomes decoration.
    private func recordAgreement(
        _ consistency: ConsistencyReport,
        pairs: Int,
        trace: inout PipelineTrace
    ) -> Refusal? {
        let agreed = consistency.count(of: .agrees)
        guard agreed > 0 else {
            trace.record(
                .claimConsistency,
                .noOp(reason: "no negation, number, quantifier or version to check in \(pairs) claim(s)")
            )
            return nil
        }
        trace.record(
            .claimConsistency,
            .ran(detail: "\(agreed) of \(pairs) claim(s) positively agree with their source")
        )
        return nil
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
            let refusal = await checkConsistency(of: report, against: evidence, trace: &trace)
            return VerifyOutcome(
                text: report.decision.publishableAnswer(),
                fraction: grounded,
                claims: total,
                refusal: refusal
            )
        } catch {
            // A verifier that cannot run must not silently imply the answer was checked.
            trace.record(.grounding, .failed(message: "\(error)"))
            trace.record(.claimConsistency, .skipped(reason: "grounding produced no claim/source pairs"))
            return VerifyOutcome(text: nil, fraction: nil, claims: 0, refusal: nil)
        }
    }
}
