import EntrypointClaimKit
import Foundation
import ProviderGatewayKit

extension PostModelPipeline {
    /// Whether what the answer says a container runs holds by Docker's rules for `CMD`, `ENTRYPOINT` and
    /// `docker run`.
    ///
    /// Answers explain the command a container starts with the wrong picture of how the pieces
    /// combine: `docker run api --debug` said to keep the `CMD`'s `--port 80` (arguments after the
    /// image replace `CMD`), `docker run -it api bash` said to give a shell (an exec-form `ENTRYPOINT`
    /// gets `bash` as an argument), `--entrypoint` said to keep the `CMD`, a shell-form `ENTRYPOINT`
    /// said to receive the `CMD`, `CMD ['node', 'server.js']` read as the exec form (it is not JSON, so
    /// it runs through `/bin/sh`). Each one builds and then fails when the container starts. After
    /// `dockerfileCheck`, on the text the user will see: run claims, statements and the answer's
    /// `CMD`/`ENTRYPOINT` lines are judged against EntrypointClaimKit's model of Docker's parser,
    /// builder and daemon. A claim under a base image whose `ENTRYPOINT` the answer does not show is
    /// judged only on the part the Dockerfile settles, and a wrapper `ENTRYPOINT` (`tini --`, a lone
    /// script) is taken to run the command it is handed.
    ///
    /// Earlier answers are replayed through one `EntrypointLedger`, each with its question; the ledger
    /// keeps the last Dockerfile and the image tags the chat showed, so "`docker run api --debug` runs
    /// ..." in a later turn is judged against them and marked as said again. Nothing is read in a turn
    /// whose answer and question never mention `CMD`, `ENTRYPOINT`, `docker run` or a Dockerfile.
    ///
    /// No refusal: the answer is paid for, and one misread command does not make the rest wrong. A
    /// claim that does not hold gets a note under the bubble with what the container actually runs and
    /// the slip behind it. The note stays out of the text, the cache and the history. `$VAR` inside
    /// `CMD` is `dockerfileCheck`'s, and EntrypointClaimKit does not read it, so one mistake still gets
    /// one note.
    static func checkEntrypoints(
        _ review: AnswerReview,
        messages: [LLMMessage],
        trace: inout PipelineTrace
    ) async -> AnswerReview {
        guard review.refusal == nil else {
            let reason = "the answer was withheld, so there is nothing to check"
            trace.record(.entrypointCheck, .skipped(reason: reason))
            return review
        }
        let ledger = EntrypointLedger()
        let turns = conversation(messages)
        for earlier in turns.dropLast() {
            _ = await ledger.review(earlier.answer, context: earlier.question)
        }
        let report = await ledger.review(review.publishableText, context: turns.last?.question ?? "")
        guard !report.flagged.isEmpty else {
            trace.record(.entrypointCheck, .noOp(reason: report.summary))
            return review
        }
        let corrections = report.corrections.joined(separator: " ")
        trace.record(.entrypointCheck, .ran(detail: "\(report.summary); \(corrections)"))
        let again = report.repeatedCount > 0 ? " An earlier answer in this chat stated the same claim." : ""
        var flagged = review
        flagged.entrypointNote = "Container command check: " + corrections + again
        return flagged
    }
}
