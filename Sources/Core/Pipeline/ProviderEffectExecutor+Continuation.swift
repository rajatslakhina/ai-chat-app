import AnswerContinuationKit
import ProviderGatewayKit

/// The answer the length limit cut: one more call for the rest, or the safe part. See
/// `LiveAnswerContinuation.swift`.
extension ProviderEffectExecutor {
    /// The output limit each call of this turn was sent with.
    func outputLimit() -> Int { request.maxOutputTokens }

    /// Returns the answer to deliver, and records what happened in `continuation`.
    ///
    /// Never throws. The continuation call happens after the answer was billed, so an error here
    /// must not reach the retry policy: a resend would pay for the whole answer again.
    func finishIfCut(
        _ answer: String,
        stop: LLMResponse.FinishReason?,
        messages: [LLMMessage]
    ) async -> String {
        guard let stop else {
            continuation = .none
            return answer
        }
        guard stop == .maxTokens else {
            continuation = .stopped(stop)
            return answer
        }
        var loop = ContinuationLoop(policy: LiveAnswerContinuation.policy)
        let step = loop.start(answer: answer, stop: .lengthLimit)
        let outcome = await drive(step, loop: &loop, messages: messages)
        continuation = .cut(cutAt: answer.unicodeScalars.count, outcome: outcome)
        return outcome.text
    }

    /// Sends each plan the loop returns until it finishes. One round under the app's policy.
    private func drive(
        _ step: ContinuationStep,
        loop: inout ContinuationLoop,
        messages: [LLMMessage]
    ) async -> ContinuationOutcome {
        switch step {
        case let .finished(outcome):
            return outcome
        case let .continueWith(plan):
            let next: ContinuationStep
            do {
                next = loop.absorb(try await askForTheRest(plan, after: messages), to: plan)
            } catch {
                next = loop.fail("\(error)")
            }
            return await drive(next, loop: &loop, messages: messages)
        }
    }

    /// The continuation request: the conversation so far, the kept answer as the assistant's turn,
    /// and the instruction. No tools: the model is asked to finish writing, not to act.
    private func askForTheRest(
        _ plan: ContinuationPlan,
        after messages: [LLMMessage]
    ) async throws -> ModelReply {
        let next = LLMRequest(
            messages: messages + plan.messages.map(LiveAnswerContinuation.message),
            maxOutputTokens: request.maxOutputTokens,
            temperature: request.temperature
        )
        var reply = ModelReply(text: "", stop: .missing)
        for try await event in provider.stream(request: next) {
            if case let .completed(response) = event {
                let stop = LiveAnswerContinuation.stop(response.finishReason)
                reply = ModelReply(text: response.text, stop: stop)
            }
        }
        return reply
    }
}
