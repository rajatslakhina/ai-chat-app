import AbstentionPolicyKit
import Foundation

extension PreModelPipeline {
    /// The origins the four free gates file their readings under.
    ///
    /// One per stage rather than one per finding, because the arbiter counts judges and not
    /// utterances. The temporal stage can raise a reservation about several passages and that is
    /// still one stage's opinion.
    enum ReservationOrigin {
        static let answerability = SignalOrigin("answerability")
        static let temporal = SignalOrigin("temporal validity")
        static let independence = SignalOrigin("source independence")
        static let stability = SignalOrigin("verdict stability")
    }

    /// The policy this app arbitrates under.
    ///
    /// `minimumClearOrigins: 0` is the load-bearing choice, and it is not a loosening. Most turns
    /// in a chat client carry no retrieved evidence at all, so all four gates correctly record
    /// themselves as skipped — and under any positive coverage floor that would abstain on
    /// ordinary conversation. An unretrieved turn is not a turn whose judges went missing; it is a
    /// turn that does not need them. The distinction between those two is exactly what
    /// `SignalReading.unavailable` exists to preserve, and setting the floor to zero says this app
    /// reads a skipped judge as inapplicable rather than as a gap.
    ///
    /// Which leaves concurrence as the whole of the arbiter's job here, which is the honest scope:
    /// it exists to catch turns that several gates were uneasy about and none would stop.
    static let abstentionArbiter = AbstentionArbiter(
        policy: AbstentionPolicy(
            decisiveSeverity: .high,
            concurringOrigins: 2,
            minimumClearOrigins: 0,
            treatsUnavailableAsBlocking: false
        )
    )

    /// Reads the reservations the four gates filed and decides whether they add up.
    ///
    /// Returns `nil` on every path that is not an abstention, and records a real outcome on all of
    /// them — a stage that runs silently when it does nothing is a stage nobody can audit.
    nonisolated func arbitrateReservations(trace: inout PipelineTrace) -> Refusal? {
        let ruling = Self.abstentionArbiter.rule(on: trace.reservations)

        guard case let .abstain(reason) = ruling.decision else {
            trace.record(
                .abstentionArbiter,
                .ran(detail: "\(ruling.concerningOrigins.count) reservation(s) across "
                    + "\(trace.reservations.count) reading(s); below the bar to stop the turn")
            )
            return nil
        }

        // The arbiter's own thresholds produce exactly one of these. The other reasons belong to
        // policies this app does not run — a refusal here is impossible because the gates return
        // before filing one, and the coverage floor is zero — so mapping them to a user-facing
        // refusal would be writing a screen no input can reach.
        guard case let .concurringConcerns(origins) = reason else {
            trace.record(
                .abstentionArbiter,
                .noOp(reason: "ruled \(reason.summary), which this app's policy does not act on")
            )
            return nil
        }

        let refusal = Self.concurrenceRefusal(origins: origins, signals: trace.reservations)
        trace.record(.abstentionArbiter, .refused(refusal))
        return refusal
    }

    /// The one refusal this stage makes.
    ///
    /// It names the checks in the words the Diagnostics screen names them, and it quotes what each
    /// one actually said rather than summarising — a user told "two checks were unhappy" cannot
    /// tell a real problem from a fussy threshold, and the whole reason this stage exists is that
    /// each finding alone was judged not worth stopping for.
    ///
    /// The recovery is `.openSettings(field: "Retrieval")` because every reservation that can
    /// reach here is a statement about the retrieved corpus — its age, how many distinct voices
    /// are in it, how thin the support is. Retrieval is the one thing the user can change.
    private static func concurrenceRefusal(
        origins: [SignalOrigin],
        signals: [AbstentionSignal]
    ) -> Refusal {
        let named = origins.map(\.rawValue).joined(separator: " and ")
        let findings = origins
            .compactMap { origin -> String? in
                guard let detail = Self.concern(from: origin, in: signals) else { return nil }
                return "\u{2022} \(origin.rawValue): \(detail)"
            }
            .joined(separator: "\n")

        return Refusal(
            stage: .abstentionArbiter,
            headline: "Several checks were uneasy about this answer",
            explanation: "No single check was willing to stop this on its own, but \(named) each "
                + "found something:\n\(findings)\nTogether that is more doubt than this answer is "
                + "worth sending.",
            recovery: .openSettings(field: "Retrieval")
        )
    }

    /// What one origin actually said, read back out of the same array the arbiter ruled on.
    ///
    /// Deliberately not a side table populated as the gates file. A second store would be a second
    /// source of truth that two concurrent sends share, and the explanation would then be able to
    /// describe a set of findings different from the one the decision was made from — which is the
    /// mistake this ecosystem found by hand on 08-14 and again on 08-17, with a data race on top.
    private static func concern(from origin: SignalOrigin, in signals: [AbstentionSignal]) -> String? {
        signals.first { $0.origin == origin && $0.reading.concernSeverity != nil }?.reading.detail
    }

    /// Files one gate's reading.
    nonisolated static func reserve(
        _ reading: SignalReading,
        for origin: SignalOrigin,
        trace: inout PipelineTrace
    ) {
        trace.reserve(AbstentionSignal(origin: origin, reading: reading))
    }
}
