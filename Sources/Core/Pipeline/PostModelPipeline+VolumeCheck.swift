import ComposeVolumeClaimKit
import Foundation
import ProviderGatewayKit

extension PostModelPipeline {
    /// Whether what the answer says about compose volumes and bind mounts holds by what Docker Compose and
    /// the engine do.
    ///
    /// Answers explain lost or stale data with the wrong picture of volumes: `docker compose down` said to
    /// delete named volumes (only `down -v` does), `up --build` said to refresh the `node_modules` volume
    /// (compose keeps it, and Docker never copies into a volume that has files), compose said to create a
    /// missing `external` volume, `data:/x` read as the project's `data` folder (a bare name is a named
    /// volume), a volume's name given without the `<project>_` prefix. After `healthcheckCheck`, on the text
    /// the user will see: ComposeVolumeClaimKit reads the compose file and `.env` the chat shows, and checks
    /// the statements the answer makes and the volume lines of its own last compose file (a line the question
    /// already showed is not flagged).
    ///
    /// Earlier answers are replayed through one `VolumeLedger`, each with its question, so a file shown
    /// earlier counts and a claim stated again after a note is marked. Sentences about `docker run`,
    /// Kubernetes, Swarm or Podman, where the same words hold, are left alone.
    ///
    /// No refusal: the answer is paid for, and one misread volume does not make the rest wrong. A claim that
    /// does not hold gets a note under the bubble with what compose does. The note stays out of the text, the
    /// cache and the history.
    static func checkVolumes(
        _ review: AnswerReview,
        messages: [LLMMessage],
        trace: inout PipelineTrace
    ) async -> AnswerReview {
        guard review.refusal == nil else {
            let reason = "the answer was withheld, so there is nothing to check"
            trace.record(.volumeCheck, .skipped(reason: reason))
            return review
        }
        let ledger = VolumeLedger()
        let turns = conversation(messages)
        for earlier in turns.dropLast() {
            _ = await ledger.review(earlier.answer, context: earlier.question)
        }
        let report = await ledger.review(review.publishableText, context: turns.last?.question ?? "")
        guard !report.flagged.isEmpty else {
            trace.record(.volumeCheck, .noOp(reason: report.summary))
            return review
        }
        let corrections = report.corrections.joined(separator: " ")
        trace.record(.volumeCheck, .ran(detail: "\(report.summary); \(corrections)"))
        let again = report.repeatedCount > 0 ? " An earlier answer in this chat stated the same claim." : ""
        var flagged = review
        flagged.volumeNote = "Volume check: " + corrections + again
        return flagged
    }
}
