import Foundation
import ProviderGatewayKit
import StringClaimKit

extension PostModelPipeline {
    /// Whether what the answer says about strings holds once it is run.
    ///
    /// "There are 2 r's in strawberry", "the base64 of hello is aGVsbG8K", a SHA-256 copied from
    /// `echo hello | sha256sum`, `"👍🏽".length // 1`: a model sees tokens, not characters, and states
    /// counts, encodings and digests it never computed (CharBench, AAAI 2026; SubTokenTest, ACL 2026).
    /// After `regexCheck`, on the text the user will see, code blocks included: Python, JavaScript and
    /// Swift results are checked by each language's own rules, and `echo … | command` lines with the
    /// newline `echo` sends.
    ///
    /// Earlier answers in the conversation are replayed through one `StringLedger`, so a wrong claim the
    /// chat already stated is marked as said again rather than reported as new.
    ///
    /// No refusal: the answer is paid for, and one wrong letter count does not make the rest wrong. A
    /// claim that does not hold, or holds only under another reading (spaces left out, base64 without
    /// padding), gets a note under the bubble with the right value and the slip behind it. The note stays
    /// out of the text, the cache and the history.
    static func checkStrings(
        _ review: AnswerReview,
        messages: [LLMMessage],
        trace: inout PipelineTrace
    ) async -> AnswerReview {
        guard review.refusal == nil else {
            let reason = "the answer was withheld, so there is nothing to check"
            trace.record(.stringCheck, .skipped(reason: reason))
            return review
        }
        let ledger = StringLedger()
        for earlier in conversation(messages).dropLast() {
            _ = await ledger.review(earlier.answer)
        }
        let report = await ledger.review(review.publishableText)
        guard !report.flagged.isEmpty else {
            trace.record(.stringCheck, .noOp(reason: report.summary))
            return review
        }
        let corrections = report.corrections.joined(separator: " ")
        trace.record(.stringCheck, .ran(detail: "\(report.summary); \(corrections)"))
        let again = report.repeatedCount > 0
            ? " An earlier answer in this chat stated the same claim." : ""
        var flagged = review
        flagged.stringNote = "String check: " + corrections + again
        return flagged
    }
}
