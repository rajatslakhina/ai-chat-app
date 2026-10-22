import Foundation
import ProviderGatewayKit
import TokenCalibrationKit

/// Counts a request's prompt tokens before it is sent, from the bills this model has already sent.
///
/// Every token count this app made before a call was characters / 4
/// (`ConversationMessage.estimatedTokens`). That is close for English and far too low for Japanese,
/// code and emoji, and the compactor trims to the window by that count, so a long Japanese
/// conversation could pass compaction and still be rejected by the model after the budget was held.
/// Here a `TokenCalibrator` counts the request exactly as it will be sent (the messages, the
/// tool-result instruction and the tool definitions) at rates learned from this model's own bills,
/// and `ContextFit` compares that interval with the window less the output limit.
///
/// The key is the model on the wire, not `turn.modelID`. `LLMRequest` has no model field, so every
/// call goes to the configured model whatever the router chose (see Remaining work in the README),
/// and rates filed under the router's choice would describe a model that never billed them.
struct LiveTokenCalibration: Sendable {
    let calibrator: TokenCalibrator
    let wireModel: String

    init(wireModel: String, calibrator: TokenCalibrator = TokenCalibrator()) {
        self.wireModel = wireModel
        self.calibrator = calibrator
    }

    /// What the stage records, and the refusal to show when it says no.
    struct Verdict: Sendable, Equatable {
        let outcome: StageOutcome
        let refusal: Refusal?
    }

    /// A request as the estimator sees it.
    ///
    /// A tool definition is counted from its name, its description and the Swift description of its
    /// schema rather than its wire JSON. The estimator only counts characters by class, so the order a
    /// dictionary prints in does not matter, and the tool set is the same on every turn, so the fit
    /// takes the difference from the wire form into the per-tool rate.
    static func features(of request: LLMRequest) -> TextFeatures {
        .prompt(
            messages: request.messages.map(\.content),
            toolSchemas: request.tools.map { tool in
                "\(tool.name) \(tool.toolDescription) \(String(describing: tool.parameterSchema))"
            }
        )
    }

    /// Whether the request fits `contextWindow` with `reservedOutput` kept for the answer.
    ///
    /// Only a certain overflow refuses: the lower end of the interval is already too big, so the model
    /// would reject the request. An interval that straddles the limit is sent and says so, because the
    /// point estimate and most of the interval fit and a refusal on a coin toss would be worse.
    func check(_ request: LLMRequest, contextWindow: Int, reservedOutput: Int) async -> Verdict {
        do {
            let estimate = try await calibrator.estimate(Self.features(of: request), model: wireModel)
            let fit = try ContextFit(
                estimate: estimate,
                contextWindow: contextWindow,
                reservedOutput: reservedOutput
            )
            var summary = "\(estimate.point) tokens [\(estimate.lower)-\(estimate.upper)] on \(wireModel),"
                + " \(estimate.basis.label)"
            if estimate.unfamiliarTokens > 0, case .calibrated = estimate.basis {
                summary += " (\(estimate.unfamiliarTokens) of them from text this model was never billed for,"
                    + " bounded by the prior band)"
            }
            guard case let .overflows(least, most) = fit else {
                let room = "\(contextWindow) less \(reservedOutput) for the answer"
                let detail = "\(summary); \(fit.label) in \(room)"
                return Verdict(outcome: .ran(detail: detail), refusal: nil)
            }
            let refusal = Refusal(
                stage: .tokenCalibration,
                headline: "Too long for this model",
                explanation: "By this model's own billing, this conversation is "
                    + "\(estimate.lower)-\(estimate.upper) tokens. The model takes \(contextWindow) with "
                    + "\(reservedOutput) kept for the answer, so it is \(least)-\(most) tokens over "
                    + "and would be rejected. Nothing was sent or charged.",
                recovery: .shortenConversation
            )
            return Verdict(outcome: .refused(refusal), refusal: refusal)
        } catch {
            return Verdict(outcome: .failed(message: "\(error)"), refusal: nil)
        }
    }

    /// Teaches the calibrator one bill: the prompt tokens of the call made with `request`.
    func learn(_ request: LLMRequest, billed: Int) async -> CalibrationUpdate? {
        try? await calibrator.record(Self.features(of: request), billedTokens: billed, model: wireModel)
    }
}
