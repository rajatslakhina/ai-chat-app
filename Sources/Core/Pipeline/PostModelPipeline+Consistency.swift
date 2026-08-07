import ClaimConsistencyKit
import Foundation
import GroundingKit

/// The claim-consistency stage, lifted out of `PostModelPipeline` so that actor stays inside
/// SwiftLint's 250-line body limit as stages keep being added. It crossed the limit when
/// `citationBinding` was wired in; extracting a stage is the fix, not raising the limit.
extension PostModelPipeline {
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
    func checkConsistency(
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
}
