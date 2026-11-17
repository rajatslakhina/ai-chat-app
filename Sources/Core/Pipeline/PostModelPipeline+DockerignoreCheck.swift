import DockerignoreClaimKit
import Foundation
import ProviderGatewayKit

extension PostModelPipeline {
    /// Whether what the answer says about .dockerignore rules holds by Docker's own matching.
    ///
    /// Answers write a .dockerignore the way they write a .gitignore: `node_modules` and `*.log` said to
    /// match in every package (Docker matches every pattern from the root of the build context), `.env  #
    /// secrets` on one line (`#` starts a comment only at the start of a line, so it excludes nothing), a
    /// `.dockerignore` per service folder (only the root one is read), a warning that listing the
    /// `Dockerfile` breaks the build (it does not). Each leaves a `node_modules` folder or a secret in the
    /// image. After `ignoreCheck`, which leaves another tool's ignore file unchecked, on the text the user
    /// will see: claims in the prose, and the lines of any root `.dockerignore` the answer shows, are judged
    /// with a port of the Docker CLI's matcher. The app does not know which builder the user runs, so a claim
    /// that holds under one builder only (a wildcard exception inside an excluded folder) is a second look
    /// rather than a verdict.
    ///
    /// Earlier answers in the conversation are replayed through one `DockerignoreLedger`, each with its
    /// question, so a wrong claim the chat already gave is marked as stated again. A sentence's own patterns
    /// are read as .dockerignore rules only in a turn whose answer or question names .dockerignore: "`*.log`
    /// matches `logs/a.log`" is true of a .gitignore.
    ///
    /// No refusal: the answer is paid for, and one misread pattern does not make the rest wrong. A claim that
    /// does not hold gets a note under the bubble with what Docker does, the slip behind it and a line that
    /// does what the answer meant. The note stays out of the text, the cache and the history.
    static func checkDockerignoreRules(
        _ review: AnswerReview,
        messages: [LLMMessage],
        trace: inout PipelineTrace
    ) async -> AnswerReview {
        guard review.refusal == nil else {
            let reason = "the answer was withheld, so there is nothing to check"
            trace.record(.dockerignoreCheck, .skipped(reason: reason))
            return review
        }
        let ledger = DockerignoreLedger()
        let turns = conversation(messages)
        for earlier in turns.dropLast() {
            _ = await ledger.review(earlier.answer, context: earlier.question)
        }
        let report = await ledger.review(review.publishableText, context: turns.last?.question ?? "")
        guard !report.flagged.isEmpty else {
            trace.record(.dockerignoreCheck, .noOp(reason: report.summary))
            return review
        }
        let corrections = report.corrections.joined(separator: " ")
        trace.record(.dockerignoreCheck, .ran(detail: "\(report.summary); \(corrections)"))
        let again = report.repeatedCount > 0
            ? " An earlier answer in this chat stated the same claim." : ""
        var flagged = review
        flagged.dockerignoreNote = "Dockerignore check: " + corrections + again
        return flagged
    }
}
