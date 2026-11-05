import Foundation
import GuardrailKit
import ProviderGatewayKit
import Testing
@testable import AIChatApp

private let question = "What body do I send to create the app?"

private func user(_ text: String) -> LLMMessage {
    LLMMessage(role: .user, content: text)
}

private func review(
    _ answer: String,
    messages: [LLMMessage] = [user(question)]
) async -> (AnswerReview, PipelineTrace) {
    let pipeline = PostModelPipeline(guardrail: GuardrailPipeline(policy: GuardrailPolicy()))
    var trace = PipelineTrace()
    let reviewed = await pipeline.review(answer: answer, sources: [], messages: messages, trace: &trace)
    return (reviewed, trace)
}

private let brokenBlock = "Use this body:\n```json\n{\"name\": \"app\",}\n```"
private let comma = "The block shown as JSON does not parse: a trailing comma at line 1, column 15."

@Suite("JSONClaimKit - what an answer says about JSON, parsed and run")
struct JSONCheckStageTests {
    @Test("a block labeled json that does not parse gets a note with the line and column, after stringCheck")
    func brokenBlockGetsANote() async throws {
        let (reviewed, trace) = await review(brokenBlock)
        #expect(reviewed.publishableText == brokenBlock)
        #expect(reviewed.jsonNote == "JSON check: " + comma)
        #expect(trace.outcome(for: .jsonCheck) == .ran(detail: "1 claim checked, 0 hold, 1 wrong; " + comma))
        let stages = trace.records.map(\.stage)
        let json = try #require(stages.firstIndex(of: .jsonCheck))
        let strings = try #require(stages.firstIndex(of: .stringCheck))
        #expect(json > strings)
        var bubble = ChatBubble(role: .assistant, text: reviewed.publishableText)
        bubble.applyReview(reviewed)
        #expect(bubble.jsonNote == reviewed.jsonNote)
        #expect(bubble.reviewNotes.map(\.id).last == "jsonNote")
    }

    @Test("json.dumps output and jq output are run by their own rules, and the slip is named")
    func codeAndShellAreRun() async {
        let python = "```python\n>>> json.dumps({\"a\": 1})\n'{\"a\":1}'\n```"
        let (dumped, _) = await review(python)
        #expect(dumped.jsonNote == "JSON check: json.dumps({\"a\": 1}) gives '{\"a\": 1}', not '{\"a\":1}': "
            + "json.dumps puts a space after each \",\" and \":\" unless separators says otherwise.")
        let shell = "```console\n$ echo '{\"name\": \"Ann\"}' | jq -r '.name'\n\"Ann\"\n```"
        let (queried, trace) = await review(shell)
        let correction = "echo '{\"name\": \"Ann\"}' | jq -r '.name' gives Ann, not \"Ann\": -r prints strings "
            + "without their quotes."
        #expect(queried.jsonNote == "JSON check: " + correction)
        #expect(trace.outcome(for: .jsonCheck) == .ran(detail: "1 claim checked, 0 hold, 1 wrong; " + correction))
    }

    @Test("JSON that parses but repeats a key is noted for a second look")
    func caveatIsNoted() async {
        let (reviewed, trace) = await review("```json\n{\"id\": 1, \"id\": 2}\n```")
        let caveat = "The block shown as JSON parses, but repeats the key \"id\"; parsers disagree on which value "
            + "wins, and some refuse it."
        #expect(reviewed.jsonNote == "JSON check: " + caveat)
        #expect(trace.outcome(for: .jsonCheck) == .ran(detail: "1 claim checked, 0 hold, 1 to check; " + caveat))
    }

    @Test("a broken block the chat already gave is marked as said again")
    func repeatedClaimSaysSo() async {
        let messages = [
            user(question),
            LLMMessage(role: .assistant, content: brokenBlock),
            user("That fails to parse.")
        ]
        let (reviewed, trace) = await review(brokenBlock, messages: messages)
        #expect(reviewed.jsonNote == "JSON check: " + comma + " An earlier answer in this chat stated the same claim.")
        #expect(trace.outcome(for: .jsonCheck)
            == .ran(detail: "1 claim checked, 0 hold, 1 wrong, 1 repeated; " + comma))
    }

    @Test("JSON that parses, no JSON at all, or an abridged block get no note")
    func quietWhenItHolds() async {
        let (held, heldTrace) = await review("```json\n{\"name\": \"app\"}\n```")
        #expect(held.jsonNote == nil)
        #expect(heldTrace.outcome(for: .jsonCheck) == .noOp(reason: "1 claim checked, 1 hold"))
        let (none, noneTrace) = await review("Weigh the flour rather than using cups.")
        #expect(none.jsonNote == nil)
        #expect(noneTrace.outcome(for: .jsonCheck) == .noOp(reason: "no claims about JSON"))
        let (abridged, abridgedTrace) = await review("```json\n{\"items\": [1, 2, ...]}\n```")
        #expect(abridged.jsonNote == nil)
        #expect(abridgedTrace.outcome(for: .jsonCheck) == .noOp(reason: "1 claim checked, 0 hold, 1 unchecked"))
    }

    @Test("a withheld answer is not checked")
    func withheldIsSkipped() async {
        let refusal = Refusal(stage: .guardrailOutput, headline: "Withheld", explanation: "x", recovery: nil)
        let withheld = AnswerReview(
            publishableText: "", wasModified: true, groundedFraction: nil, claimCount: 0, refusal: refusal
        )
        var trace = PipelineTrace()
        let result = await PostModelPipeline.checkJSON(withheld, messages: [user(question)], trace: &trace)
        #expect(result == withheld)
        #expect(trace.outcome(for: .jsonCheck)
            == .skipped(reason: "the answer was withheld, so there is nothing to check"))
    }

    @Test("the JSON note comes last among the notes, after the string note")
    func reviewNotesKeepTheirOrder() {
        var bubble = ChatBubble(role: .assistant, text: "x")
        bubble.jsonNote = "j"
        bubble.stringNote = "t"
        #expect(bubble.reviewNotes == [ReviewNote(id: "stringNote", text: "t"), ReviewNote(id: "jsonNote", text: "j")])
    }
}
