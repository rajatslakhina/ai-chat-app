import ComposeCommandClaimKit
import Foundation
import ProviderGatewayKit

extension PostModelPipeline {
    /// Whether what the answer says a compose service runs holds by compose's own reading of `command:` and
    /// `entrypoint:`.
    ///
    /// Answers explain a broken service with the wrong picture of how compose starts it: `command: npm
    /// install && npm start` said to run through a shell (compose splits the string into words with no shell
    /// and stops at `&&`, so only `npm install` runs), `$GREETING` said to come from the service's
    /// `environment:` (compose fills it from the shell or `.env` when it reads the file), an `entrypoint:`
    /// such as `tini` said to keep the image's `CMD` (it drops it), `docker compose run web npm test` said to
    /// add to the command (it replaces it). Each file passes `docker compose config`. After `mergeCheck`, on
    /// the text the user will see: ComposeCommandClaimKit reads the compose file, the Dockerfile and the
    /// `.env` the chat shows, works out the process each service starts, and checks the command lines and
    /// rules the answer states and the `command:` lines of the last compose file it shows. A stated command
    /// line is wrong only when a named misreading reproduces it.
    ///
    /// Earlier answers are replayed through one `CommandLedger`, each with its question, so files shown
    /// earlier count and a claim stated again after a note is marked. A Kubernetes manifest, where `command:`
    /// means the opposite, is left alone.
    ///
    /// No refusal: the answer is paid for, and one misread command does not make the rest wrong. A claim that
    /// does not hold gets a note under the bubble with what compose actually runs. The note stays out of the
    /// text, the cache and the history.
    static func checkComposeCommands(
        _ review: AnswerReview,
        messages: [LLMMessage],
        trace: inout PipelineTrace
    ) async -> AnswerReview {
        guard review.refusal == nil else {
            let reason = "the answer was withheld, so there is nothing to check"
            trace.record(.commandCheck, .skipped(reason: reason))
            return review
        }
        let ledger = CommandLedger()
        let turns = conversation(messages)
        for earlier in turns.dropLast() {
            _ = await ledger.review(earlier.answer, context: earlier.question)
        }
        let report = await ledger.review(review.publishableText, context: turns.last?.question ?? "")
        guard !report.flagged.isEmpty else {
            trace.record(.commandCheck, .noOp(reason: report.summary))
            return review
        }
        let corrections = report.corrections.joined(separator: " ")
        trace.record(.commandCheck, .ran(detail: "\(report.summary); \(corrections)"))
        let again = report.repeatedCount > 0 ? " An earlier answer in this chat stated the same claim." : ""
        var flagged = review
        flagged.commandNote = "Compose command check: " + corrections + again
        return flagged
    }
}
