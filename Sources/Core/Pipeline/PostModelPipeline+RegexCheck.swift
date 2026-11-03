import Foundation
import ProviderGatewayKit
import RegexClaimKit

extension PostModelPipeline {
    /// Whether the regular expressions the answer gives do what it says they do.
    ///
    /// "`^\d{5}$` matches `12345` but not `123456`", a ✅/❌ list, a table of inputs, a JavaScript or
    /// Python line with `// true` after it: a model states what its regex matches without running it, and
    /// the claim reads the same whether or not it holds (Query4Regex, EACL 2026: semantic errors stay
    /// common even in regexes that parse). After `unitCheck`, on the text the user will see. The text
    /// includes code, which is where most regexes are, so this stage reads code blocks that the prose
    /// checks skip.
    ///
    /// Earlier answers in the conversation are replayed through one `RegexLedger`, so a wrong claim the
    /// chat already stated is marked as said again rather than reported as new.
    ///
    /// No refusal: the answer is paid for, and a regex with one wrong example may still be the right
    /// regex. A claim that does not hold, a pattern that does not compile, or one that backtracks without
    /// end gets a note under the bubble that names the slip (missing anchors, case, an unescaped dot, a
    /// greedy quantifier, JavaScript's `g` flag, a string literal that swallowed a backslash). A pattern
    /// that uses something the checker's engine lacks is recorded as unchecked, not judged. The note stays
    /// out of the text, the cache and the history.
    static func checkRegexes(
        _ review: AnswerReview,
        messages: [LLMMessage],
        trace: inout PipelineTrace
    ) async -> AnswerReview {
        guard review.refusal == nil else {
            let reason = "the answer was withheld, so there is nothing to check"
            trace.record(.regexCheck, .skipped(reason: reason))
            return review
        }
        let ledger = RegexLedger()
        for earlier in conversation(messages).dropLast() {
            _ = await ledger.review(earlier.answer)
        }
        let report = await ledger.review(review.publishableText)
        guard !report.flagged.isEmpty else {
            trace.record(.regexCheck, .noOp(reason: report.summary))
            return review
        }
        let corrections = report.corrections.joined(separator: " ")
        trace.record(.regexCheck, .ran(detail: "\(report.summary); \(corrections)"))
        let again = report.repeatedCount > 0
            ? " An earlier answer in this chat stated the same claim." : ""
        var flagged = review
        flagged.regexNote = "Regex check: " + corrections + again
        return flagged
    }
}
