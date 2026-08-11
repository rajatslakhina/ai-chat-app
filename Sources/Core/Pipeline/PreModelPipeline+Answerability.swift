import AnswerabilityKit
import Foundation

/// What the answerability gate concluded about the retrieved evidence.
enum AnswerabilityResult: Sendable, Equatable {
    /// Send the turn. Either the evidence covers the question, or the gate had no opinion.
    case admitted
    /// Do not send this turn.
    case refused(Refusal)
}

extension PreModelPipeline {
    /// Judges whether the passages that survived can answer the question that was asked.
    ///
    /// Every truthfulness stage downstream of `providerRouting` — grounding, citation binding,
    /// consistency, decontextualization — judges a paragraph the user has already paid for.
    /// `sourceConflict` runs earlier and is free, but it asks whether the passages agree with
    /// *each other*. Neither asks the question this stage asks: **do these passages contain what
    /// this question needs?**
    ///
    /// The failure that motivates it is specific to this app. `groundedFraction` renders as
    /// "N of M verified" in the transcript. A question the corpus cannot answer still produces an
    /// answer, and that answer still gets scored — the umbrella demo's scenario 31 shows grounding
    /// returning `partiallySupported 43%` for a sentence whose only load-bearing token was
    /// invented, because every word around it overlapped a real passage. A verification badge on
    /// that answer is the app asserting in its own voice that it checked something it could not
    /// have checked.
    ///
    /// Runs after compaction so it judges the evidence the model will actually receive rather
    /// than the evidence retrieval happened to find.
    func gateAnswerability(
        of sources: [RetrievedSource],
        for outbound: String,
        trace: inout PipelineTrace
    ) async -> AnswerabilityResult {
        // No `sources.isEmpty` check here on purpose. The package already distinguishes "handed
        // nothing to judge" from "judged and found wanting", and re-deciding that here would put
        // the same judgement in two places — where only one of them is tested.
        let report = await answerability.admit(
            Question(outbound),
            evidence: sources.map { EvidenceItem(id: $0.id, text: $0.snippet) }
        )

        switch report.verdict {
        case .answerable:
            trace.record(
                .answerabilityGate,
                .ran(detail: "\(Self.covered(report)) of \(report.assessments.count) aspect(s) covered "
                    + "over \(report.evidenceCount) passage(s)")
            )
            return .admitted

        case let .insufficient(missing):
            // Recorded, not refused. The reason is a property of this app's matcher rather than
            // of the package — see the note below `gateAnswerability`.
            trace.record(
                .answerabilityGate,
                .ran(detail: "\(Self.covered(report)) of \(report.assessments.count) aspect(s) covered; "
                    + "nothing found for: \(missing.joined(separator: ", "))")
            )
            return .admitted

        case let .contested(aspects):
            return .refused(Self.contestedRefusal(aspects: aspects, trace: &trace))

        case .undetermined(.noEvidenceOffered):
            // Ordinary chat is not evidence-backed and most turns here carry no passages at all.
            // Inapplicable rather than inconclusive, which is what `.skipped` means.
            trace.record(
                .answerabilityGate,
                .skipped(reason: "no retrieved passages; turn is not evidence-backed")
            )
            return .admitted

        case let .undetermined(.tooFewAspects(found, required)):
            // Not a soft block. The gate formed no opinion, and dressing that up as a refusal
            // would refuse a question on the strength of not having read it. `unjudgedQuestion`
            // is the only way past this point, and reaching for it here is deliberate.
            trace.record(
                .answerabilityGate,
                .noOp(reason: "read \(found) aspect(s), \(required) required to rule; no opinion offered")
            )
            return .admitted
        }
    }

    // MARK: - Why a coverage gap is recorded rather than refused
    //
    // `.insufficient` is a claim that *nothing* in the corpus speaks to an aspect — evidence of
    // absence, inferred from the matcher finding nothing. That inference is only as good as the
    // matcher's recall, and `LexicalEvidenceMatcher` does no stemming. Wiring this as a hard
    // refusal blocked "how much am I spending" against this app's own budget corpus, because the
    // corpus says `spend` and `spends` and the question says `spending`. Three existing tests
    // caught it, and they were right to.
    //
    // `.contested` does not have this failure mode. It requires two passages that both matched,
    // pointing opposite ways — a claim about **presence**, which a recall gap can only ever make
    // less likely to fire, never more. So that is the one this stage refuses on, and the coverage
    // gap is surfaced in Diagnostics instead, where a reader can weigh it.
    //
    // The gap closes when the matcher improves: `EvidenceMatching` is a protocol precisely so a
    // stemming or embedding matcher can replace the lexical one without touching this policy.
    // Until then, refusing on absence would trade a real failure for a more common invented one.

    /// Distinct from `sourceConflict`, which asks whether passages disagree on their shared topic.
    /// This asks whether they disagree on **the specific thing this question needs**, which a
    /// topic-level audit can admit and still leave unanswerable.
    private static func contestedRefusal(aspects: [String], trace: inout PipelineTrace) -> Refusal {
        let refusal = Refusal(
            stage: .answerabilityGate,
            headline: "Your sources contradict each other on this point",
            explanation: "The passages both speak to \(aspects.joined(separator: ", ")) and say "
                + "opposite things about it. Retrieving more would not settle that — picking a "
                + "source would.",
            recovery: .openSettings(field: "Retrieval")
        )
        trace.record(.answerabilityGate, .refused(refusal))
        return refusal
    }

    /// Counts rather than a rate.
    ///
    /// `coverageRate()` is optional because a question with no aspects has no rate — but both
    /// callers here are in verdicts that guarantee aspects exist, so the `nil` branch was
    /// unreachable, and an unreachable branch is a behaviour nobody has checked. Counts carry
    /// their own denominator, which is what a Diagnostics reader needs anyway.
    private static func covered(_ report: AnswerabilityReport) -> Int {
        report.assessments.filter(\.isCovered).count
    }
}
