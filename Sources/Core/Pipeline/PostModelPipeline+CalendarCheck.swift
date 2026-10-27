import CalendarClaimKit
import Foundation
import ProviderGatewayKit

extension PostModelPipeline {
    /// Whether the date arithmetic in the answer holds.
    ///
    /// Date math is where a model is confidently wrong: "90 days after March 3 is June 2", "one month
    /// after March 31 is April 31", business days counted as calendar days. `numberBinding` cannot catch
    /// these: a date the model worked out has no tool output or source to bind to. The calendar is the
    /// evidence, so this needs only the answer, the conversation and the clock. After
    /// `instructionCompliance`, on the text the user will see.
    ///
    /// Earlier turns are replayed through one `CalendarSession`, so a year the conversation set ("the
    /// 2027 offsite") applies to "March 17" two turns later. The last user message is the question, so
    /// "A Sunday." answering "What day was July 4, 1976?" is checked, and "90 days later" counts from the
    /// date the user gave.
    ///
    /// No refusal: the answer is paid for and most of it may be right. A wrong date, a date that does
    /// not exist, or a span that holds only counting both ends gets a note under the bubble with the
    /// computed value. The note stays out of the text, the cache and the history.
    static func checkCalendar(
        _ review: AnswerReview,
        messages: [LLMMessage],
        now: Date,
        trace: inout PipelineTrace
    ) async -> AnswerReview {
        guard review.refusal == nil else {
            let reason = "the answer was withheld, so there is nothing to check"
            trace.record(.calendarCheck, .skipped(reason: reason))
            return review
        }
        let session = CalendarSession(checker: CalendarChecker(timeZone: .current))
        let turns = conversation(messages)
        for earlier in turns.dropLast() {
            await session.review(answer: earlier.answer, question: earlier.question)
        }
        let report = await session.review(
            answer: review.publishableText, question: turns.last?.question, now: now
        )
        let tally = "\(report.verdict.rawValue): \(report.count(.verified)) of \(report.checks.count) hold"
        guard let note = report.note else {
            trace.record(.calendarCheck, .noOp(reason: report.checks.isEmpty ? "no calendar claims" : tally))
            return review
        }
        let lines = (report.corrections + report.caveats).joined(separator: " ")
        trace.record(.calendarCheck, .ran(detail: "\(tally); \(lines)"))
        var flagged = review
        flagged.calendarNote = note
        return flagged
    }

    /// Each user message with the assistant answer that followed it. The last one has none: its answer
    /// is the one under review.
    static func conversation(_ messages: [LLMMessage]) -> [(question: String, answer: String)] {
        var turns: [(question: String, answer: String)] = []
        for message in messages {
            switch message.role {
            case .user: turns.append((message.content, ""))
            case .assistant where !turns.isEmpty: turns[turns.count - 1].answer = message.content
            default: break
            }
        }
        return turns
    }
}
