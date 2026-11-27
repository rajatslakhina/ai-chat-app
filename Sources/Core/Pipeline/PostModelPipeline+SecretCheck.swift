import ComposeSecretClaimKit
import Foundation
import ProviderGatewayKit

extension PostModelPipeline {
    /// Whether what the answer says about compose secrets and configs holds by what plain `docker compose`
    /// (not Swarm) does.
    ///
    /// Answers about secrets carry Swarm's picture or an env-var one into plain compose: a secret said to
    /// become an environment variable (it is a file, `/run/secrets/<name>`), Swarm said to be needed (only
    /// `external: true` needs it), `docker compose up` said to read an `external` secret (it stops with
    /// "unsupported external secret"), compose said to encrypt secrets or keep them on a tmpfs, `mode: 0400`
    /// said to lock down a `file:` secret (compose bind-mounts the host file and ignores it), a path compose
    /// does not mount the secret on. After `volumeCheck`, on the text the user will see:
    /// ComposeSecretClaimKit reads the compose file and `.env` the chat shows, and checks the statements the
    /// answer makes and the secret and config lines of its own last compose file (a line the question already
    /// showed is not flagged).
    ///
    /// Earlier answers are replayed through one `SecretLedger`, each with its question, so a file shown
    /// earlier counts and a claim stated again after a note is marked. A conversation that deploys with Swarm
    /// (`docker stack deploy`) keeps its external, encryption and tmpfs statements, which are true there, and
    /// sentences about Kubernetes, Vault or build-time secrets are left alone.
    ///
    /// No refusal: the answer is paid for, and one misread secret does not make the rest wrong. A claim that
    /// does not hold gets a note under the bubble with what compose does. The note stays out of the text, the
    /// cache and the history.
    static func checkSecrets(
        _ review: AnswerReview,
        messages: [LLMMessage],
        trace: inout PipelineTrace
    ) async -> AnswerReview {
        guard review.refusal == nil else {
            let reason = "the answer was withheld, so there is nothing to check"
            trace.record(.secretCheck, .skipped(reason: reason))
            return review
        }
        let ledger = SecretLedger()
        let turns = conversation(messages)
        for earlier in turns.dropLast() {
            _ = await ledger.review(earlier.answer, context: earlier.question)
        }
        let report = await ledger.review(review.publishableText, context: turns.last?.question ?? "")
        guard !report.flagged.isEmpty else {
            trace.record(.secretCheck, .noOp(reason: report.summary))
            return review
        }
        let corrections = report.corrections.joined(separator: " ")
        trace.record(.secretCheck, .ran(detail: "\(report.summary); \(corrections)"))
        let again = report.repeatedCount > 0 ? " An earlier answer in this chat stated the same claim." : ""
        var flagged = review
        flagged.secretNote = "Secret check: " + corrections + again
        return flagged
    }
}
