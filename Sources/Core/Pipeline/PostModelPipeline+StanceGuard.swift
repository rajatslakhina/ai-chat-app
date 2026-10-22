import ProviderGatewayKit
import StanceGuardKit

/// The exchange `stanceGuard` judges, read from the messages the model was sent this turn: the last
/// user message, the assistant answer before it, and everything earlier.
struct StanceExchange: Equatable {
    let previousAnswer: String
    let userTurn: String
    let earlier: [String]
    /// Earlier user messages that were themselves objections. A question asked twice is not a
    /// repeated objection.
    let earlierObjections: [String]

    init?(messages: [LLMMessage]) {
        guard let userIndex = messages.lastIndex(where: { $0.role == .user }),
              let answerIndex = messages[..<userIndex].lastIndex(where: { $0.role == .assistant }) else {
            return nil
        }
        previousAnswer = messages[answerIndex].content
        userTurn = messages[userIndex].content
        let before = messages[..<answerIndex]
        earlier = before.map(\.content)
        let classifier = PushbackClassifier()
        earlierObjections = before.filter { $0.role == .user }.map(\.content).filter {
            !classifier.assess($0, previous: nil, prior: []).cues.isEmpty
        }
    }
}

extension PostModelPipeline {
    /// Whether the answer held the previous answer's position across the user's message.
    ///
    /// The other post-model stages judge the answer against sources and policy. None of them can see an
    /// answer that was right last turn and given up this turn because the user said "are you sure?".
    /// After `verify`, so it reads the text the user will see.
    ///
    /// No refusal: the answer may even be right. The user gets a note under the bubble saying the change
    /// came after a message with no new evidence, and what to do about it, and the trace records why.
    static func checkStance(
        _ review: AnswerReview,
        messages: [LLMMessage],
        trace: inout PipelineTrace
    ) -> AnswerReview {
        guard review.refusal == nil else {
            trace.record(.stanceGuard, .skipped(reason: "the answer was withheld, so there is no position"))
            return review
        }
        guard let exchange = StanceExchange(messages: messages) else {
            trace.record(.stanceGuard, .noOp(reason: "no earlier answer in this conversation to compare"))
            return review
        }
        let report = StanceGuard().assess(
            previousAnswer: exchange.previousAnswer, userTurn: exchange.userTurn,
            newAnswer: review.publishableText, earlier: exchange.earlier,
            earlierObjections: exchange.earlierObjections
        )
        guard report.needsAttention, let note = report.note else {
            trace.record(.stanceGuard, .noOp(reason: report.summary))
            return review
        }
        trace.record(.stanceGuard, .ran(detail: report.summary))
        var flagged = review
        flagged.stanceNote = note + " Ask again for a check on the merits if you want a second look."
        return flagged
    }
}
