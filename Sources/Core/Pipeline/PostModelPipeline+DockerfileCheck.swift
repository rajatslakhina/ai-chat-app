import DockerfileClaimKit
import Foundation
import ProviderGatewayKit

extension PostModelPipeline {
    /// Whether what the answer says about a Dockerfile holds by Docker's own rules.
    ///
    /// Answers explain their Dockerfiles as if Docker read them like a shell script or like `cp -r`: `COPY
    /// src /app` said to keep the `src` folder (Docker copies what is inside it), `RUN cd /app` on a line of
    /// its own (each `RUN` is a new shell), an `ARG` declared above `FROM` and used in a `RUN` (empty until
    /// the stage declares it again), `$PORT` in an exec-form `CMD` (no shell expands it), a build stage's
    /// `ENV` said to reach a final stage built from a fresh image. Each one builds and then fails when the
    /// container runs. After `dockerignoreCheck`, on the text the user will see: the Dockerfile lines the
    /// answer shows and the claims in its prose are judged against DockerfileClaimKit's model of Docker's
    /// parser, variables, stages and `COPY`. Something that holds only under a setup the answer does not
    /// state (a destination the base image may already have) is a second look.
    ///
    /// Two kinds of finding stay out of the note and go to the trace only: a file the .dockerignore keeps out
    /// (`dockerignoreCheck` already says so, and one mistake gets one note), and a line only the classic
    /// builder was seen to stop on (several sources copied to `.`): BuildKit, Docker's default builder, was
    /// not checked.
    ///
    /// Earlier answers are replayed through one `DockerfileLedger`, each with its question; the ledger keeps
    /// the last Dockerfile the chat showed, so "yes, it ends up at `/app/src/index.js`" in a later turn is
    /// judged against it and marked as said again. Nothing is read in a turn whose answer and question never
    /// mention a Dockerfile.
    ///
    /// No refusal: the answer is paid for, and one misread line does not make the rest wrong. A claim that
    /// does not hold gets a note under the bubble with what Docker does, the slip behind it and a line that
    /// does what the answer meant. The note stays out of the text, the cache and the history.
    static func checkDockerfile(
        _ review: AnswerReview,
        messages: [LLMMessage],
        trace: inout PipelineTrace
    ) async -> AnswerReview {
        guard review.refusal == nil else {
            let reason = "the answer was withheld, so there is nothing to check"
            trace.record(.dockerfileCheck, .skipped(reason: reason))
            return review
        }
        let ledger = DockerfileLedger()
        let turns = conversation(messages)
        for earlier in turns.dropLast() {
            _ = await ledger.review(earlier.answer, context: earlier.question)
        }
        let report = await ledger.review(review.publishableText, context: turns.last?.question ?? "")
        guard !report.flagged.isEmpty else {
            trace.record(.dockerfileCheck, .noOp(reason: report.summary))
            return review
        }
        let shown = report.flagged.filter(belongsUnderBubble)
        guard !shown.isEmpty else {
            let kept = report.corrections.joined(separator: " ")
            let detail = "\(report.summary); not shown under the answer: \(kept)"
            trace.record(.dockerfileCheck, .ran(detail: detail))
            return review
        }
        let corrections = shown.map(\.explanation).joined(separator: " ")
        trace.record(.dockerfileCheck, .ran(detail: "\(report.summary); \(corrections)"))
        let again = shown.contains(where: \.isRepeated)
            ? " An earlier answer in this chat stated the same claim." : ""
        var flagged = review
        flagged.dockerfileNote = "Dockerfile check: " + corrections + again
        return flagged
    }

    /// A finding the user should see under the answer. A file the .dockerignore keeps out is
    /// `dockerignoreCheck`'s note; a line only the classic builder stops on is not worth a note while
    /// BuildKit is unchecked.
    static func belongsUnderBubble(_ finding: DockerfileFinding) -> Bool {
        switch finding.outcome {
        case .wrong(.excludedByDockerignore?), .caveat(.classicBuilderStops),
             .caveat(.placement(.classicStops)):
            false
        default:
            true
        }
    }
}
