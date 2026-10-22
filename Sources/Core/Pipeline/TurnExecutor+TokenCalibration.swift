import Foundation
import TokenCalibrationKit

/// The `tokenCalibration` stage: before the budget is held, and after the bill arrives.
extension TurnExecutor {
    /// Checks the request against the context window. Before the workload profile and the hold, so a
    /// request the model will reject never holds budget or reaches the network.
    func checkTokenFit(_ turn: PreparedTurn, trace: inout PipelineTrace) async -> Refusal? {
        guard let tokenCalibration else {
            trace.record(
                .tokenCalibration,
                .skipped(reason: "no token calibrator is wired into this executor")
            )
            return nil
        }
        let verdict = await tokenCalibration.check(
            await request(from: turn),
            contextWindow: turn.contextWindowTokens,
            reservedOutput: settings.maxOutputTokens
        )
        trace.record(.tokenCalibration, verdict.outcome)
        return verdict.refusal
    }

    /// Learns from the turn's first billed call, the one made with the turn's own messages. Later
    /// calls of a tool turn also carry tool results, so their prompts are not this request.
    @discardableResult
    func learnTokenRates(_ turn: PreparedTurn, firstCall: OpenRouterUsage?) async -> CalibrationUpdate? {
        guard let tokenCalibration, let firstCall else { return nil }
        return await tokenCalibration.learn(await request(from: turn), billed: firstCall.promptTokens)
    }
}
