import DelayCurveKit
import ExplorationChannelKit
import Foundation

extension MetadataPipeline {
    /// Asks what the labels that came back say about how long a verdict takes, with no family in
    /// the way — and then refuses to spend the answer.
    ///
    /// The two stages beside this one decline for reasons that are about *them*. `delaySignal`
    /// needs two separable rates. `delayShape` needs one of four families to fit. A product-limit
    /// estimate needs neither: it is a step function read straight off the labels, and a delay that
    /// only ever takes one value produces a perfectly well-formed curve with one step in it.
    ///
    /// So this stage can compute where its siblings cannot, and that turns out to be the trap
    /// rather than the win. Every product-limit estimate rests on the outstanding requests being
    /// like the returned ones only later — non-informative censoring, which the survival literature
    /// is blunt about needing external validation. In this app they are not alike at all: an
    /// admission is unlabelled because it never reached a verdict, not because its verdict is slow.
    /// The estimator has no way to see that. It reads a label and a cutoff landing in the same tick,
    /// finds an event at its support limit, and calls the distribution **complete** — reporting that
    /// everything resolved by t1 when a share of it never resolved at all.
    ///
    /// Runs off the critical path, after the answer is on screen, because nothing it finds is about
    /// the turn it runs on. Like everything in this pipeline it never produces a `Refusal`: there is
    /// nothing for a user to undo about the shape of a delay.
    func auditDelayCurve(
        trace: inout PipelineTrace,
        ledger: ExplorationLedger = ExplorationBudget.ledger
    ) async {
        await auditDelayCurve(trace: &trace, entries: await ledger.allEntries)
    }

    /// The same audit over an entry list, for the same reason the sibling stages take one.
    func auditDelayCurve(trace: inout PipelineTrace, entries: [ExplorationEntry]) async {
        guard !entries.isEmpty else {
            trace.record(
                .delayCurve,
                .noOp(reason: "nothing has been explored yet — there are no arrival times to curve")
            )
            return
        }
        guard let sample = Self.curveSample(entries: entries) else {
            trace.record(
                .delayCurve,
                .noOp(reason: "no exploration has been labelled yet — nothing has arrived to curve")
            )
            return
        }
        trace.record(.delayCurve, Self.curveOutcome(for: sample))
    }

    /// This app's ledger as a product-limit sample.
    ///
    /// Both timestamps mirror `delayPanelSnapshot` exactly — admitted at 0, labelled at 1, read at 1
    /// — so the three delay stages cannot disagree about which admissions exist or when they
    /// resolved. `nil` when nothing has been labelled, because a curve fitted to no events is the
    /// prior drawn as a step function.
    static func curveSample(entries: [ExplorationEntry]) -> CurveSample? {
        let observations: [CurveObservation] = entries.map { entry in
            entry.observedLoss == nil ? .outstanding(forTicks: 1) : .returned(afterTicks: 1)
        }
        return try? CurveSample(observations)
    }

    /// The verdict for one sample, separated from the actor so it can be driven with samples this
    /// app cannot currently produce — which is all the interesting ones, and is the finding.
    ///
    /// Volume first, then variety. Three labels that happen to share a tick really is just a small
    /// sample, and only once there are enough of them does sameness mean anything — the ordering
    /// `DelayShapeKit` arrived at on 2026-08-26 and the same one applies here.
    static func curveOutcome(for sample: CurveSample, settings: CurveSettings = .standard) -> StageOutcome {
        guard sample.returnedCount >= settings.minimumEvents else {
            return .skipped(
                reason: "only \(sample.returnedCount) label\(sample.returnedCount == 1 ? "" : "s") "
                    + "\(sample.returnedCount == 1 ? "has" : "have") come back, against the "
                    + "\(settings.minimumEvents) a curve needs. This one is waiting on volume."
            )
        }
        guard sample.distinctEventTimes > 1 else {
            return .skipped(reason: Self.inlineCurveReason(sample))
        }
        let curve = KaplanMeier.estimate(for: sample, settings: settings)
        return .ran(detail: Self.describeCurve(curve, sample: sample))
    }

    /// Why a curve this app *can* compute is one it must not use.
    ///
    /// Written out rather than shortened, because the short version — "the delay never varies" — is
    /// the same sentence `delayShape` already prints and would read as a duplicate. The fact worth
    /// separating is the second one: the estimator does not merely lack signal here, it reports a
    /// confident and wrong answer, and it is wrong in the direction that flatters the pipeline.
    static func inlineCurveReason(_ sample: CurveSample) -> String {
        let outstanding = sample.outstandingCount
        guard outstanding > 0 else {
            return "every label arrived in the same tick, so the curve is a single step and there "
                + "is no delay distribution to read. Verification here is inline."
        }
        return "every label arrived in the same tick and \(outstanding) admission"
            + "\(outstanding == 1 ? "" : "s") sit\(outstanding == 1 ? "s" : "") unlabelled at that "
            + "same tick, so the estimator finds an event at its support limit and calls the "
            + "distribution complete — it would report that everything resolved by t1 while "
            + "\(outstanding) never resolved at all. That is not a small-sample problem. A "
            + "product-limit estimate assumes the outstanding are the returned ones only later, and "
            + "here they are turns that never reached a verdict. No amount of traffic fixes it, and "
            + "nothing in the data would have told you."
    }

    /// What a real curve says, for the panels this app does not have yet.
    static func describeCurve(_ curve: SurvivalCurve, sample: CurveSample) -> String {
        let boundary = curve.isProper
            ? "every request reported"
            : "it stops at " + String(format: "%.4f", curve.survivalAtSupport)
                + " — where the rest sits is not in the data"
        let median = curve.medianDelay.map { "median \($0) tick\($0 == 1 ? "" : "s")" }
            ?? "no median inside the support"
        return "\(curve.points.count) step\(curve.points.count == 1 ? "" : "s") over "
            + "\(sample.count) requests, support to t\(curve.supportLimit), \(median), \(boundary)."
    }
}
