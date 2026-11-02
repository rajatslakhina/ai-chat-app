import Foundation
import ProviderGatewayKit
import UnitClaimKit

extension PostModelPipeline {
    /// Whether the unit conversions the answer makes on its own hold.
    ///
    /// "2 cups of flour (500 g)", "5 miles (3.1 km)", "10°C (50°F) warmer": a model converting units in
    /// prose gets the size or direction of the factor wrong, drops or adds a temperature offset, or weighs
    /// flour as if it were water (NUMCoT, arXiv 2406.02864: unit errors mostly come from the size
    /// relationship between units). `arithmeticCheck` treats units as labels and `numberBinding` converts
    /// only against evidence, so neither sees these. After `arithmeticCheck`, on the text the user will see.
    ///
    /// Earlier answers in the conversation are replayed through one `ConversionLedger`, so a wrong
    /// conversion the chat already stated is marked as said again rather than reported as new.
    ///
    /// No refusal: the answer is paid for and most of it may be right. A wrong conversion, one rounded the
    /// wrong way, or one that holds only for another size of the unit (an imperial gallon, a metric cup)
    /// gets a note under the bubble with the exact value. A cup weighed in grams with no known density is
    /// left unchecked and said so in the trace, not guessed. The note stays out of the text, the cache and
    /// the history.
    static func checkUnits(
        _ review: AnswerReview,
        messages: [LLMMessage],
        trace: inout PipelineTrace
    ) async -> AnswerReview {
        guard review.refusal == nil else {
            let reason = "the answer was withheld, so there is nothing to check"
            trace.record(.unitCheck, .skipped(reason: reason))
            return review
        }
        let ledger = ConversionLedger()
        for earlier in conversation(messages).dropLast() {
            _ = await ledger.review(earlier.answer)
        }
        let report = await ledger.review(review.publishableText)
        guard !report.flagged.isEmpty else {
            trace.record(.unitCheck, .noOp(reason: report.summary))
            return review
        }
        let corrections = report.corrections.joined(separator: " ")
        trace.record(.unitCheck, .ran(detail: "\(report.summary); \(corrections)"))
        let again = report.repeatedCount > 0
            ? " An earlier answer in this chat stated the same conversion." : ""
        var flagged = review
        flagged.unitNote = "Unit check: " + corrections + again
        return flagged
    }
}
