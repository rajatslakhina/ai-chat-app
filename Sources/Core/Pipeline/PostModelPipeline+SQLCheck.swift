import Foundation
import ProviderGatewayKit
import SQLClaimKit

extension PostModelPipeline {
    /// Whether what the answer says its SQL returns holds once the SQL runs on the data the answer shows.
    ///
    /// `WHERE email = NULL` shown returning two customers (it returns none), a `LEFT JOIN` filtered in
    /// `WHERE` shown keeping every customer (it drops the ones with no match), `NOT IN` over a column with a
    /// NULL shown finding three rows (it finds none), `SELECT 245 / 3;  -- 81.67` in SQLite (it gives 81):
    /// each reads like a right answer. After `tomlCheck`, on the text the user will see: the answer's SQL
    /// blocks run, in order, in a private in-memory SQLite database (no files, no `ATTACH`, a step budget),
    /// and the output the answer states (a table, a row count, a value in a comment, "this runs") is
    /// compared with what comes back.
    ///
    /// SQL whose tables the answer never creates is left alone: most SQL in chat queries a schema the app
    /// cannot see, and it gets no note. Results that differ between engines, with no engine named, are a
    /// second look rather than a mistake; an answer for PostgreSQL or MySQL is not judged.
    ///
    /// Earlier answers are replayed through one `SQLLedger`, so a wrong result the chat already gave is
    /// marked as stated again. No refusal: a note under the bubble, kept out of the text, the cache and the
    /// history.
    static func checkSQL(
        _ review: AnswerReview,
        messages: [LLMMessage],
        trace: inout PipelineTrace
    ) async -> AnswerReview {
        guard review.refusal == nil else {
            let reason = "the answer was withheld, so there is nothing to check"
            trace.record(.sqlCheck, .skipped(reason: reason))
            return review
        }
        let ledger = SQLLedger()
        for earlier in conversation(messages).dropLast() {
            _ = await ledger.review(earlier.answer)
        }
        let report = await ledger.review(review.publishableText)
        guard !report.flagged.isEmpty else {
            trace.record(.sqlCheck, .noOp(reason: report.summary))
            return review
        }
        let corrections = report.corrections.joined(separator: " ")
        trace.record(.sqlCheck, .ran(detail: "\(report.summary); \(corrections)"))
        let again = report.repeatedCount > 0
            ? " An earlier answer in this chat stated the same claim." : ""
        var flagged = review
        flagged.sqlNote = "SQL check: " + corrections + again
        return flagged
    }
}
