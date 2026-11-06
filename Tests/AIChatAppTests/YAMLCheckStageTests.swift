import Foundation
import GuardrailKit
import ProviderGatewayKit
import Testing
@testable import AIChatApp

private let question = "How do I configure the deploy?"

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

private let brokenBlock = "Use this config:\n```yaml\nname: app\n  port: 8080\n```"
private let colon = "The block shown as YAML does not parse: a colon followed by a space inside an unquoted value "
    + "at line 2, column 7."
private let version = "In YAML, `python-version: 3.10` is read as the string \"3.10\"."
private let float = "`python-version: 3.10` is not the string \"3.10\": YAML 1.1 (PyYAML) reads it as the float 3.1 "
    + "(an unquoted 3.10 is the number 3.1; quote it to keep the text)."

@Suite("YAMLClaimKit - what an answer says about YAML, parsed and loaded")
struct YAMLCheckStageTests {
    @Test("a block labeled yaml that does not parse gets a note with the line and column, after jsonCheck")
    func brokenBlockGetsANote() async throws {
        let (reviewed, trace) = await review(brokenBlock)
        #expect(reviewed.publishableText == brokenBlock)
        #expect(reviewed.yamlNote == "YAML check: " + colon)
        #expect(trace.outcome(for: .yamlCheck) == .ran(detail: "1 claim checked, 0 hold, 1 wrong; " + colon))
        let stages = trace.records.map(\.stage)
        let yaml = try #require(stages.firstIndex(of: .yamlCheck))
        let json = try #require(stages.firstIndex(of: .jsonCheck))
        #expect(yaml > json)
        var bubble = ChatBubble(role: .assistant, text: reviewed.publishableText)
        bubble.applyReview(reviewed)
        #expect(bubble.yamlNote == reviewed.yamlNote)
        #expect(bubble.reviewNotes.map(\.id).last == "yamlNote")
    }

    @Test("a sentence about how a value reads is checked with YAML's own rules, and the slip is named")
    func readingIsChecked() async {
        let (reviewed, trace) = await review(version)
        #expect(reviewed.yamlNote == "YAML check: " + float)
        #expect(trace.outcome(for: .yamlCheck) == .ran(detail: "1 claim checked, 0 hold, 1 wrong; " + float))
    }

    @Test("a safe_load snippet is run against the YAML block shown before it")
    func snippetIsLoaded() async {
        let answer = "```yaml\nregions: [GB, NO, SE]\n```\n\n```python\nimport yaml\n"
            + "config = yaml.safe_load(open(\"deploy.yml\"))\nprint(config[\"regions\"])  # ['GB', 'NO', 'SE']\n```"
        let (reviewed, trace) = await review(answer)
        let caveat = "The YAML has unquoted values that PyYAML (YAML 1.1) and YAML 1.2 parsers read differently: NO; "
            + "quote any that must stay text."
        let loaded = "`print(config[\"regions\"])` gives ['GB', False, 'SE'], not ['GB', 'NO', 'SE'] (YAML 1.1 reads "
            + "yes, no, on and off as booleans; quote the value to keep it as text)."
        #expect(reviewed.yamlNote == "YAML check: " + caveat + " " + loaded)
        #expect(trace.outcome(for: .yamlCheck)
            == .ran(detail: "2 claims checked, 0 hold, 1 to check, 1 wrong; " + caveat + " " + loaded))
    }

    @Test("a wrong reading the chat already gave is marked as said again")
    func repeatedClaimSaysSo() async {
        let messages = [
            user(question),
            LLMMessage(role: .assistant, content: version),
            user("Are you sure about 3.10?")
        ]
        let (reviewed, trace) = await review(version, messages: messages)
        #expect(reviewed.yamlNote == "YAML check: " + float + " An earlier answer in this chat stated the same claim.")
        #expect(trace.outcome(for: .yamlCheck)
            == .ran(detail: "1 claim checked, 0 hold, 1 wrong, 1 repeated; " + float))
    }

    @Test("YAML that parses, no YAML at all, or YAML the checker does not parse get no note")
    func quietWhenItHolds() async {
        let (held, heldTrace) = await review("```yaml\nname: app\nport: 8080\n```")
        #expect(held.yamlNote == nil)
        #expect(heldTrace.outcome(for: .yamlCheck) == .noOp(reason: "1 claim checked, 1 hold"))
        let (none, noneTrace) = await review("Weigh the flour rather than using cups.")
        #expect(none.yamlNote == nil)
        #expect(noneTrace.outcome(for: .yamlCheck) == .noOp(reason: "no claims about YAML"))
        let (tagged, taggedTrace) = await review("```yaml\nkey: !vault secret\n```")
        #expect(tagged.yamlNote == nil)
        #expect(taggedTrace.outcome(for: .yamlCheck) == .noOp(reason: "1 claim checked, 0 hold, 1 unchecked"))
    }

    @Test("a withheld answer is not checked")
    func withheldIsSkipped() async {
        let refusal = Refusal(stage: .guardrailOutput, headline: "Withheld", explanation: "x", recovery: nil)
        let withheld = AnswerReview(
            publishableText: "", wasModified: true, groundedFraction: nil, claimCount: 0, refusal: refusal
        )
        var trace = PipelineTrace()
        let result = await PostModelPipeline.checkYAML(withheld, messages: [user(question)], trace: &trace)
        #expect(result == withheld)
        #expect(trace.outcome(for: .yamlCheck)
            == .skipped(reason: "the answer was withheld, so there is nothing to check"))
    }

    @Test("the YAML note comes last among the notes, after the JSON note")
    func reviewNotesKeepTheirOrder() {
        var bubble = ChatBubble(role: .assistant, text: "x")
        bubble.yamlNote = "y"
        bubble.jsonNote = "j"
        #expect(bubble.reviewNotes == [ReviewNote(id: "jsonNote", text: "j"), ReviewNote(id: "yamlNote", text: "y")])
    }
}
