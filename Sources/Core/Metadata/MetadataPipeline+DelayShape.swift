import DelayShapeKit
import DelayShapeSignal
import DelaySignalKit
import DelaySignalReturn
import ExplorationChannelKit
import Foundation
import LabelReturnKit

extension MetadataPipeline {
    /// Asks whether the delay `delaySignal` reads has any shape in it at all.
    ///
    /// `delaySignal` skips here, and its reason is that every label arrives the same distance from
    /// its admission so the delay cannot separate the classes. That is a statement about *this*
    /// estimator's identifiability condition. This stage asks the more basic version of the same
    /// question — is there a delay *distribution* to fit, of any kind — and the answer is worth
    /// having separately, because the two failures have different remedies and only one of them is
    /// waiting.
    ///
    /// Runs beside `delaySignal` in the metadata pipeline, off the critical path, for the same
    /// reason: nothing it finds is about the turn it runs on. Like everything here it never
    /// produces a `Refusal` — there is nothing for a user to undo about the shape of a delay.
    func auditDelayShape(
        trace: inout PipelineTrace,
        ledger: ExplorationLedger = ExplorationBudget.ledger
    ) async {
        await auditDelayShape(trace: &trace, entries: await ledger.allEntries)
    }

    /// The same audit over an entry list, for the same reason the sibling stage takes one: the
    /// unreadable-ledger arm is reachable through a plain array and not through the actor.
    func auditDelayShape(trace: inout PipelineTrace, entries: [ExplorationEntry]) async {
        guard !entries.isEmpty else {
            trace.record(
                .delayShape,
                .noOp(reason: "nothing has been explored yet — there are no arrival times to shape")
            )
            return
        }
        guard let snapshot = await Self.delayPanelSnapshot(entries: entries) else {
            trace.record(
                .delayShape,
                .skipped(reason: "the exploration ledger could not be read as a return ledger")
            )
            return
        }
        trace.record(.delayShape, Self.shapeOutcome(for: LedgerPanel.panel(from: snapshot)))
    }

    /// The verdict for one panel, separated from the actor so it can be driven with panels this app
    /// cannot currently produce — which is all the interesting ones, and is the finding.
    static func shapeOutcome(
        for panel: DelayPanel,
        settings: SelectionSettings = .standard
    ) -> StageOutcome {
        guard !panel.returned.isEmpty else {
            return .noOp(reason: "no exploration has been labelled yet — nothing has arrived to shape")
        }
        let diagnosis = PanelShapes.diagnose(panel, settings: settings)
        switch diagnosis.assumption {
        case let .supported(labels):
            return .ran(
                detail: "the delay of every class is memoryless within the evidence available "
                    + "(\(labels.map(\.description).joined(separator: ", "))) — a constant-hazard "
                    + "model is the right one to correct with"
            )
        case let .contradicted(label, chosen, margin):
            return .ran(
                detail: Self.describeShape(label: label, chosen: chosen, margin: margin, panel: panel)
            )
        case let .undecided(reason):
            return .skipped(reason: Self.describeUndecided(reason, panel: panel))
        }
    }

    /// The one line that matters when a class turns out to be a different shape: what to use
    /// instead, and how much of the correction was riding on the assumption.
    static func describeShape(
        label: LabelClass,
        chosen: DelayShape,
        margin: Double,
        panel: DelayPanel
    ) -> String {
        "the \(label) class does not have a constant hazard: \(chosen) beats the exponential by "
            + String(format: "%.2f", margin)
            + " AIC over \(panel.returned(label).count) labels. Any delay correction built on a "
            + "constant hazard is leaning on the wrong tail."
    }

    /// Why this app cannot use the package it just wired in, in the words an operator needs.
    ///
    /// The degenerate arm gets its own sentence because it is the one that would otherwise be read
    /// as "collect more data". It is not. More of a delay that never varies is more of nothing, and
    /// the useful reading is that verification here is not asynchronous at all.
    static func describeUndecided(
        _ reason: ExponentialAssumption.UndecidedReason,
        panel: DelayPanel
    ) -> String {
        guard case let .degenerateDelays(label, distinct) = reason else {
            return "no delay shape — \(reason)"
        }
        return "no delay shape — the \(label) class's \(panel.returned(label).count) labels all "
            + "arrived in \(distinct) distinct tick\(distinct == 1 ? "" : "s"). This app verifies "
            + "inline, so there is no delay distribution to fit and no amount of traffic will "
            + "produce one. The remedy is not more data: an admission still unlabelled here is not "
            + "a slow verification, it is a turn that never reached a verdict."
    }
}
