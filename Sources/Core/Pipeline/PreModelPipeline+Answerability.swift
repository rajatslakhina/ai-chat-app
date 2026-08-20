import AbstentionPolicyKit
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
            // The package reports `.contested` only when the affirming and denying strengths land
            // within `conflictMargin` of each other. That symmetry test turns out to be fragile to
            // a recall change, and this app found out how: keying raised one side of its own retry
            // corpus from 0.75 to 1.00 while the other stayed at 0.75, pushing a flat contradiction
            // outside the margin and turning a refusal into an admission. The old pass had been
            // luck — two *different* recall failures cancelling out at 0.75 each.
            //
            // So the presence of two-sided support is checked here as well. It is the claim this
            // app actually cares about, and unlike a margin, no strength change can hide it.
            let disputed = Self.disputed(in: report)
            guard disputed.isEmpty else {
                Self.reserve(.refuse("two-sided support on \(disputed.joined(separator: ", "))"),
                             for: ReservationOrigin.answerability, trace: &trace)
                return .refused(Self.contestedRefusal(aspects: disputed, trace: &trace))
            }
            Self.reserve(.clear, for: ReservationOrigin.answerability, trace: &trace)
            trace.record(
                .answerabilityGate,
                .ran(detail: "\(Self.covered(report)) of \(report.assessments.count) aspect(s) covered "
                    + "over \(report.evidenceCount) passage(s)")
            )
            return .admitted

        case let .insufficient(missing):
            return Self.judgeCoverageGap(report: report, missing: missing, trace: &trace)

        case let .contested(aspects):
            Self.reserve(.refuse("evidence disagrees about \(aspects.joined(separator: ", "))"),
                         for: ReservationOrigin.answerability, trace: &trace)
            return .refused(Self.contestedRefusal(aspects: aspects, trace: &trace))

        case .undetermined(.noEvidenceOffered):
            // Ordinary chat is not evidence-backed and most turns here carry no passages at all.
            // Inapplicable rather than inconclusive, which is what `.skipped` means.
            trace.record(
                .answerabilityGate,
                .skipped(reason: "no retrieved passages; turn is not evidence-backed")
            )
            Self.reserve(.unavailable("turn is not evidence-backed"),
                         for: ReservationOrigin.answerability, trace: &trace)
            return .admitted

        case let .undetermined(.tooFewAspects(found, required)):
            // Not a soft block. The gate formed no opinion, and dressing that up as a refusal
            // would refuse a question on the strength of not having read it. `unjudgedQuestion`
            // is the only way past this point, and reaching for it here is deliberate.
            trace.record(
                .answerabilityGate,
                .noOp(reason: "read \(found) aspect(s), \(required) required to rule; no opinion offered")
            )
            Self.reserve(.unavailable("read \(found) of \(required) aspects needed to rule"),
                         for: ReservationOrigin.answerability, trace: &trace)
            return .admitted
        }
    }

    /// A coverage gap, refused only when this app's matcher reads every missing aspect reliably.
    ///
    /// An attribute aspect is matched with its anchors unkeyed, so absence there is a much weaker
    /// claim than absence of a subject. See the note below.
    ///
    /// The untrusted branch files `.unavailable`, not a concern, and the difference is the whole
    /// point of the four-case vocabulary. This stage is not saying "I found a mild problem"; it is
    /// saying **"I could not measure this reliably"** — an attribute aspect is matched with its
    /// anchors unkeyed, so absence there is a claim about spelling. A reading the stage will not
    /// stand behind must not be able to corroborate somebody else's, or two symptoms of one
    /// recall gap add up to a refusal as though they were two independent judges.
    ///
    /// Filing it as a concern is exactly what was tried first, and `HybridRetrievalTests` refused
    /// "how much am I spending, what is the ceiling" for the third time in this app's history —
    /// the same query, a new mechanism. Those tests have now been right four times running.
    private static func judgeCoverageGap(
        report: AnswerabilityReport,
        missing: [String],
        trace: inout PipelineTrace
    ) -> AnswerabilityResult {
        guard Self.recallIsTrustworthy(for: report) else {
            trace.record(
                .answerabilityGate,
                .ran(detail: "\(Self.covered(report)) of \(report.assessments.count) aspect(s) covered; "
                    + "nothing found for: \(missing.joined(separator: ", ")); recorded rather than "
                    + "refused - an attribute aspect is matched unkeyed")
            )
            Self.reserve(
                .unavailable("cannot rule on coverage of \(missing.joined(separator: ", ")); an "
                    + "attribute aspect is matched unkeyed, so absence is weak evidence"),
                for: ReservationOrigin.answerability,
                trace: &trace
            )
            return .admitted
        }
        Self.reserve(.refuse("nothing covers \(missing.joined(separator: ", "))"),
                     for: ReservationOrigin.answerability, trace: &trace)
        return .refused(Self.insufficientRefusal(report: report, missing: missing, trace: &trace))
    }

    // MARK: - Why absence is refused for some aspects and only recorded for others
    //
    // `.insufficient` is a claim that *nothing* in the corpus speaks to an aspect — evidence of
    // absence, inferred from the matcher finding nothing. That inference is worth exactly as much
    // as the matcher's recall, which is why this stage used to admit it unconditionally: with
    // `LexicalEvidenceMatcher`, refusing blocked "how much am I spending" against this app's own
    // budget corpus, because the corpus says `spend` and `spends` and the question says `spending`.
    //
    // `MorphologyEvidenceMatcher` keys those onto one bucket, so that specific gap is closed — but
    // the flip still cannot be made wholesale, and the reason is worth writing down because it is
    // not the reason it failed last time. **The decorator deliberately leaves attribute aspects
    // unkeyed.** An `AttributeProbe` tests the shape of a statement against surface vocabulary —
    // `.time` looks for `minutes`, `.quantity` for `hundred` — and keying the passage turns those
    // into `minut` and `hundr`, which appear in no unit list, breaking the probe it was meant to
    // help. An attribute aspect's anchors go through unkeyed with it.
    //
    // So "how much am I spending" is *still* `.insufficient`, now missing `a quantity` rather than
    // its subject, and the three hybrid-retrieval tests caught the wholesale flip a second time.
    // They were right twice, for two different reasons.
    //
    // The policy that follows from that is narrower and matches where recall actually improved:
    // refuse when every uncovered aspect is probe-free — a missing subject means the corpus is not
    // about the thing at all, and inflection-aware recall makes that claim trustworthy. Record,
    // don't refuse, when an attribute is among the gaps.
    //
    // `.contested` never had this exposure: it requires two passages that both matched, pointing
    // opposite ways, which is a claim about **presence** that a recall gap can only make less
    // likely to fire. It has been refused since this stage was written, and still is.

    /// Aspects carrying meaningful support in both directions, whatever their strengths.
    ///
    /// `affirmingSources` and `denyingSources` are already filtered by the policy's
    /// `supportThreshold`, so a passage listed here matched the aspect properly rather than
    /// glancingly. Two such passages pointing opposite ways is a contradiction regardless of how
    /// far apart their scores are, and reading it from presence rather than from a margin is what
    /// makes this stage robust to its own matcher improving.
    private static func disputed(in report: AnswerabilityReport) -> [String] {
        report.assessments
            .filter { !$0.affirmingSources.isEmpty && !$0.denyingSources.isEmpty }
            .map(\.aspect.surface)
    }

    /// Whether every aspect the gate could not cover is one this app's matcher reads reliably.
    ///
    /// `probe == nil` is the test because that is exactly the set `MorphologyEvidenceMatcher` keys.
    /// An attribute aspect is compared with its anchor terms in their written form, so "no passage
    /// mentions this" is a claim about spelling as much as about content — not a basis for refusing
    /// somebody's question.
    private static func recallIsTrustworthy(for report: AnswerabilityReport) -> Bool {
        report.assessments
            .filter { !$0.isCovered }
            .allSatisfy { $0.aspect.probe == nil }
    }

    /// A coverage gap the user can act on.
    ///
    /// Named aspects rather than a score. "Nothing covers the retry budget" tells someone what to
    /// go and add; "coverage 40%" tells them the app is unhappy and not why. Retrieval is the
    /// recovery because a gap is the one verdict more retrieval actually fixes — which is exactly
    /// what separates it from `.contested`, where retrieving more makes things worse.
    private static func insufficientRefusal(
        report: AnswerabilityReport,
        missing: [String],
        trace: inout PipelineTrace
    ) -> Refusal {
        let refusal = Refusal(
            stage: .answerabilityGate,
            headline: "Your sources don't cover this question",
            explanation: "Nothing in the \(report.evidenceCount) retrieved passage(s) speaks to "
                + "\(missing.joined(separator: ", ")). Answering from them would produce something "
                + "that reads as verified without being checkable.",
            recovery: .openSettings(field: "Retrieval")
        )
        trace.record(.answerabilityGate, .refused(refusal))
        return refusal
    }

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

