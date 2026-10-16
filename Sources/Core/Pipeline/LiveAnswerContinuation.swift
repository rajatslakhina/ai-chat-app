import AnswerContinuationKit
import ProviderGatewayKit

/// An answer that reaches the output limit stops wherever the tokens ran out. OpenRouter says so
/// (`finish_reason: "length"`, which the provider maps to `.maxTokens`) and returns HTTP 200.
/// Until this stage nothing read the finish reason, so the cut text was delivered as if the model
/// had finished: a dose one token short of its value, a link to half an address, a code block
/// that never closed.
///
/// The limit is not one the user chose. `TurnSettings.maxOutputTokens` is an app default (1,024)
/// with no control in Settings, and reasoning models spend part of it thinking: OpenRouter gives
/// them roughly 20/50/80/95% of `max_tokens` at Low/Medium/High/Extra effort, which leaves about
/// 52 tokens for the answer at Extra.
///
/// So `AnswerContinuationKit` asks once for the rest, inside the same billed effect (one more model
/// call, like a tool hop, metered like any other), and stitches the reply on: a preamble, a
/// reopened code fence and a repeat of the answer's end are removed, and a reply that starts over
/// is refused rather than spliced. If the answer is still cut, the part up to the last complete
/// word, number or link is delivered, any open code block closed, under a refusal that says what
/// happened and suggests a lower Effort before Try again.
///
/// The continuation is not streamed into the bubble: the bubble shows the cut text as it arrived,
/// and the stitched answer replaces it when the turn is reviewed. Streaming it live needs the
/// bubble to take back the dangling tail first; see the README's "Remaining work".
enum LiveAnswerContinuation {
    /// What the final model call of an attempt told the app about how it stopped.
    enum Record: Sendable, Equatable {
        /// No stop reason reached the app: the stream was cut short (by the repetition check) or
        /// the turn ended inside the tool loop.
        case none
        /// The model stopped for a reason other than the length limit.
        case stopped(LLMResponse.FinishReason)
        /// The length limit cut the answer after `cutAt` characters; `outcome` is what continuing did.
        case cut(cutAt: Int, outcome: ContinuationOutcome)
    }

    /// One round: each round sends the whole conversation again, so more rounds would multiply the
    /// cost of every cut answer without the user having asked for it. No inline notice: the
    /// refusal banner says the answer was cut, and a notice in the text would be re-sent to the
    /// model with the history.
    static let policy = ContinuationPolicy(
        maxRounds: 1,
        strategy: .instruction,
        missingStop: .assumeFinished,
        notice: ""
    )

    static let replayed: StageOutcome = .noOp(reason: "replayed an earlier result; nothing new to check")

    static let notCalled: StageOutcome = .skipped(
        reason: "the idempotency guard stopped the turn before the model answered"
    )

    static let discarded: StageOutcome = .noOp(
        reason: "the call did not finish; no answer was delivered to check"
    )

    /// Whether the stage asked the model for the rest, so the turn made a second billed call.
    static func madeACall(_ outcome: StageOutcome?) -> Bool {
        switch outcome {
        case .ran?, .refused?: return true
        default: return false
        }
    }

    /// The gateway's finish reason in the package's terms.
    static func stop(_ reason: LLMResponse.FinishReason) -> StopReason {
        switch reason {
        case .stop: return .finished
        case .maxTokens: return .lengthLimit
        case .toolCallLimitExceeded: return .toolCall
        }
    }

    /// A plan's message as the gateway's.
    static func message(_ message: ContinuationMessage) -> LLMMessage {
        LLMMessage(role: message.role == .assistant ? .assistant : .user, content: message.content)
    }

    static func outcome(_ record: Record, limit: Int) -> StageOutcome {
        switch record {
        case .none:
            return .noOp(reason: "no stop reason reached the app: the stream was cut short or the turn "
                + "ended in the tool loop")
        case let .stopped(reason):
            return .noOp(reason: "the model stopped on its own (\(describe(reason)))")
        case let .cut(cutAt, outcome):
            guard outcome.isComplete else {
                return .refused(refusal(cutAt: cutAt, outcome: outcome, limit: limit))
            }
            let added = outcome.rounds.map(\.added).reduce(0, +)
            let removed = outcome.rounds.flatMap(\.removed).map(describe)
            let note = removed.isEmpty ? "" : "; removed \(removed.joined(separator: ", "))"
            return .ran(
                detail: "cut at the \(limit)-token limit after \(cutAt) characters; one more call finished "
                    + "the answer (+\(added) characters\(note))"
            )
        }
    }

    static func refusal(cutAt: Int, outcome: ContinuationOutcome, limit: Int) -> Refusal {
        let closed = outcome.delivery?.closedFence == nil ? "" : ", with its code block closed"
        return Refusal(
            stage: .answerContinuation,
            headline: "The answer was cut off at the length limit",
            explanation: "The model used all \(limit) output tokens after \(cutAt) characters, and "
                + "\(why(outcome.status)). You are seeing it up to the last complete word, number or "
                + "link\(closed). A lower Effort for this conversation leaves more of the limit for "
                + "the answer.",
            recovery: .retryLater(after: nil)
        )
    }

    /// What continuing did, as the middle of a sentence.
    static func why(_ status: ContinuationStatus) -> String {
        switch status {
        case .notNeeded, .completed:
            return "asking for the rest finished it"
        case let .incomplete(reason):
            switch reason {
            case .continuationDisabled: return "continuing is turned off"
            case .roundLimit: return "asking once more for the rest was cut off too"
            case .noProgress: return "asking for the rest added nothing new"
            case .restarted: return "asking for the rest started the answer over instead"
            case let .stoppedBy(stop): return "asking for the rest stopped for another reason (\(stop))"
            case let .failed(message): return "asking for the rest failed (\(message))"
            }
        }
    }

    static func describe(_ reason: LLMResponse.FinishReason) -> String {
        switch reason {
        case .stop: return "finished"
        case .maxTokens: return "length limit"
        case .toolCallLimitExceeded: return "tool-call limit"
        }
    }

    static func describe(_ removal: StitchRemoval) -> String {
        switch removal {
        case .preamble: return "a preamble"
        case .reopenedFence: return "a reopened code fence"
        case .repeatedText: return "repeated text"
        }
    }
}
