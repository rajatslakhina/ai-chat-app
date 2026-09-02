import Foundation
import ProxyLabelKit

extension MetadataPipeline {
    /// Whether the label `effectiveVote` says this app does not have could be derived from what
    /// happened after the answer shipped.
    ///
    /// It can, and this stage does it. What it will not do is hand the result to the stage beside
    /// it. `checkConsistency` rules on the **answer**, so its verdict labels every gate that
    /// admitted the evidence behind that answer at once — and label noise shared across judges
    /// does not blur an error correlation toward zero the way independent noise does. It
    /// manufactures one. Switching `effectiveVote` to error agreement on these labels would not
    /// improve that measurement, it would invent dependence between gates that share nothing.
    ///
    /// Pricing the labels is what would make them safe, and pricing needs an audited subset —
    /// somebody reading turns and recording which gate was actually right. This app has no
    /// surface for that, so the stage reports the real refusal, with the real number of audited
    /// turns still missing, rather than a sentence saying it would be nice to have some.
    func auditProxyLabel(trace: inout PipelineTrace, store: PanelHistoryStore = .shared) async {
        await auditProxyLabel(
            trace: &trace,
            proposals: await store.labelProposals,
            outcomes: await store.outcomeCount,
            audited: Self.auditedTurns
        )
    }

    /// The audited subset this app can supply, which is none of them.
    ///
    /// A named empty value rather than an inline one, because it is the whole finding. Pricing a
    /// proxy label needs someone to read turns and record which gate was actually right, and this
    /// app has no screen, no store and no gesture for that. The parameter below exists so the day
    /// something does, the stage starts pricing without being rewritten.
    static let auditedTurns = AuditSample(entries: [])

    /// The same audit over supplied labels, for the same reason the sibling stages take a history.
    func auditProxyLabel(
        trace: inout PipelineTrace,
        proposals: [LabelProposal],
        outcomes: Int,
        audited: AuditSample = MetadataPipeline.auditedTurns
    ) async {
        guard let regime = NoiseRegime.detect(in: proposals) else {
            trace.record(
                .proxyLabel,
                .skipped(
                    reason: "no turn has both a filed gate reading and a downstream outcome yet, "
                        + "so nothing has been labelled (\(outcomes) outcome(s) recorded)"
                )
            )
            return
        }
        trace.record(
            .proxyLabel,
            .ran(detail: Self.detail(proposals: proposals, regime: regime, audited: audited))
        )
    }

    /// What was derived, what regime it landed in, and what stops it being used.
    private static func detail(
        proposals: [LabelProposal],
        regime: NoiseRegime,
        audited: AuditSample
    ) -> String {
        var parts: [String] = []
        let items = Set(proposals.map(\.item)).count
        let incorrect = proposals.filter { $0.label == .incorrect }.count
        parts.append(
            "\(proposals.count) label(s) derived across \(items) turn(s); "
                + "\(incorrect) call a gate wrong"
        )
        parts.append("regime is \(regime), read off the outcomes' scope and not chosen")

        switch FlipRateEstimator().estimate(from: audited) {
        case .success(let cost):
            parts.append("priced from \(audited.count) audited turn(s): flip rate \(cost.symmetric)")
        case .failure(let refusal):
            parts.append("not priced: \(refusal)")
        }
        parts.append(
            "so effectiveVote stays on vote agreement: an outcome scoped to the turn moves every "
                + "gate together, and unpriced shared noise manufactures correlation rather than "
                + "blurring it"
        )
        return parts.joined(separator: "; ")
    }
}
