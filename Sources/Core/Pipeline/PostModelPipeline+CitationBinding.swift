import CitationBindingKit
import Foundation
import GroundingKit

/// Whether each claim is supported by the document the answer *said* it came from.
///
/// Grounding asks which retrieved passage best supports a claim and keeps the winner. That is a
/// different question from the one a reader assumes was asked. A claim cut down to a clause shares
/// most of its wording with its neighbours, so the best-scoring passage is often not the one the
/// answer cited — and grounding has no vocabulary for saying so, because it never looked at the
/// citation.
///
/// This stage looks at the citation. It runs on grounding's own claims, so nothing is re-parsed and
/// the two cannot disagree about what a claim is.
extension PostModelPipeline {
    /// The policy this app binds under, and why it is not `.strict`.
    ///
    /// `.strict` refuses any claim the model did not attribute. This app asks for citations but
    /// cannot compel them, and a chat answer that summarises three passages in one sentence is
    /// ordinary rather than dishonest. Requiring a citation per clause would refuse most real
    /// answers, and a gate that fires on the normal case gets switched off. Inference is allowed
    /// and *tagged*, so an attribution the model asserted stays distinguishable from one this app
    /// guessed — which is the distinction the package exists to preserve.
    static var citationPolicy: BindingPolicy {
        BindingPolicy(
            adequateAlignment: 0.5,
            decisiveMargin: 0.25,
            inference: .infer,
            requiresCitations: false
        )
    }

    /// A citation naming a document that was never retrieved is invented provenance, and it is the
    /// one attribution failure worth refusing over.
    ///
    /// The others are degradations a reader can weigh: a weak citation is still a real document, an
    /// inferred binding is labelled as inferred, a divergence is reported alongside the answer. An
    /// invented source is different in kind — the answer asserts it came from somewhere that does
    /// not exist, and there is no version of that a user can evaluate. Publishing it with a
    /// footnote would put a fabricated provenance on screen in the app's own voice.
    func bindCitations(
        of report: GroundingReport,
        against evidence: GroundingKit.EvidenceSet,
        trace: inout PipelineTrace
    ) -> Refusal? {
        let claims = report.verdicts.map { verdict in
            CitedClaim(
                id: verdict.claim.id,
                text: verdict.claim.text,
                citations: verdict.claim.citations.map { CitationBindingKit.SourceID($0.rawValue) }
            )
        }
        guard let bound = boundReport(for: claims, against: evidence, trace: &trace) else {
            return nil
        }
        return record(bound, trace: &trace)
    }

    private func boundReport(
        for claims: [CitedClaim],
        against evidence: GroundingKit.EvidenceSet,
        trace: inout PipelineTrace
    ) -> BindingReport? {
        do {
            let documents = evidence.documents.map { document in
                CitationBindingKit.SourceDocument(
                    id: CitationBindingKit.SourceID(document.id.rawValue),
                    title: document.title,
                    text: document.text
                )
            }
            let binder = SynchronousCitationBinder(
                evidence: try CitationBindingKit.EvidenceSet(documents),
                policy: Self.citationPolicy
            )
            return try binder.bind(claims)
        } catch {
            // Binding is local computation, so a throw here is a wiring fault — a duplicate claim
            // id, or an evidence set this app built wrong — never a network or model failure. It is
            // reported rather than allowed to take the turn down: the answer is already paid for
            // and grounding has already judged it.
            trace.record(.citationBinding, .failed(message: "\(error)"))
            return nil
        }
    }

    private func record(_ report: BindingReport, trace: inout PipelineTrace) -> Refusal? {
        let statistics = report.statistics()
        let invented = report.flaggedFindings().compactMap { flagged -> String? in
            guard case let .unknownSource(source) = flagged.finding else { return nil }
            return source.description
        }
        if let refusal = refusalForInvented(invented, claims: statistics.claimCount) {
            trace.record(.citationBinding, .refused(refusal))
            return refusal
        }
        guard statistics.checkableCount > 0 else {
            trace.record(
                .citationBinding,
                .noOp(reason: "no claim in this answer asserts anything a citation could support")
            )
            return nil
        }
        trace.record(.citationBinding, .ran(detail: detail(for: statistics, in: report)))
        return nil
    }

    private func refusalForInvented(_ invented: [String], claims: Int) -> Refusal? {
        guard !invented.isEmpty else { return nil }
        let named = Set(invented).sorted().joined(separator: ", ")
        return Refusal(
            stage: .citationBinding,
            headline: "Answer cites a source that does not exist",
            explanation: "The answer attributes \(invented.count) of \(claims) statement(s) to "
                + "\(named), which was never retrieved for this question. A citation naming a "
                + "document nobody fetched cannot be checked, and the attribution is invented.",
            recovery: .retryLater(after: nil)
        )
    }

    /// The detail line names what was attributed and what was only inferred, because "5 of 5 bound"
    /// reads as five cited claims when it may be five guesses.
    private func detail(for statistics: BindingStatistics, in report: BindingReport) -> String {
        var parts = ["\(statistics.citedBoundCount) of \(statistics.checkableCount) claim(s) "
            + "bound to a source the answer cited"]
        if statistics.inferredBoundCount > 0 {
            parts.append("\(statistics.inferredBoundCount) inferred from overlap alone")
        }
        if statistics.unboundCount > 0 {
            parts.append("\(statistics.unboundCount) unattributed")
        }
        if statistics.misattributedCount > 0 {
            let names = report.misattributed().map(\.claimID).joined(separator: ", ")
            parts.append("\(statistics.misattributedCount) cited a source an uncited one beats "
                + "decisively (\(names))")
        }
        return parts.joined(separator: ", ")
    }
}
