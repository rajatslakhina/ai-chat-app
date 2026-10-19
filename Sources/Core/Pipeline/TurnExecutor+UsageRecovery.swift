import Foundation
import QuotaGovernorKit

/// The `usageRecovery` stage inside the executor: where a call that never reported its usage stops
/// being settled at zero. Its own file because `TurnExecutor+Support.swift` sits near SwiftLint's
/// 500-line limit.
extension TurnExecutor {
    /// Where one turn's calls start in the usage recorder, and how many attempts it took.
    struct CallMarks: Sendable, Equatable {
        let attempts: Int
        /// `UsageRecorder.recordCount` before the call.
        let records: Int
        /// `UsageRecorder.unmeteredCount` before the call.
        let unmetered: Int
    }

    /// Records `usageRecovery` and returns what the budget should hold, when one of this turn's
    /// calls streamed without reporting usage.
    func recoverIfUnmetered(
        reported: Bool,
        mark: Int,
        turn: PreparedTurn,
        trace: inout PipelineTrace
    ) async -> LiveUsageRecovery.Held? {
        if reported {
            trace.record(.usageRecovery, .noOp(reason: "the provider reported this turn's usage"))
            return nil
        }
        let calls = await usage.unmetered(after: mark)
        guard !calls.isEmpty else {
            trace.record(.usageRecovery, .noOp(reason: "no call streamed without reporting its usage"))
            return nil
        }
        guard let usageRecovery else {
            trace.record(
                .usageRecovery,
                .skipped(reason: "\(calls.count) call(s) ended without usage, but no billing lookup is "
                    + "wired into this executor; settled at zero")
            )
            return nil
        }
        let decision = await usageRecovery.hold(
            calls,
            promptTokens: turn.estimatedInputTokens,
            cutBy: Self.cutReason(trace),
            sinks: LiveUsageRecovery.Sinks(meter: meter, spend: onSettled)
        )
        switch decision {
        case let .held(held):
            trace.record(.usageRecovery, .ran(detail: held.detail))
            return held
        case let .skipped(reason):
            trace.record(.usageRecovery, .skipped(reason: reason))
            return nil
        }
    }

    /// A turn that stopped after its call: a dropped connection the completion check refused, a
    /// loop guard, a hop cap. If one of its calls streamed without usage, the hold settles at that
    /// call's upper bound instead of being released as if nothing had been spent.
    func settleStopped(
        _ reservation: Reservation?,
        turn: PreparedTurn,
        marks: CallMarks,
        trace: inout PipelineTrace
    ) async {
        let reported = await usage.lastRecord(after: marks.records) != nil
        guard let held = await recoverIfUnmetered(
            reported: reported,
            mark: marks.unmetered,
            turn: turn,
            trace: &trace
        ) else {
            await releaseIfHeld(reservation)
            return
        }
        await settle(
            reservation,
            tokens: held.tokens,
            microcents: held.microcents,
            reportsSpend: false,
            trace: &trace
        )
    }

    /// Why the app stopped reading, when a stage it ran says so.
    static func cutReason(_ trace: PipelineTrace) -> String? {
        trace.outcome(for: .degenerationGuard)?.isRefusal == true ? "cut by the repetition guard" : nil
    }
}
