import LanguageConfusionKit
import ProviderGatewayKit

extension PostModelPipeline {
    /// Whether the answer is in the language the user wrote in, or asked for.
    ///
    /// A user who writes in French and gets a paragraph that switches to English for the sentence that
    /// matters has not been answered, and a model routed through OpenRouter can be any model: language
    /// confusion (Marchisio et al., EMNLP 2024) is worst in exactly the open models a user can pick here.
    /// No other stage reads the language of an answer. After `calendarCheck`, on the text the user will see.
    ///
    /// Earlier turns are replayed through one `LanguageSession`, so "from now on, reply in German" two turns
    /// back still applies, and a short follow-up ("ok, et un set ?") is expected in the conversation's
    /// language. Only user messages are read for the expectation: memory and retrieval go into the system
    /// message. Two identifiers must agree on a sentence before it is judged, so names, headings, code and
    /// quotations are never findings.
    ///
    /// No refusal: the answer is paid for and may still be useful to someone who reads both languages. A
    /// sentence or a word in the wrong language gets a note under the bubble, kept out of the text, the
    /// cache and the history.
    static func checkLanguage(
        _ review: AnswerReview,
        messages: [LLMMessage],
        trace: inout PipelineTrace
    ) async -> AnswerReview {
        guard review.refusal == nil else {
            let reason = "the answer was withheld, so there is nothing to check"
            trace.record(.languageMatch, .skipped(reason: reason))
            return review
        }
        let identifier = AgreeingIdentifier(NaturalLanguageIdentifier(), LexicalIdentifier())
        let session = LanguageSession(checker: LanguageChecker(identifier: identifier))
        let turns = conversation(messages)
        for earlier in turns.dropLast() {
            await session.review(answer: earlier.answer, question: earlier.question)
        }
        let report = await session.review(answer: review.publishableText, question: turns.last?.question)
        guard let note = report.note else {
            trace.record(.languageMatch, .noOp(reason: report.summary))
            return review
        }
        trace.record(.languageMatch, .ran(detail: report.summary))
        var flagged = review
        flagged.languageNote = "Language check: " + note
        return flagged
    }
}
