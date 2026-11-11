import Foundation
import ProviderGatewayKit
import TOMLClaimKit

extension PostModelPipeline {
    /// Whether what the answer says about TOML holds once it is parsed and loaded as Python's `tomllib`
    /// would.
    ///
    /// `python_version = 3.10` said to stay "3.10" (it is the float 3.1), `python = ^3.10` in a block called
    /// valid TOML (unquoted text does not parse), `tomllib.load` on a file opened in text mode (it raises
    /// `TypeError`), `data["tool.poetry"]` (the dotted header made nested tables, so it raises `KeyError`),
    /// `tomllib.dumps` (there is no writer in the standard library): each reads like a right answer and
    /// breaks a `pyproject.toml` later. After `yamlCheck`, on the text the user will see, code blocks
    /// included: blocks labeled `toml` are parsed, sentences about how a value reads are checked with
    /// TOML 1.0's rules, and Python `tomllib` snippets are run against the TOML block shown before them.
    ///
    /// Earlier answers in the conversation are replayed through one `TOMLLedger`, so a wrong claim the chat
    /// already gave is marked as stated again rather than reported as new.
    ///
    /// No refusal: the answer is paid for, and one unquoted value does not make the rest wrong. A claim
    /// that does not hold, or needs a second look (an unquoted float written with a trailing zero, a dotted
    /// key made of digits), gets a note under the bubble with what really comes out and the slip behind it.
    /// The note stays out of the text, the cache and the history.
    static func checkTOML(
        _ review: AnswerReview,
        messages: [LLMMessage],
        trace: inout PipelineTrace
    ) async -> AnswerReview {
        guard review.refusal == nil else {
            let reason = "the answer was withheld, so there is nothing to check"
            trace.record(.tomlCheck, .skipped(reason: reason))
            return review
        }
        let ledger = TOMLLedger()
        for earlier in conversation(messages).dropLast() {
            _ = await ledger.review(earlier.answer)
        }
        let report = await ledger.review(review.publishableText)
        guard !report.flagged.isEmpty else {
            trace.record(.tomlCheck, .noOp(reason: report.summary))
            return review
        }
        let corrections = report.corrections.joined(separator: " ")
        trace.record(.tomlCheck, .ran(detail: "\(report.summary); \(corrections)"))
        let again = report.repeatedCount > 0
            ? " An earlier answer in this chat stated the same claim." : ""
        var flagged = review
        flagged.tomlNote = "TOML check: " + corrections + again
        return flagged
    }
}