extension PreModelPipeline {
    /// The four rulings that can stop a turn while stopping it is still free.
    ///
    /// All four run after compaction, so they judge the evidence the model will actually receive.
    /// Order matters and is not arbitrary. The gate decides whether the evidence answers the
    /// question at all. Temporal validity comes next because it needs nothing from the two below
    /// it and because a ruling resting on an expired snapshot is not worth measuring the
    /// provenance or the stability of. Independence then derives the document keys stability
    /// needs, and stability runs last because it is the only one that re-runs a judge.
    ///
    /// Lives here rather than in the actor body for the reason `resolveIndependence` does: adding
    /// the temporal call put `PreModelPipeline` at 251 lines against a 250-line limit, and the fix
    /// for that is to move orchestration out, not to raise the number.
    func refusalBeforeSending(
        sources: [RetrievedSource],
        outbound: String,
        trace: inout PipelineTrace
    ) async -> Refusal? {
        if let refusal = await firstStageRefusal(sources: sources, outbound: outbound, trace: &trace) {
            // The arbiter still reports, and reports the truth: it did not rule, because there was
            // nothing left for it to rule on. Leaving it unreached would show the Diagnostics
            // reader a stage that silently did not run, which is the one thing that screen exists
            // to prevent — and this app has five other stages that already look like that after an
            // early refusal, so the reason is worth stating rather than inferring.
            trace.record(
                .signalDependence,
                .skipped(reason: "\(refusal.stage.title) already refused; nothing left to count")
            )
            trace.record(
                .abstentionArbiter,
                .skipped(reason: "\(refusal.stage.title) already refused; a refusal is never overturned")
            )
            trace.record(
                .conformalGate,
                .skipped(reason: "\(refusal.stage.title) already refused; nothing left to score")
            )
            return refusal
        }
        // Deflate before arbitrating, never after. The arbiter counts distinct origins, so a
        // reduction applied to its ruling rather than to its input would be arguing with a
        // decision instead of correcting the arithmetic it was made from.
        await deflateSignalDependence(trace: &trace)
        if let refusal = arbitrateReservations(trace: &trace) {
            trace.record(
                .conformalGate,
                .skipped(reason: "the arbiter already refused; nothing left to score")
            )
            return refusal
        }
        return await gateOnCertifiedRisk(ledger: calibration, trace: &trace)
    }

    /// The four rulings, in order, stopping at the first that refuses.
    ///
    /// Split out from ``refusalBeforeSending(sources:outbound:trace:)`` so the arbiter's own
    /// reporting is not tangled with four early returns — and because `function_body_length` is a
    /// fair signal that a function doing both had outgrown one body.
    private func firstStageRefusal(
        sources: [RetrievedSource],
        outbound: String,
        trace: inout PipelineTrace
    ) async -> Refusal? {
        if case let .refused(refusal) = await gateAnswerability(of: sources, for: outbound, trace: &trace) {
            return refusal
        }
        if let refusal = establishTemporalValidity(question: outbound, sources: sources, trace: &trace) {
            return refusal
        }
        let independence = resolveIndependence(of: sources, trace: &trace)
        if let refusal = independence.refusal {
            return refusal
        }
        if case let .refused(refusal) = await measureVerdictStability(
            of: sources,
            independence: independence.report,
            for: outbound,
            trace: &trace
        ) {
            return refusal
        }
        return nil
    }
}
