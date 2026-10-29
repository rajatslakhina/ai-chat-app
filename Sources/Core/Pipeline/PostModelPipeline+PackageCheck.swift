import Foundation
import PackageClaimKit

extension PostModelPipeline {
    /// Whether the packages the answer tells someone to install exist, on the registry its command uses,
    /// at the version it pins.
    ///
    /// Models invent package names, and invent the same ones again (Spracklen et al., USENIX Security
    /// 2025: at least 5.2% of the packages commercial models suggested did not exist), so an attacker can
    /// register them and wait. A code block is the part of an answer people paste into a terminal without
    /// reading. No other stage reads commands. After `languageMatch`, on the text the user will see.
    ///
    /// The vetter asks PyPI, npm and crates.io over HTTPS, so this is the one post-model stage that makes
    /// requests of its own: only package names leave the device, and an answer with no install command or
    /// manifest in its code makes none. One vetter lives as long as the app, so a name is fetched once.
    ///
    /// No refusal: the answer is paid for, and the user may know the name is fine. A name that does not
    /// exist, a pinned version that was never released, or a package that is days old, deprecated or a
    /// near-spelling of a well-known one gets a note under the bubble, kept out of the text, the cache and
    /// the history. A registry that cannot be reached is a failed stage, not a clean answer.
    func checkPackages(_ review: AnswerReview, now: Date, trace: inout PipelineTrace) async -> AnswerReview {
        guard review.refusal == nil else {
            let reason = "the answer was withheld, so there is nothing to check"
            trace.record(.packageCheck, .skipped(reason: reason))
            return review
        }
        guard let packages else {
            trace.record(.packageCheck, .skipped(reason: "no package registry is configured"))
            return review
        }
        let report = await packages.review(review.publishableText, now: now)
        guard let note = report.note else {
            let quiet: StageOutcome = report.verdict == .unchecked
                ? .failed(message: report.summary) : .noOp(reason: report.summary)
            trace.record(.packageCheck, quiet)
            return review
        }
        trace.record(.packageCheck, .ran(detail: report.summary))
        var flagged = review
        flagged.packageNote = "Package check: " + note
        return flagged
    }
}
