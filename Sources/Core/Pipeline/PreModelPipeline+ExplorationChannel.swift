import CensoredFeedbackKit
import ConformalGateKit
import ExplorationChannelKit
import Foundation

extension PreModelPipeline {
    /// Answers a turn the conformal gate refused, on purpose, to find out whether it was right.
    ///
    /// **This is the only stage in this app that overrides a supported refusal.** `censoredFeedback`
    /// one step above declines to enforce a promise that never reached this traffic, which is a
    /// different and weaker thing: it withdraws a guarantee that was not earned. This one lets a
    /// turn through that the certificate genuinely does support refusing, because a gate that never
    /// overrides itself never learns what it was refusing — the app labels only the turns it
    /// answered, so the refused half stays permanently unmeasured and no arithmetic recovers it.
    ///
    /// Four things bound it, and the first is the one that matters:
    ///
    /// 1. **It can only ever see a refusal from the conformal gate.** Every judging gate and the
    ///    arbiter return before this runs, so their refusals never reach it. That is structural,
    ///    not a rule somebody has to remember, and it is why a stage that loosens gates is safe to
    ///    have here at all.
    /// 2. The region bounds how confident the gate was. A turn far above the threshold is
    ///    unreachable at any budget.
    /// 3. The budget is finite and denominated in answered turns.
    /// 4. It produces no refusal of its own, ever. When it declines, the gate's refusal stands and
    ///    reaches the user unchanged.
    ///
    /// What it deliberately does not do is tell the user their answer was an exploration. This app
    /// has no channel for that short of a refusal, and inventing one here would be a UI decision
    /// made inside a pipeline stage. The admission is in the trace and on the Diagnostics screen,
    /// which is an audit trail rather than a disclosure, and the difference is worth naming.
    nonisolated func exploreRefusedTurn(
        refusal: Refusal?,
        ledger: CalibrationStore,
        channel: ExplorationChannel?,
        trace: inout PipelineTrace
    ) async -> Refusal? {
        guard let refusal else {
            trace.record(.explorationChannel, .noOp(reason: "nothing was refused — no refusal to explore"))
            return nil
        }
        // Defensive in name only: every other refusal returns upstream. Kept as a `guard` rather
        // than an assertion because the ordering it depends on is one edit away from changing, and
        // a stage that silently explored an answerability refusal would be very hard to see.
        guard refusal.stage == .conformalGate else {
            trace.record(
                .explorationChannel,
                .skipped(
                    reason: "\(refusal.stage.title) refused — "
                        + "only a certified-risk refusal is explorable"
                )
            )
            return refusal
        }
        guard let channel else {
            trace.record(.explorationChannel, .skipped(reason: "no exploration budget configured"))
            return refusal
        }
        guard let score = ConformalCalibration.score(for: trace.reservations),
              let threshold = await ledger.certificate().certificate?.threshold else {
            trace.record(
                .explorationChannel,
                .skipped(reason: "no scored threshold to measure depth against")
            )
            return refusal
        }

        let id = "explore-\(await censoring?.count ?? 0)"
        let candidate = ExplorationBudget.candidate(id: id, score: score, threshold: threshold)
        let ruling = await channel.consider(candidate)
        await ExplorationBudget.ledger.record(candidate, ruling: ruling)

        guard case let .admitted(cost, probability) = ruling else {
            trace.record(
                .explorationChannel,
                Self.explorationDeclined(ruling, score: score, threshold: threshold)
            )
            return refusal
        }

        await recordExploredTurn(id: id, probability: probability)
        // Carried to `labelReturn` at the far end of the turn, which is the only stage that will
        // ever know whether this exploration was worth buying.
        trace.noteExploration(id: id)
        trace.record(
            .explorationChannel,
            .ran(
                detail: "answered as a deliberate exploration — depth "
                    + String(format: "%.3f", candidate.depth)
                    + " above the threshold, cost " + String(format: "%.3f", cost)
                    + ", admission probability " + String(format: "%.2f", probability)
                    + "; \(String(format: "%.3f", await channel.remaining)) of budget left"
            )
        )
        return nil
    }

    /// Why this turn was not explored, told apart by reason.
    ///
    /// Four arms rather than one message, because "we did not explore" covers four different
    /// states and only one of them is fixable by waiting. Out of region is permanent at any budget;
    /// too costly and exhausted are about money; not drawn is about the frequency and will differ
    /// next turn.
    private static func explorationDeclined(
        _ ruling: AdmissionRuling,
        score: Double,
        threshold: Double
    ) -> StageOutcome {
        let depth = String(format: "%.3f", score - threshold)
        switch ruling {
        case .outsideRegion:
            return .noOp(reason: "depth \(depth) is beyond what this app explores at any budget")
        case let .tooCostly(cost, remaining):
            return .noOp(
                reason: "exploring depth \(depth) costs \(String(format: "%.3f", cost)) "
                    + "with \(String(format: "%.3f", remaining)) of budget left"
            )
        case .notDrawn:
            return .noOp(reason: "depth \(depth) is explorable; not drawn this turn")
        case .notRefused, .admitted:
            // `notRefused` here means the gate refused a turn whose score sits *inside* the
            // certified threshold — the refusal and the score disagree, which is a real state
            // worth reporting rather than exploring. `admitted` is handled by the caller and
            // cannot arrive; the arm is shared because Swift needs the switch exhaustive.
            return .skipped(
                reason: "the gate refused but depth \(depth) is inside the threshold — nothing to explore"
            )
        }
    }

    /// Records an explored turn as one that *had a chance*, which is the whole point.
    ///
    /// `CensoringFeedback.refused` logs probability zero, correctly, for a turn a deterministic
    /// threshold never could have admitted. This turn was admitted, at `probability`, so it carries
    /// a finite inverse-probability weight and its region stops being uncorrectable. Its loss is
    /// still unknown here — the answer has not been produced yet, let alone verified — so it goes
    /// in censored. The chance is the fact worth recording; the label arrives later or not at all.
    nonisolated func recordExploredTurn(id: String, probability: Double) async {
        guard let censoring else { return }
        try? await censoring.record(
            FeedbackRecord(id: id, admissionProbability: probability, observation: .censored)
        )
    }
}
