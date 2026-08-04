import Foundation
import SourceConflictKit

/// What the conflict audit concluded about the fused passages.
enum SourceConflictResult: Sendable, Equatable {
    /// Use these passages. Withheld ones have already been removed.
    case admitted([RetrievedSource])
    /// Do not send this turn.
    case refused(Refusal)
}

/// What the retrieval half of preparation produced.
///
/// A tuple could not carry the third possibility. Retrieval used to either find passages or not;
/// now it can also conclude that the passages it found contradict each other, and that outcome has
/// to reach `prepare` rather than being flattened into "no passages".
enum RetrievalResult: Sendable, Equatable {
    case passages([RetrievedSource], String)
    case refused(Refusal)
}

extension PreModelPipeline {
    /// Audits the passages that survived fusion against **each other**, before any of them reach
    /// the model.
    ///
    /// Every other truthfulness stage in this pipeline runs after `providerRouting`: grounding
    /// checks the answer against its sources, `claimConsistency` checks whether the answer states
    /// the opposite of the passage it cited. Both judge a paragraph the user has already paid for.
    /// This one runs while the evidence is still just evidence, and it is free.
    ///
    /// The retrieved set answers one question, so it is audited under one topic derived from the
    /// outbound text. Passages are keyed by document, which is what makes `corroboration` mean
    /// "how many independent documents say this" rather than "how many chunks came back".
    func auditSourceConflicts(
        _ fused: [RetrievedSource],
        for outbound: String,
        trace: inout PipelineTrace
    ) async -> SourceConflictResult {
        guard fused.count > 1 else {
            trace.record(.sourceConflict, .noOp(reason: "fewer than two passages; nothing to compare"))
            return .admitted(fused)
        }
        guard let topic = try? TopicKey(outbound) else {
            // A query of nothing but stop words gives no subject to scope the comparison to, and
            // auditing everything against everything would report unrelated passages as disputes.
            trace.record(.sourceConflict, .skipped(reason: "the query carries no subject to scope on"))
            return .admitted(fused)
        }

        do {
            let report = try await ConflictAuditor().audit(
                fused.map { source in
                    Passage(
                        id: source.id,
                        text: source.snippet,
                        topic: topic,
                        // The corpus carries no publisher tier and no revision, so `authority` and
                        // `recency` tie on every comparison and stand aside by design. That leaves
                        // corroboration deciding, and an even split refusing — stated here rather
                        // than hidden behind a tier invented to make the ladder look busier.
                        provenance: Provenance(sourceID: source.id)
                    )
                },
                policy: .strict,
                at: 0
            )
            return outcome(of: report, over: fused, trace: &trace)
        } catch {
            trace.record(.sourceConflict, .failed(message: "\(error)"))
            return .admitted(fused)
        }
    }

    private func outcome(
        of report: ConflictReport,
        over fused: [RetrievedSource],
        trace: inout PipelineTrace
    ) -> SourceConflictResult {
        switch report.decision {
        case .clear:
            trace.record(.sourceConflict, .noOp(reason: "\(fused.count) passages, no disagreement"))
            return .admitted(fused)

        case let .flagged(withheld):
            let rule = report.findings.compactMap(decidingRule).first ?? "a tie-breaker"
            trace.record(
                .sourceConflict,
                .ran(detail: "\(report.findings.count) conflict(s); "
                    + "withheld \(withheld.count) passage(s) on \(rule)")
            )
            return .admitted(fused.filter { report.admitted.contains($0.id) })

        case let .blocked(topics):
            // A refusal, not a failure. The sources genuinely contradict each other and nothing
            // in the evidence says which is right — answering anyway would produce a confident
            // sentence built on whichever passage landed closer to the prompt.
            let refusal = Refusal(
                stage: .sourceConflict,
                headline: "Your sources disagree with each other",
                explanation: "The passages retrieved for \(topics.joined(separator: ", ")) "
                    + "contradict one another, and nothing about them says which is right. "
                    + "Answering from both would produce a confident answer built on a coin flip.",
                recovery: .openSettings(field: "Retrieval")
            )
            trace.record(.sourceConflict, .refused(refusal))
            return .refused(refusal)
        }
    }

    private func decidingRule(_ finding: ConflictFinding) -> String? {
        guard case let .resolved(_, rule) = finding.resolution else { return nil }
        return rule.rawValue
    }
}
