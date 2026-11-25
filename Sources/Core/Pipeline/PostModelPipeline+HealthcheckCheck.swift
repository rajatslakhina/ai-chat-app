import Foundation
import HealthcheckClaimKit
import ProviderGatewayKit

extension PostModelPipeline {
    /// Whether what the answer says about a container healthcheck holds by what Docker Compose and the
    /// engine do.
    ///
    /// Answers explain an unhealthy container with the wrong picture of how Docker checks it: the exec form
    /// `["CMD", "curl", ..., "||", "exit", "1"]` said to run through a shell (the engine execs it, so `||`
    /// reaches `curl` as an argument), Docker said to restart an unhealthy container under `restart: always`
    /// (it only marks it), `$API_TOKEN` in `test:` said to come from the service's `environment:` (compose
    /// substitutes it from the shell and `.env` when it reads the file), a wrong default `interval`, a
    /// compose override said to drop the image's `HEALTHCHECK` command. After `commandCheck`, on the text the
    /// user will see: HealthcheckClaimKit reads the compose file, Dockerfile and `.env` the chat shows, and
    /// checks the rules and defaults the answer states and the healthcheck lines of its own last compose
    /// file and Dockerfile (a line the question already showed is not flagged).
    ///
    /// Earlier answers are replayed through one `HealthLedger`, each with its question, so files shown
    /// earlier count and a claim stated again after a note is marked. Sentences about Kubernetes probes,
    /// Swarm or autoheal, where "unhealthy is restarted" holds, are left alone.
    ///
    /// No refusal: the answer is paid for, and one misread healthcheck does not make the rest wrong. A claim
    /// that does not hold gets a note under the bubble with what Docker does. The note stays out of the text,
    /// the cache and the history.
    static func checkHealthchecks(
        _ review: AnswerReview,
        messages: [LLMMessage],
        trace: inout PipelineTrace
    ) async -> AnswerReview {
        guard review.refusal == nil else {
            let reason = "the answer was withheld, so there is nothing to check"
            trace.record(.healthcheckCheck, .skipped(reason: reason))
            return review
        }
        let ledger = HealthLedger()
        let turns = conversation(messages)
        for earlier in turns.dropLast() {
            _ = await ledger.review(earlier.answer, context: earlier.question)
        }
        let report = await ledger.review(review.publishableText, context: turns.last?.question ?? "")
        guard !report.flagged.isEmpty else {
            trace.record(.healthcheckCheck, .noOp(reason: report.summary))
            return review
        }
        let corrections = report.corrections.joined(separator: " ")
        trace.record(.healthcheckCheck, .ran(detail: "\(report.summary); \(corrections)"))
        let again = report.repeatedCount > 0 ? " An earlier answer in this chat stated the same claim." : ""
        var flagged = review
        flagged.healthcheckNote = "Healthcheck check: " + corrections + again
        return flagged
    }
}
