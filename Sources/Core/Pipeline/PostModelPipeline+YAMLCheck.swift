import Foundation
import ProviderGatewayKit
import YAMLClaimKit

extension PostModelPipeline {
    /// Whether what the answer says about YAML holds once it is parsed and loaded as PyYAML would.
    ///
    /// `python-version: 3.10` said to stay "3.10" (it is the float 3.1), `[GB, NO, SE]` said to load as three
    /// strings (PyYAML reads `NO` as `False`), `workflow["on"]` (the key became `True`, so it raises
    /// `KeyError`), a block labeled `yaml` with a tab or `: ` inside a value: each reads like a right answer
    /// and breaks a config later. After `jsonCheck`, on the text the user will see, code blocks included:
    /// blocks labeled `yaml` are parsed, sentences about how a value reads are checked with YAML 1.1 and
    /// YAML 1.2 rules, and Python `yaml.safe_load` snippets are run against the YAML block shown before them.
    ///
    /// Earlier answers in the conversation are replayed through one `YAMLLedger`, so a wrong reading the chat
    /// already gave is marked as stated again rather than reported as new.
    ///
    /// No refusal: the answer is paid for, and one unquoted value does not make the rest wrong. A claim
    /// that does not hold, or needs a second look (a repeated key, a value the two YAML versions read
    /// differently, `key:value` with no space), gets a note under the bubble with what really comes out and
    /// the slip behind it. The note stays out of the text, the cache and the history.
    static func checkYAML(
        _ review: AnswerReview,
        messages: [LLMMessage],
        trace: inout PipelineTrace
    ) async -> AnswerReview {
        guard review.refusal == nil else {
            let reason = "the answer was withheld, so there is nothing to check"
            trace.record(.yamlCheck, .skipped(reason: reason))
            return review
        }
        let ledger = YAMLLedger()
        for earlier in conversation(messages).dropLast() {
            _ = await ledger.review(earlier.answer)
        }
        let report = await ledger.review(review.publishableText)
        guard !report.flagged.isEmpty else {
            trace.record(.yamlCheck, .noOp(reason: report.summary))
            return review
        }
        let corrections = report.corrections.joined(separator: " ")
        trace.record(.yamlCheck, .ran(detail: "\(report.summary); \(corrections)"))
        let again = report.repeatedCount > 0
            ? " An earlier answer in this chat stated the same claim." : ""
        var flagged = review
        flagged.yamlNote = "YAML check: " + corrections + again
        return flagged
    }
}
