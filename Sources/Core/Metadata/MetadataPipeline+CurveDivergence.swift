import CurveDivergenceKit
import DelayCurveKit
import ExplorationChannelKit
import Foundation

extension MetadataPipeline {
    /// Asks whether two classes of admission resolve at different speeds, using a supremum rather
    /// than an area — and then refuses, for a reason none of the three stages beside it has.
    ///
    /// `delaySignal` declines because it needs two separable rates. `delayShape` declines because it
    /// needs one of four families to fit. `delayCurve` *can* compute and declines anyway, because
    /// the censoring in this app is informative and a product-limit estimate assumes it is not.
    /// This one declines earlier and more simply: **there is no window to take a supremum over.**
    ///
    /// Every admission in this app is timestamped `admitted 0, returned 1` — the same logical clock
    /// `delayPanelSnapshot` uses, so the four stages cannot disagree about when anything happened.
    /// A shared window one tick wide leaves the gap series exactly two entries long, `t0` where both
    /// curves are one by construction and `t1`. A supremum over that is the difference between two
    /// proportions, and calling it a Kolmogorov-Smirnov statistic does not make it a statement about
    /// delay.
    ///
    /// The second half is worse than the first and is the reason this is a `skipped` rather than a
    /// `noOp`. **In this app the class label and the event indicator are the same field.** The two
    /// classes worth comparing are loss against no-loss, and an admission belongs to one of them
    /// only if `observedLoss` is there — which is the same fact that makes it a returned label
    /// rather than an outstanding one. So the arms can hold nothing but labelled entries, every
    /// unlabelled admission is dropped for want of a class, and what is left is two samples with no
    /// censoring in them at all. Removing the censoring is not a workaround here; it is the only
    /// way to form the arms, and it deletes the thing survival analysis exists for.
    ///
    /// Runs off the critical path with its siblings. Like them it never produces a `Refusal`: there
    /// is nothing for a user to undo about a comparison between two delay curves.
    func auditCurveDivergence(
        trace: inout PipelineTrace,
        ledger: ExplorationLedger = ExplorationBudget.ledger
    ) async {
        await auditCurveDivergence(trace: &trace, entries: await ledger.allEntries)
    }

    /// The same audit over an entry list, for the same reason the sibling stages take one.
    func auditCurveDivergence(trace: inout PipelineTrace, entries: [ExplorationEntry]) async {
        guard !entries.isEmpty else {
            trace.record(
                .curveDivergence,
                .noOp(reason: "nothing has been explored yet — there are no curves to compare")
            )
            return
        }
        guard let split = Self.divergenceSample(entries: entries) else {
            trace.record(
                .curveDivergence,
                .noOp(
                    reason: "one of the two classes has no labelled admission in it, so there is "
                        + "one curve and nothing to compare it against"
                )
            )
            return
        }
        trace.record(
            .curveDivergence,
            Self.divergenceOutcome(for: split.sample, dropped: split.dropped)
        )
    }

    /// The loss threshold `delayPanelSnapshot` splits on, so the four delay stages cannot disagree
    /// about which admissions are losses.
    static let divergenceLossThreshold = 0.5

    /// This app's ledger split into the two classes it can form, and the count it has to throw away
    /// to form them.
    ///
    /// Loss against no-loss, the same split the shared ecosystem demo compares. Only labelled
    /// entries can be placed: an admission with no `observedLoss` has no class, because the field
    /// that would give it one is the field that is missing. Those are exactly the censored
    /// observations, so the arms come back fully uncensored — reported alongside rather than
    /// quietly, since it is half of why this stage skips.
    ///
    /// `nil` when either arm has nothing in it, because a comparison needs two curves rather than
    /// one curve and an absence.
    static func divergenceSample(
        entries: [ExplorationEntry]
    ) -> (sample: DivergenceSample, dropped: Int)? {
        let labelled = entries.filter { $0.observedLoss != nil }
        let loss = labelled.filter { ($0.observedLoss ?? 0) > Self.divergenceLossThreshold }
        let clean = labelled.filter { ($0.observedLoss ?? 0) <= Self.divergenceLossThreshold }
        guard let first = Self.curveSample(entries: loss),
            let second = Self.curveSample(entries: clean)
        else { return nil }
        return (DivergenceSample(first: first, second: second), entries.count - labelled.count)
    }

