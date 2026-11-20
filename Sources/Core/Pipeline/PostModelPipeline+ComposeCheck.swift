import ComposeClaimKit
import Foundation
import ProviderGatewayKit

extension PostModelPipeline {
    /// Whether what the answer says about a Docker Compose project holds by compose's and Docker's rules.
    ///
    /// Answers wire compose services with the wrong picture of the network and of substitution:
    /// `DATABASE_URL=postgres://db:5433/app` when `db` publishes `5433:5432` (containers reach each
    /// other on the container port, so `db:5433` is refused), `localhost:5432` inside the `api`
    /// container to reach Postgres (there `localhost` is the container itself), `depends_on` said to
    /// wait until the database is ready (it waits for the container to start), `${TAG-latest}` said to
    /// give `latest` for an empty `TAG` (without a colon only an unset one), `.env` said to reach the
    /// containers (it feeds substitution in the compose file only). Each one passes
    /// `docker compose config` and fails at run time. After `entrypointCheck`, on the text the user
    /// will see: addresses, port mappings, substitutions, statements and the compose file's own
    /// `environment:` addresses are judged against ComposeClaimKit's reading of the file, the `.env`
    /// and the `export` lines the chat shows.
    ///
    /// Earlier answers are replayed through one `ComposeLedger`, each with its question; the ledger
    /// keeps the last compose file and the variables, so a later "`app` connects to `db:5433`" is judged
    /// against them and marked as said again. Nothing is read in a turn whose answer and question never
    /// name compose or show a compose file, and a fragment that leaves out a service is not called
    /// wrong for it.
    ///
    /// No refusal: the answer is paid for, and one wrong address does not make the rest wrong. A claim
    /// that does not hold gets a note under the bubble with what compose actually does. The note stays
    /// out of the text, the cache and the history.
    static func checkCompose(
        _ review: AnswerReview,
        messages: [LLMMessage],
        trace: inout PipelineTrace
    ) async -> AnswerReview {
        guard review.refusal == nil else {
            let reason = "the answer was withheld, so there is nothing to check"
            trace.record(.composeCheck, .skipped(reason: reason))
            return review
        }
        let ledger = ComposeLedger()
        let turns = conversation(messages)
        for earlier in turns.dropLast() {
            _ = await ledger.review(earlier.answer, context: earlier.question)
        }
        let report = await ledger.review(review.publishableText, context: turns.last?.question ?? "")
        guard !report.flagged.isEmpty else {
            trace.record(.composeCheck, .noOp(reason: report.summary))
            return review
        }
        let corrections = report.corrections.joined(separator: " ")
        trace.record(.composeCheck, .ran(detail: "\(report.summary); \(corrections)"))
        let again = report.repeatedCount > 0 ? " An earlier answer in this chat stated the same claim." : ""
        var flagged = review
        flagged.composeNote = "Compose check: " + corrections + again
        return flagged
    }
}
