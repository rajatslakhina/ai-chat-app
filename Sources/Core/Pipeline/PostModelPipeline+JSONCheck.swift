import Foundation
import JSONClaimKit
import ProviderGatewayKit

extension PostModelPipeline {
    /// Whether what the answer says about JSON holds once it is parsed and run.
    ///
    /// A block labeled `json` with a trailing comma or single quotes, `json.dumps(user)` shown with
    /// JavaScript's spacing, `JSON.parse` keeping an id past 2^53, `jq -r` output shown with its quotes:
    /// each reads like a right answer and costs the person who pastes it. After `stringCheck`, on the text
    /// the user will see, code blocks included: blocks labeled `json` are parsed strictly, Python and
    /// JavaScript JSON calls are run by each language's rules, and jq commands against the input they echo.
    ///
    /// Earlier answers in the conversation are replayed through one `JSONLedger`, so a broken block or a
    /// wrong result the chat already gave is marked as stated again rather than reported as new.
    ///
    /// No refusal: the answer is paid for, and one bad comma does not make the rest wrong. A claim that does
    /// not hold, or needs a second look (a repeated key, an integer JavaScript rounds, a block that parses
    /// only as JSON with comments), gets a note under the bubble with what really comes out and the slip
    /// behind it. The note stays out of the text, the cache and the history.
    static func checkJSON(
        _ review: AnswerReview,
        messages: [LLMMessage],
        trace: inout PipelineTrace
    ) async -> AnswerReview {
        guard review.refusal == nil else {
            let reason = "the answer was withheld, so there is nothing to check"
            trace.record(.jsonCheck, .skipped(reason: reason))
            return review
        }
        let ledger = JSONLedger()
        for earlier in conversation(messages).dropLast() {
            _ = await ledger.review(earlier.answer)
        }
        let report = await ledger.review(review.publishableText)
        guard !report.flagged.isEmpty else {
            trace.record(.jsonCheck, .noOp(reason: report.summary))
            return review
        }
        let corrections = report.corrections.joined(separator: " ")
        trace.record(.jsonCheck, .ran(detail: "\(report.summary); \(corrections)"))
        let again = report.repeatedCount > 0
            ? " An earlier answer in this chat stated the same claim." : ""
        var flagged = review
        flagged.jsonNote = "JSON check: " + corrections + again
        return flagged
    }
}