    /// The verdict for one pair of arms, separated from the actor so it can be driven with panels
    /// this app cannot currently produce — which, as with `delayCurve`, is all the interesting ones.
    static func divergenceOutcome(
        for sample: DivergenceSample,
        dropped: Int = 0,
        settings: DivergenceSettings = .standard
    ) -> StageOutcome {
        guard sample.sharedSupport > 1 else {
            return .skipped(reason: Self.flatWindowReason(sample, dropped: dropped))
        }
        // Switched rather than guarded on `finding`, because a `guard let` needs a reason for the
        // else branch and the only honest one is the decline — which the optional has already
        // thrown away by then, leaving a `??` fallback that no input can reach.
        let report = DivergenceReport.make(for: sample, settings: settings)
        switch report.verdict {
        case let .separated(finding), let .notSeparated(finding):
            return .ran(detail: Self.describeDivergence(finding, report: report))
        case let .declined(reason):
            return .skipped(reason: "\(reason)")
        }
    }

    /// Why a window one tick wide is not a window.
    ///
    /// Written out rather than shortened to "the delay never varies", because that is the sentence
    /// `delayShape` and `delayCurve` already print between them and a third copy would read as
    /// duplication rather than as the distinct fact it is. The distinct fact is that this stage's
    /// statistic *degenerates* here — it does not lose power, it stops being the statistic — and
    /// that the comparison it would degenerate into is one the arms guarantee the answer to.
    static func flatWindowReason(_ sample: DivergenceSample, dropped: Int) -> String {
        let loss = sample.first.count
        let clean = sample.second.count
        return "every admission is timestamped admitted-0 returned-1, so the shared window is one "
            + "tick wide and the gap series has two entries: t0, where both curves are 1 by "
            + "construction, and t1. A supremum over that is a difference between two proportions, "
            + "and calling it a Kolmogorov-Smirnov statistic does not make it a statement about "
            + "delay. The second reason is separate and does not go away with a longer clock: the "
            + "class label and the event indicator are the same field here. An admission joins the "
            + "loss arm or the clean arm only if observedLoss is present, which is the same fact "
            + "that makes it a returned label — so \(dropped) unlabelled admission"
            + "\(dropped == 1 ? "" : "s") had no class to join and the \(loss)-against-\(clean) "
            + "comparison that remains has no censoring in it at all. Deleting the censoring is "
            + "not a workaround, it is the only way to form the arms, and it removes the thing "
            + "these curves exist to handle. A clock with more than one tick would fix the first "
            + "reason; only a label that arrives separately from the class would fix the second."
    }

    /// What a real comparison says, for the panels this app does not have yet.
    static func describeDivergence(_ finding: DivergenceFinding, report: DivergenceReport) -> String {
        let statistic = finding.statistic
        let where_ = statistic.positive.magnitude > statistic.negative.magnitude
            ? statistic.positive
            : statistic.negative
        let strain = finding.permutation.exchangeabilitySuspect
            ? " Censoring differs by "
                + String(format: "%.0f", report.censoredShareGap * 100)
                + "% between the arms, so exchangeability is under strain."
            : ""
        return "\(statistic.shape) over t0-t\(statistic.sharedSupport). "
            + "KS " + String(format: "%.4f", statistic.kolmogorovSmirnov)
            + " at t\(where_.time), p " + String(format: "%.4f", finding.permutation.kolmogorovSmirnovPValue)
            + "; Kuiper " + String(format: "%.4f", statistic.kuiper)
            + ", p " + String(format: "%.4f", finding.permutation.kuiperPValue)
            + "." + strain
    }
}
