import ExplorationChannelKit
import Foundation
import LabelReturnExploration
import LabelReturnKit

extension PostModelPipeline {
    /// Records what the verification stages just decided, as one labelled calibration point, and
    /// routes the same verdict back to the admission that bought this turn.
    ///
    /// Wraps ``verify(answer:sources:trace:)`` rather than living inside it because that function
    /// returns from four places, and a label recorded at three of them would quietly train the
    /// gate on the subset of turns that took those paths.
    ///
    /// Lives in this file rather than beside the actor because it is now the entry point for the
    /// return routing below, and because keeping it there put the actor body over SwiftLint's
    /// type-length limit — which is a real signal that this function had drifted away from the
    /// stages it sits among.
    func label(trace: inout PipelineTrace) async {
        let id = "turn-\(await calibration.size())"
        guard let point = ConformalCalibration.point(id: id, trace: trace) else {
            trace.record(
                .labelReturn,
                .skipped(reason: "this turn carries no verdict, so there is no label to route")
            )
            return
        }
        await calibration.record(point)
        // The same turn, in the log that also holds the refusals. Recorded here rather than beside
        // the point above so both halves of the population are written under the same condition:
        // a turn that cannot carry a label is not in the population either half is about.
        if let censoring {
            try? await censoring.record(
                CensoringFeedback.answered(id: id, wasWrong: point.wasWrong)
            )
        }
        await routeReturn(wasWrong: point.wasWrong, trace: &trace)
    }

    /// Attaches this turn's verdict to the admission that bought it, then says what the admissions
    /// still unlabelled do to the number the gate is judged on.
    ///
    /// `explorationChannel` answers a refused turn on purpose and records that it *had a chance*,
    /// with its loss left unknown — correctly, because at that point in the turn no answer exists.
    /// Until now nothing ever went back. Every exploration this app has ever paid for sat in the
    /// channel's ledger as spend with no evidence attached, and the comment saying the label
    /// "arrives later or not at all" was accurate in only one direction: it never arrived.
    ///
    /// This closes it. The verdict the judging stages just reached is the label, and this is the
    /// first point in the turn where it exists.
    ///
    /// **It never refuses**, and the reason is worth stating rather than leaving to be noticed.
    /// Outstanding labels are a fact about *earlier* turns; withholding this answer over them would
    /// punish a request that had nothing to do with it, and every stage that could act on the
    /// finding — `censoredFeedback`, `conformalGate`, `explorationChannel` — has already run and
    /// already spent the money. What this produces is an audit line, and it is honest about being
    /// one.
    /// `ledger` is injected with a default exactly as `CensoringLedger` and `ExplorationBudget`
    /// are, so two tests cannot route verdicts into each other's admissions.
    func routeReturn(
        wasWrong: Bool,
        trace: inout PipelineTrace,
        ledger: ExplorationLedger = ExplorationBudget.ledger
    ) async {
        guard let explorationID = trace.explorationID else {
            await reportOutstanding(trace: &trace, explored: false, ledger: ledger)
            return
        }
        let attached = await ledger.label(explorationID, loss: wasWrong ? 1 : 0)
        guard attached else {
            // The channel has no entry under this id. Reported rather than swallowed: the two
            // stages agreed on an id and one of them is wrong, which is a bookkeeping fault and
            // not a quiet no-op.
            trace.record(
                .labelReturn,
                .skipped(reason: "no admission on file for \(explorationID) — the verdict has nowhere to go")
            )
            return
        }
        await reportOutstanding(trace: &trace, explored: true, ledger: ledger, verdictWas: wasWrong)
    }

    /// Reads the channel's whole ledger through the return audit and files what it says.
    private func reportOutstanding(
        trace: inout PipelineTrace,
        explored: Bool,
        ledger: ExplorationLedger,
        verdictWas wasWrong: Bool? = nil
    ) async {
        // One guard rather than two. An empty-entries check and a nil reading are the same
        // condition written twice: `audit` can only fail to build its ledger on a duplicate id or
        // a probability outside `(0, 1]`, and a channel ledger produces neither — it keys entries
        // by id, and the probability is the region's own validated frequency. So a nil reading
        // means there is nothing to read, and a second guard would have been a branch no test
        // could reach sitting behind one that every test does.
        guard let reading = await Self.audit(entries: await ledger.allEntries) else {
            trace.record(
                .labelReturn,
                .noOp(reason: "nothing has been explored yet — no admission is waiting on a verdict")
            )
            return
        }
        let prefix: String
        if let wasWrong {
            prefix = "verdict routed — this exploration was "
                + (wasWrong ? "wrong, which is what buying it was for; " : "right; ")
        } else {
            prefix = explored ? "verdict routed; " : "not an exploration; "
        }
        trace.record(.labelReturn, .ran(detail: prefix + Self.describe(reading)))
    }

    /// The bracket, the diagnosis and the re-audit, over every exploration this app has bought.
    ///
    /// One band rather than several. This app explores a single narrow region by construction —
    /// `ExplorationBudget.reach` is 0.15 of nonconformity score — so splitting it would produce
    /// bands that differ by less than the noise in a handful of admissions, and a selectivity
    /// check on those would fire on nothing. Named here because the alternative is a reader
    /// assuming the check is doing work it is not.
    static func audit(entries: [ExplorationEntry]) async -> CorrectedRisk? {
        let plan = ExplorationAuditPlan(
            edges: [ExplorationBudget.reach],
            lossThreshold: 0.5,
            gate: GateFingerprint(identifier: "conformal-gate", threshold: CensoringFeedback.budget)
        )
        guard let built = try? await ExplorationReturnAudit.ledger(
            from: entries,
            plan: plan,
            admittedAt: { _ in LogicalTime(0) },
            returnedAt: { _ in LogicalTime(1) }
        ) else { return nil }
        let snapshot = await built.ledger.snapshot(asOf: LogicalTime(1))
        return CorrectedRisk.estimate(from: snapshot, selectivityTolerance: 0.15)
    }

    /// One line an operator can read on the Diagnostics screen.
    ///
    /// It leads with the floor and says what the floor *is*, because that is the number this whole
    /// stage exists to stop somebody quoting on its own.
    static func describe(_ reading: CorrectedRisk) -> String {
        let verdict = ReauditVerdict.reaudit(reading, alpha: CensoringFeedback.budget)
        return "closing the books here reports "
            + String(format: "%.3f", reading.lower)
            + ", the most optimistic reading the evidence allows; with every outstanding label "
            + "counted against it the rate is at most "
            + String(format: "%.3f", reading.upper)
            + " (" + String(format: "%.0f", reading.unobservedShare * 100)
            + "% of the explored population still unlabelled). Re-audit at "
            + String(format: "%.2f", CensoringFeedback.budget) + ": \(verdict)"
    }
}
