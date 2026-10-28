import GuardrailKit
import ProviderGatewayKit
import Testing
@testable import AIChatApp

private let frenchQuestion = "Quelle est la différence entre une liste et un tuple en Python ?"
private let frenchAnswer = "Une liste est modifiable, alors qu'un tuple ne l'est pas."
private let englishSentence = "In practice, you should use a tuple when the data must not change."

private func review(_ answer: String, conversation: [LLMMessage]) async -> (AnswerReview, PipelineTrace) {
    let pipeline = PostModelPipeline(guardrail: GuardrailPipeline(policy: GuardrailPolicy()))
    var trace = PipelineTrace()
    let reviewed = await pipeline.review(answer: answer, sources: [], messages: conversation, trace: &trace)
    return (reviewed, trace)
}

private func user(_ text: String) -> LLMMessage { LLMMessage(role: .user, content: text) }
private func assistant(_ text: String) -> LLMMessage { LLMMessage(role: .assistant, content: text) }

@Suite("LanguageConfusionKit - the answer in the language the user wrote in or asked for")
struct LanguageMatchStageTests {
    @Test("an English sentence in a French answer gets a note, after calendarCheck, and the text is unchanged")
    func mixedSentencesGetANote() async throws {
        let answer = frenchAnswer + " " + englishSentence
        let (reviewed, trace) = await review(answer, conversation: [user(frenchQuestion)])
        #expect(reviewed.publishableText == answer)
        #expect(reviewed.languageNote == "Language check: 1 of 2 sentences is in English, not French "
            + "(you wrote in French): “In practice, you should use a tuple when the data must not…”.")
        #expect(trace.outcome(for: .languageMatch)
            == .ran(detail: "mixedSentences (expected French, userMessage; 2 judged, 1 wrong, 0 stray)"))
        let stages = trace.records.map(\.stage)
        let language = try #require(stages.firstIndex(of: .languageMatch))
        let calendar = try #require(stages.firstIndex(of: .calendarCheck))
        #expect(language > calendar)
    }

    @Test("an answer in the user's language gets no note")
    func matchedIsQuiet() async {
        let (reviewed, trace) = await review(frenchAnswer, conversation: [user(frenchQuestion)])
        #expect(reviewed.languageNote == nil)
        #expect(trace.outcome(for: .languageMatch)
            == .noOp(reason: "matched (expected French, userMessage; 1 judged, 0 wrong, 0 stray)"))
    }

    @Test("a standing request from an earlier turn applies to a later one")
    func standingRequestCarries() async {
        let conversation = [
            user("From now on, reply in German."),
            assistant("Gerne, ab jetzt antworte ich nur noch auf Deutsch."),
            user("What is a tuple?")
        ]
        let (reviewed, trace) = await review(
            "A tuple is a sequence of values that cannot be changed after it is created.",
            conversation: conversation
        )
        #expect(reviewed.languageNote
            == "Language check: This answer is in English, but you asked earlier for answers in German.")
        #expect(trace.outcome(for: .languageMatch)
            == .ran(detail: "wrongLanguage (expected German, standing; 1 judged, 1 wrong, 0 stray)"))
    }

    @Test("a follow-up too short to identify is expected in the conversation's language")
    func shortFollowUpUsesTheConversation() async {
        let conversation = [user(frenchQuestion), assistant(frenchAnswer), user("ok, et un set ?")]
        let (reviewed, _) = await review(
            "A set stores unique values with no order, so checking whether it contains a value is fast.",
            conversation: conversation
        )
        #expect(reviewed.languageNote
            == "Language check: This answer is in English, but this conversation is in French.")
    }

    @Test("an English word in a Japanese answer is a stray word")
    func strayWordInJapanese() async {
        let (reviewed, trace) = await review(
            "リストは変更可能ですが、タプルは変更できません。however、両方とも任意の型を含むことができます。",
            conversation: [user("Pythonのリストとタプルの違いは何ですか？")]
        )
        #expect(reviewed.languageNote == "Language check: This Japanese answer slips in English words (“however”).")
        #expect(trace.outcome(for: .languageMatch)
            == .ran(detail: "strayWords (expected Japanese, userMessage; 2 judged, 0 wrong, 1 stray)"))
    }

    @Test("nothing to expect records why nothing ran")
    func noExpectation() async {
        let (reviewed, trace) = await review("Sure.", conversation: [user("ok")])
        #expect(reviewed.languageNote == nil)
        #expect(trace.outcome(for: .languageMatch)
            == .noOp(reason: "noExpectation (expected none; 0 judged, 0 wrong, 0 stray)"))
    }

    @Test("a withheld answer is not checked")
    func withheldIsSkipped() async {
        let refusal = Refusal(stage: .guardrailOutput, headline: "Withheld", explanation: "x", recovery: nil)
        let withheld = AnswerReview(
            publishableText: "", wasModified: true, groundedFraction: nil, claimCount: 0, refusal: refusal
        )
        var trace = PipelineTrace()
        let result = await PostModelPipeline.checkLanguage(withheld, messages: [user(frenchQuestion)], trace: &trace)
        #expect(result == withheld)
        #expect(trace.outcome(for: .languageMatch)
            == .skipped(reason: "the answer was withheld, so there is nothing to check"))
    }
}
