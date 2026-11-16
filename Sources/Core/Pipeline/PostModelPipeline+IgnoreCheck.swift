import Foundation
import GitignoreClaimKit
import ProviderGatewayKit

extension PostModelPipeline {
    /// Whether what the answer says about .gitignore rules holds by git's own matching.
    ///
    /// `logs/` followed by `!logs/keep.log` said to keep the file (git never looks inside an excluded
    /// directory), `node_modules/  # dependencies` written as one line (`#` starts a comment only at the
    /// start of a line, so it ignores nothing), `doc/*.txt` said to match `doc/server/arch.txt` (`*` stops
    /// at `/`), a committed `.env` said to stop being tracked once it is listed: each reads like a right
    /// answer and leaves a secret committed or a file missing. After `rangeCheck`, on the text the user
    /// will see: claims in the prose, and the lines of any `.gitignore` the answer shows, are judged with a
    /// port of git's matcher. Another tool's ignore file (`.dockerignore`, `.npmignore`) is recognised and
    /// not checked; a claim that depends on `core.ignorecase` is a second look rather than a verdict.
    ///
    /// Earlier answers in the conversation are replayed through one `IgnoreLedger`, so a wrong claim the
    /// chat already gave is marked as stated again rather than reported as new.
    ///
    /// No refusal: the answer is paid for, and one misread pattern does not make the rest wrong. A claim
    /// that does not hold gets a note under the bubble with what git does, the slip behind it and a line
    /// that does what the answer meant. The note stays out of the text, the cache and the history.
    static func checkIgnoreRules(
        _ review: AnswerReview,
        messages: [LLMMessage],
        trace: inout PipelineTrace
    ) async -> AnswerReview {
        guard review.refusal == nil else {
            let reason = "the answer was withheld, so there is nothing to check"
            trace.record(.ignoreCheck, .skipped(reason: reason))
            return review
        }
        let ledger = IgnoreLedger()
        for earlier in conversation(messages).dropLast() {
            _ = await ledger.review(earlier.answer)
        }
        let report = await ledger.review(review.publishableText)
        guard !report.flagged.isEmpty else {
            trace.record(.ignoreCheck, .noOp(reason: report.summary))
            return review
        }
        let corrections = report.corrections.joined(separator: " ")
        trace.record(.ignoreCheck, .ran(detail: "\(report.summary); \(corrections)"))
        let again = report.repeatedCount > 0
            ? " An earlier answer in this chat stated the same claim." : ""
        var flagged = review
        flagged.ignoreNote = "Gitignore check: " + corrections + again
        return flagged
    }
}
