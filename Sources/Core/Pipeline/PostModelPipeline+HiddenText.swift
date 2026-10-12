import HiddenTextKit

extension PostModelPipeline {
    /// The answer with out-of-place invisible runs removed, and whether anything was.
    ///
    /// Before the output guardrail for the same reason the input stage runs before the input one.
    /// And before anything else reads the answer, because everything downstream of this review
    /// keeps the reviewed text: the bubble, the response cache, the conversation title, and the
    /// history every later turn re-sends. A note to "the next agent" hidden in tag characters
    /// would otherwise be re-read by the model on every turn after this one, and copied by anyone
    /// who copies the answer.
    ///
    /// The live bubble shows fragments before this runs. They are replaced by the reviewed text
    /// when the turn completes, so hidden scalars are only on screen, invisibly, while it streams.
    static func removeHiddenText(
        fromAnswer answer: String,
        trace: inout PipelineTrace
    ) -> (text: String, modified: Bool) {
        let cleaned = HiddenTextSanitizer().sanitize(answer)
        guard cleaned.report.suspiciousScalarCount > 0 else {
            trace.record(.hiddenTextOutput, .noOp(reason: "no hidden text in the answer"))
            return (answer, false)
        }
        trace.record(
            .hiddenTextOutput,
            .ran(detail: "removed before display and history - " + HiddenTextDetail.describe(cleaned.report))
        )
        return (cleaned.text, true)
    }
}
