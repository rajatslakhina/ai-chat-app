import Foundation
import ProviderGatewayKit
import VersionRangeClaimKit

extension PostModelPipeline {
    /// Whether what the answer says about version ranges holds by the package manager's own rules.
    ///
    /// `^0.2.3` said to pick up 0.3.0 (on 0.x a caret moves only the patch number), `requests^2.31` in
    /// a `requirements.txt` (pip has no caret), `~=4.2` said to allow Django 5.0, SwiftPM's
    /// `from: "0.9.0"` said to stay below 0.10.0 (it goes to 1.0.0): each reads like a right answer and
    /// installs something else, or nothing. After `sqlCheck`, on the text the user will see: ranges
    /// written as inline code are read with the rules of npm, pip (PEP 440), RubyGems or SwiftPM, and
    /// so are the dependency lines in code blocks. When the answer names no package manager and they
    /// read a range differently, the claim is left unchecked rather than judged; Cargo, Composer and
    /// Poetry ranges are recognised and not checked.
    ///
    /// Earlier answers in the conversation are replayed through one `RangeLedger`, so a wrong claim the
    /// chat already gave is marked as stated again rather than reported as new.
    ///
    /// No refusal: the answer is paid for, and one misread range does not make the rest wrong. A claim
    /// that does not hold, or a pre-release pip would skip without `--pre`, gets a note under the bubble
    /// with what the range really means and the slip behind it. The note stays out of the text, the
    /// cache and the history.
    static func checkRanges(
        _ review: AnswerReview,
        messages: [LLMMessage],
        trace: inout PipelineTrace
    ) async -> AnswerReview {
        guard review.refusal == nil else {
            let reason = "the answer was withheld, so there is nothing to check"
            trace.record(.rangeCheck, .skipped(reason: reason))
            return review
        }
        let ledger = RangeLedger()
        for earlier in conversation(messages).dropLast() {
            _ = await ledger.review(earlier.answer)
        }
        let report = await ledger.review(review.publishableText)
        guard !report.flagged.isEmpty else {
            trace.record(.rangeCheck, .noOp(reason: report.summary))
            return review
        }
        let corrections = report.corrections.joined(separator: " ")
        trace.record(.rangeCheck, .ran(detail: "\(report.summary); \(corrections)"))
        let again = report.repeatedCount > 0
            ? " An earlier answer in this chat stated the same claim." : ""
        var flagged = review
        flagged.rangeNote = "Version range check: " + corrections + again
        return flagged
    }
}
