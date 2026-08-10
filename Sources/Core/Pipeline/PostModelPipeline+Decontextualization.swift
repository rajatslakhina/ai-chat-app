import ClaimDecontextualizerKit
import Foundation
import GroundingKit

/// Whether each claim grounding just judged could be read on its own at all.
///
/// Grounding, consistency and citation binding all take a claim and ask which passage it matches.
/// None of them asks whether the claim has a subject. `It is not shared across sessions` does not,
/// and there is nothing in it to match correctly — a verifier handed that sentence will still
/// return a level and a percentage, because a scorer always returns something.
///
/// This stage resolves what a decisive antecedent justifies and refuses what it cannot, and the
/// refusal is the only signal in the pipeline that distinguishes *checked and found wanting* from
/// *never interpretable*.
extension PostModelPipeline {
    /// The policy this app resolves under, and why it is not `.strict`.
    ///
    /// `.strict` looks back two sentences, demands a 20% margin and treats `the cache` as pointing
    /// backwards whenever `cache` appeared earlier. Chat prose uses pronouns constantly and uses
    /// definite noun phrases even more, so strict detection would classify ordinary sentences as
    /// context-dependent and inflate the count this stage reports. `.lenient` reaches further back,
    /// accepts a narrower win, and leaves plain definite descriptions alone — which is the right
    /// trade when the escalation below fires only on claims that could not be resolved at all.
    static var decontextualizationPolicy: DecontextualizationPolicy { .lenient }

    /// A claim nobody could interpret, which grounding nonetheless counted as supported, is the one
    /// case worth refusing over.
    ///
    /// The others are degradations a reader can weigh. An unresolvable claim that grounding called
    /// unsupported or contradicted overclaims nothing — the verdict is unflattering either way. But
    /// this app renders "N of M verified" from `groundedFraction`, and a claim with no subject
    /// counted inside that N puts a verification badge on a sentence the app could not read. That
    /// is the same kind of fault as an invented citation: not a weaker answer, but the app
    /// asserting in its own voice that it checked something it did not.
    func checkDecontextualization(
        of report: GroundingReport,
        trace: inout PipelineTrace
    ) -> Refusal? {
        checkDecontextualization(claims: report.verdicts.map(\.claim.text), against: report, trace: &trace)
    }

    /// The same check, with the claim texts supplied separately.
    ///
    /// This overload exists so the malformed-input contract is testable rather than assumed. A real
    /// `GroundingReport` never carries an empty claim list or a blank claim text, so the two paths
    /// below cannot be reached through a send — and a branch no test can reach is a branch whose
    /// behaviour is a guess. Callers in the send path use the single-argument form above.
    func checkDecontextualization(
        claims: [String],
        against report: GroundingReport,
        trace: inout PipelineTrace
    ) -> Refusal? {
        guard let resolution = resolve(claims, trace: &trace) else { return nil }
        return record(resolution, for: report, trace: &trace)
    }

    private func resolve(
        _ claims: [String],
        trace: inout PipelineTrace
    ) -> DecontextualizationReport? {
        guard !claims.isEmpty else {
            trace.record(
                .claimDecontextualization,
                .noOp(reason: "grounding produced no claims, so there is nothing to make standalone")
            )
            return nil
        }
        do {
            // Grounding's own claim texts, in grounding's own order, so a claim's index here is the
            // same claim the verdict at that index judged. Re-segmenting would let the two drift.
            let discourse = try Discourse(claims)
            return DecontextualizationEngine(policy: Self.decontextualizationPolicy).report(for: discourse)
        } catch {
            // `Discourse` only throws on an empty list or a blank sentence, both of which mean the
            // segmenter handed us something malformed. Local computation, so this is a wiring fault
            // rather than a network or model failure, and the answer is already paid for.
            trace.record(.claimDecontextualization, .failed(message: "\(error)"))
            return nil
        }
    }

    private func record(
        _ resolution: DecontextualizationReport,
        for report: GroundingReport,
        trace: inout PipelineTrace
    ) -> Refusal? {
        let unresolved = Self.unresolvedIndices(in: resolution)
        let vouched = Self.vouchedFor(unresolved, in: report)
        if let refusal = Self.refusalForVouched(vouched, claims: resolution.outcomes.count) {
            trace.record(.claimDecontextualization, .refused(refusal))
            return refusal
        }
        guard resolution.contextDependentCount > 0 else {
            trace.record(
                .claimDecontextualization,
                .noOp(reason: "every claim already stood on its own")
            )
            return nil
        }
        trace.record(
            .claimDecontextualization,
            .ran(detail: Self.detail(for: resolution, unresolved: unresolved))
        )
        return nil
    }

    /// Claims the resolver declined to rewrite, by their index in grounding's verdict list.
    static func unresolvedIndices(in resolution: DecontextualizationReport) -> [Int] {
        resolution.outcomes.filter(\.outcome.isRefusal).map(\.sentenceIndex)
    }

    /// Of those, the ones grounding counted as supported.
    static func vouchedFor(_ unresolved: [Int], in report: GroundingReport) -> [String] {
        unresolved.compactMap { index in
            guard index < report.verdicts.count else { return nil }
            let verdict = report.verdicts[index]
            guard verdict.level == .supported else { return nil }
            return verdict.claim.id
        }
    }

    static func refusalForVouched(_ vouched: [String], claims: Int) -> Refusal? {
        guard !vouched.isEmpty else { return nil }
        let named = vouched.sorted().joined(separator: ", ")
        return Refusal(
            stage: .claimDecontextualization,
            headline: "Answer counts an unreadable statement as verified",
            explanation: "\(vouched.count) of \(claims) statement(s) — \(named) — cannot be read on "
                + "their own: the thing they are about is only named earlier in the answer, and no "
                + "single earlier phrase is a clear enough match to write in. Grounding still "
                + "marked them supported, so the verified count on screen would cover a sentence "
                + "nobody could check.",
            recovery: .retryLater(after: nil)
        )
    }

    /// The detail line separates resolved from refused, because "3 context-dependent" reads as
    /// three problems when it may be three sentences the resolver fixed.
    static func detail(for resolution: DecontextualizationReport, unresolved: [Int]) -> String {
        var parts = ["\(resolution.resolvedCount) of \(resolution.contextDependentCount) "
            + "context-dependent claim(s) rewritten to stand alone"]
        if !unresolved.isEmpty {
            parts.append("\(unresolved.count) left as written — no antecedent decisive enough")
        }
        if let rate = resolution.resolutionRate() {
            parts.append("resolution rate \(Int((rate * 100).rounded()))%")
        }
        return parts.joined(separator: ", ")
    }
}
