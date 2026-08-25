import DelaySignalKit
import DelaySignalReturn
import ExplorationChannelKit
import Foundation
import LabelReturnExploration
import LabelReturnKit

extension MetadataPipeline {
    /// Asks whether the labels `labelReturn` is still waiting on are late or gone.
    ///
    /// `labelReturn` holds a bracket open for every unlabelled admission, which is right when they
    /// might still arrive. Two things can make that bracket misleading and neither shows up in its
    /// width. A return process whose delay depends on the outcome makes the floor optimistic —
    /// wrong answers take longer to confirm, so the labels in hand are the flattering ones. And a
    /// return process with **no** delay at all makes an unlabelled admission something other than a
    /// slow one: it is not late, it is never coming.
    ///
    /// This app turns out to be the second case, and the stage measures that rather than assuming
    /// it. Runs here, off the critical path and after the answer is on screen, because nothing it
    /// finds is about the turn it runs on — and, like everything else in this pipeline, it never
    /// produces a `Refusal`.
    func auditDelaySignal(
        trace: inout PipelineTrace,
        ledger: ExplorationLedger = ExplorationBudget.ledger
    ) async {
        await auditDelaySignal(trace: &trace, entries: await ledger.allEntries)
    }

    /// The same audit over an entry list rather than a ledger.
    ///
    /// Split out because the unreadable-ledger arm below cannot be reached through an
    /// `ExplorationLedger`: that actor keys entries by id and carries the region's own validated
    /// probability, so the two things `ExplorationReturnAudit` throws on cannot occur. The arm still
    /// belongs here — this function's argument is a plain array and an array can hold a duplicate —
    /// and taking the array is what lets a test produce one instead of the arm being a branch
    /// nothing reaches, sitting in the send path, reported as covered.
    func auditDelaySignal(trace: inout PipelineTrace, entries: [ExplorationEntry]) async {
        guard !entries.isEmpty else {
            trace.record(
                .delaySignal,
                .noOp(reason: "nothing has been explored yet — there are no arrival times to read")
            )
            return
        }
        guard let snapshot = await Self.delayPanelSnapshot(entries: entries) else {
            trace.record(
                .delaySignal,
                .skipped(reason: "the exploration ledger could not be read as a return ledger")
            )
            return
        }
        trace.record(.delaySignal, Self.outcome(for: LedgerPanel.panel(from: snapshot)))
    }

    /// The verdict for one panel, separated from the actor so it can be driven with a panel this
    /// app cannot currently produce — which is most of them, and is the finding.
    static func outcome(for panel: DelayPanel, settings: EstimatorSettings = .standard) -> StageOutcome {
        guard !panel.returned.isEmpty else {
            return .noOp(reason: "no exploration has been labelled yet — nothing has arrived to time")
        }
        let distinct = Set(panel.returned.map { $0.delay }).count
        guard distinct > 1 else {
            return .skipped(reason: inlineVerificationReason(panel))
        }
        guard let decision = try? DelaySignalEstimator.decide(panel: panel, settings: settings) else {
            return .failed(message: "the delay panel could not be fitted")
        }
        switch decision {
        case .corrected(let risk):
            return .ran(detail: describe(risk))
        case .declined(let reason):
            return .skipped(reason: "no delay correction — \(reason)")
        }
    }

    /// Why this app cannot use the package it just wired in, in the words an operator needs.
    ///
    /// Written out rather than shortened to "not applicable" because the two facts in it are worth
    /// separating: the delay carries no signal *and* the outstanding column is not a queue. The
    /// second is the actionable one, and a reader who takes it for a backlog will wait for labels
    /// that were never sent.
    static func inlineVerificationReason(_ panel: DelayPanel) -> String {
        "this app verifies inline — all \(panel.returned.count) labels arrived the same distance "
            + "from their admission, so the delay says nothing about the outcome and the "
            + "identifiability condition cannot be met at any sample size. The "
            + "\(panel.outstanding.count) admissions still unlabelled are not slow, they are turns "
            + "that never reached a verdict: a different fault, and not one this stage can price."
    }

    /// One line an operator can read, when there is ever a correction to read.
    static func describe(_ risk: DelayCorrectedRisk) -> String {
        "closing the books reports " + String(format: "%.3f", risk.naive)
            + "; correcting for labels that are slow because they are losses gives "
            + String(format: "%.3f", risk.corrected)
            + " (" + String(format: "%+.3f", risk.shift) + ", "
            + String(format: "%.0f", risk.censoredShare * 100) + "% still outstanding). "
            + "\(risk.separation)"
    }

    /// The same ledger `labelReturn` audits, read through the same plan so the two stages cannot
    /// disagree about which admissions exist.
    static func delayPanelSnapshot(entries: [ExplorationEntry]) async -> LedgerSnapshot? {
        let plan = ExplorationAuditPlan(
            edges: [ExplorationBudget.reach],
            lossThreshold: 0.5,
            gate: GateFingerprint(identifier: "conformal-gate", threshold: CensoringFeedback.budget)
        )
        guard let built = try? await ExplorationReturnAudit.ledger(
            from: entries,
            plan: plan,
            admittedAt: { _ in LabelReturnKit.LogicalTime(0) },
            returnedAt: { _ in LabelReturnKit.LogicalTime(1) }
        ) else { return nil }
        return await built.ledger.snapshot(asOf: LabelReturnKit.LogicalTime(1))
    }
}
