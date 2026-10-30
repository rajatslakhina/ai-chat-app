import ArithmeticClaimKit
import Foundation
import ProviderGatewayKit

extension PostModelPipeline {
    /// Whether the arithmetic the answer works out on its own holds.
    ///
    /// "15% of $480 is $62", "from 40 to 50 is a 20% increase", "$100 / 3 = $33.34": a model doing sums in
    /// prose is often wrong (the ORCA benchmark, arXiv 2511.02589: five frontier models right on 45% to 63%
    /// of 500 everyday calculations), and a wrong figure reads exactly like a right one. `numberBinding`
    /// cannot catch these, because a figure the answer computed has nothing to bind to; the arithmetic is
    /// the evidence. After `packageCheck`, on the text the user will see.
    ///
    /// Earlier answers in the conversation are replayed through one `ArithmeticLedger`, so a wrong result
    /// the chat already stated is marked as said again rather than reported as new.
    ///
    /// No refusal: the answer is paid for and most of it may be right. A wrong result, one rounded the
    /// wrong way, or percentage points written as a percent change gets a note under the bubble with the
    /// exact value. The note stays out of the text, the cache and the history.
    static func checkArithmetic(
        _ review: AnswerReview,
        messages: [LLMMessage],
        trace: inout PipelineTrace
    ) async -> AnswerReview {
        guard review.refusal == nil else {
            let reason = "the answer was withheld, so there is nothing to check"
            trace.record(.arithmeticCheck, .skipped(reason: reason))
            return review
        }
        let ledger = ArithmeticLedger()
        for earlier in conversation(messages).dropLast() {
            _ = await ledger.review(earlier.answer)
        }
        let report = await ledger.review(review.publishableText)
        guard !report.flagged.isEmpty else {
            trace.record(.arithmeticCheck, .noOp(reason: report.summary))
            return review
        }
        let corrections = report.corrections.joined(separator: " ")
        trace.record(.arithmeticCheck, .ran(detail: "\(report.summary); \(corrections)"))
        let again = report.repeatedCount > 0 ? " An earlier answer in this chat stated the same result." : ""
        var flagged = review
        flagged.arithmeticNote = "Arithmetic check: " + corrections + again
        return flagged
    }
}
