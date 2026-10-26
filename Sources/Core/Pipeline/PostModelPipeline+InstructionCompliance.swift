import InstructionComplianceKit
import ProviderGatewayKit

extension PostModelPipeline {
    /// Whether the answer kept the instructions in the request a program can check.
    ///
    /// The other post-model stages judge what the answer says. None of them reads what the user asked
    /// it to look like: "under 80 words", "3 to 5 bullets", "don't use the word synergy", "in lowercase
    /// from now on". After `numberBinding`, so it reads the text the user will see.
    ///
    /// Only user messages are read: memory and retrieved passages go into the system message, so a
    /// passage that says "answer in one word" cannot set an instruction. Standing instructions from
    /// earlier turns count.
    ///
    /// No refusal: the answer has been paid for and may still be useful. A broken instruction gets a
    /// note under the bubble naming each one and what the answer did instead, and how to get a rewrite.
    /// An answer that keeps them once a one-line preamble or sign-off is set aside gets no note.
    static func checkInstructions(
        _ review: AnswerReview,
        messages: [LLMMessage],
        trace: inout PipelineTrace
    ) async -> AnswerReview {
        guard review.refusal == nil else {
            let reason = "the answer was withheld, so there is nothing to check"
            trace.record(.instructionCompliance, .skipped(reason: reason))
            return review
        }
        let userTexts = messages.filter { $0.role == .user }.map(\.content)
        guard let plan = await InstructionPlanner.plan(userTexts: userTexts), !plan.directives.isEmpty else {
            trace.record(.instructionCompliance, .noOp(reason: "no instructions a program can check"))
            return review
        }
        let report = ComplianceChecker().report(answer: review.publishableText, directives: plan.directives)
        let kept = report.results.filter(\.metLoosely).count
        let tally = "\(kept) of \(report.results.count) kept"
        guard report.verdict == .violated, let note = report.note else {
            trace.record(.instructionCompliance, .noOp(reason: "\(report.verdict.rawValue): \(tally)"))
            return review
        }
        let broken = report.violated.map { "\($0.directive.summary) (\($0.observed))" }
            .joined(separator: "; ")
        trace.record(.instructionCompliance, .ran(detail: "violated: \(tally); \(broken)"))
        var flagged = review
        flagged.instructionNote = note + " Ask for a rewrite that follows them."
        return flagged
    }
}
