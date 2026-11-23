import ComposeMergeClaimKit
import Foundation
import ProviderGatewayKit

extension PostModelPipeline {
    /// Whether what the answer says a base compose file and its override do together holds by compose's merge
    /// rules.
    ///
    /// Answers show `docker-compose.yml` and `docker-compose.override.yml` and then describe the merged
    /// result with the wrong picture of the merge: the override's `ports` said to replace the base ones
    /// (compose appends them, so both stay published), `LOG_LEVEL` said to be gone because the override sets
    /// `environment` (it merges key by key), `ports: []` said to clear the base ports (it adds nothing;
    /// `!reset []` clears), the override said to still apply with `-f docker-compose.yml` (only the files
    /// named are read). Each passes `docker compose config` and shows up only when the stack runs. After
    /// `composeCheck`, on the text the user will see: ComposeMergeClaimKit merges the files the chat shows
    /// the way compose picks them and checks the ports, image, command and variables the answer states, and
    /// the merge rules it states. A stated result is wrong only when a named misreading of the merge
    /// reproduces it.
    ///
    /// Earlier answers are replayed through one `MergeLedger`, each with its question, so files shown earlier
    /// count and a claim stated again after a note is marked. Nothing is read in a turn that neither shows
    /// two compose files nor talks about overrides, `-f` lists or merging.
    ///
    /// No refusal: the answer is paid for, and one misread merge does not make the rest wrong. A claim that
    /// does not hold gets a note under the bubble with what compose actually does. The note stays out of the
    /// text, the cache and the history.
    static func checkComposeMerge(
        _ review: AnswerReview,
        messages: [LLMMessage],
        trace: inout PipelineTrace
    ) async -> AnswerReview {
        guard review.refusal == nil else {
            let reason = "the answer was withheld, so there is nothing to check"
            trace.record(.mergeCheck, .skipped(reason: reason))
            return review
        }
        let ledger = MergeLedger()
        let turns = conversation(messages)
        for earlier in turns.dropLast() {
            _ = await ledger.review(earlier.answer, context: earlier.question)
        }
        let report = await ledger.review(review.publishableText, context: turns.last?.question ?? "")
        guard !report.flagged.isEmpty else {
            trace.record(.mergeCheck, .noOp(reason: report.summary))
            return review
        }
        let corrections = report.corrections.joined(separator: " ")
        trace.record(.mergeCheck, .ran(detail: "\(report.summary); \(corrections)"))
        let again = report.repeatedCount > 0 ? " An earlier answer in this chat stated the same claim." : ""
        var flagged = review
        flagged.mergeNote = "Compose merge check: " + corrections + again
        return flagged
    }
}
