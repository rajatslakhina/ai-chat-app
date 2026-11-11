import Foundation
import GuardrailKit
import ProviderGatewayKit
import Testing
@testable import AIChatApp

private let question = "How do I set up pyproject.toml?"

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

private let brokenBlock = "Use this config:\n```toml\n[tool.poetry.dependencies]\npython = ^3.10\n```"
private let bare = "The block shown as TOML does not parse: unquoted text where TOML needs a quoted string (^3.10) "
    + "at line 2, column 10 (TOML strings need quotes: \"...\" or '...')."
private let version = "In TOML, `python_version = 3.10` is read as the string \"3.10\"."
private let float = "`python_version = 3.10` is not the string \"3.10\": tomllib reads it as the float 3.1 "
    + "(an unquoted 3.10 is the float 3.1; quote it to keep the text)."

@Suite("TOMLClaimKit - what an answer says about TOML, parsed and loaded")
struct TOMLCheckStageTests {
    @Test("a block labeled toml that does not parse gets a note with the line and column, after yamlCheck")
    func brokenBlockGetsANote() async throws {
        let (reviewed, trace) = await review(brokenBlock)
        #expect(reviewed.publishableText == brokenBlock)
        #expect(reviewed.tomlNote == "TOML check: " + bare)
        #expect(trace.outcome(for: .tomlCheck) == .ran(detail: "1 claim checked, 0 hold, 1 wrong; " + bare))
        let stages = trace.records.map(\.stage)
        let toml = try #require(stages.firstIndex(of: .tomlCheck))
        let yaml = try #require(stages.firstIndex(of: .yamlCheck))
        #expect(toml > yaml)
        var bubble = ChatBubble(role: .assistant, text: reviewed.publishableText)
        bubble.applyReview(reviewed)
        #expect(bubble.tomlNote == reviewed.tomlNote)
        #expect(bubble.reviewNotes.map(\.id).last == "tomlNote")
    }

    @Test("a sentence about how a value reads is checked with TOML's own rules, and the slip is named")
    func readingIsChecked() async {
        let (reviewed, trace) = await review(version)
        #expect(reviewed.tomlNote == "TOML check: " + float)
        #expect(trace.outcome(for: .tomlCheck) == .ran(detail: "1 claim checked, 0 hold, 1 wrong; " + float))
    }

    @Test("a tomllib snippet is run: a text-mode file raises, and a dotted key is not a key")
    func snippetIsLoaded() async {
        let block = "```toml\n[tool.poetry]\nversion = \"0.1.0\"\n```\n\n```python\nimport tomllib\n"
        let textMode = block + "with open(\"pyproject.toml\") as f:\n    data = tomllib.load(f)\n"
            + "print(data[\"tool\"][\"poetry\"][\"version\"])  # 0.1.0\n```"
        let (opened, openedTrace) = await review(textMode)
        let typeError = "`tomllib.load(f)` raises TypeError: File must be opened in binary mode, e.g. use "
            + "`open('foo.toml', 'rb')`; the answer uses it as if it runs (tomllib.load needs a file opened in "
            + "binary mode: open(path, \"rb\"))."
        #expect(opened.tomlNote == "TOML check: " + typeError)
        #expect(openedTrace.outcome(for: .tomlCheck)
            == .ran(detail: "2 claims checked, 1 hold, 1 wrong; " + typeError))
        let dotted = block + "with open(\"pyproject.toml\", \"rb\") as f:\n    data = tomllib.load(f)\n"
            + "print(data[\"tool.poetry\"][\"version\"])  # 0.1.0\n```"
        let (looked, lookedTrace) = await review(dotted)
        let keyError = "`print(data[\"tool.poetry\"][\"version\"])` raises KeyError: 'tool.poetry'; the answer shows "
            + "0.1.0 (a dotted key makes nested tables, so index one level at a time: data[\"tool\"][\"poetry\"])."
        #expect(looked.tomlNote == "TOML check: " + keyError)
        #expect(lookedTrace.outcome(for: .tomlCheck)
            == .ran(detail: "2 claims checked, 1 hold, 1 wrong; " + keyError))
    }

    @Test("an unquoted float with a trailing zero in TOML that parses gets a caveat, not a wrong")
    func caveatIsNoted() async {
        let (reviewed, trace) = await review("```toml\n[tool.mypy]\npython_version = 3.10\n```")
        let caveat = "The TOML has unquoted numbers written with a trailing zero, which load without it: "
            + "python_version = 3.10; quote any that must stay text, such as a version."
        #expect(reviewed.tomlNote == "TOML check: " + caveat)
        #expect(trace.outcome(for: .tomlCheck) == .ran(detail: "1 claim checked, 0 hold, 1 to check; " + caveat))
    }

    @Test("a wrong reading the chat already gave is marked as said again")
    func repeatedClaimSaysSo() async {
        let messages = [
            user(question),
            LLMMessage(role: .assistant, content: version),
            user("Are you sure about 3.10?")
        ]
        let (reviewed, trace) = await review(version, messages: messages)
        #expect(reviewed.tomlNote == "TOML check: " + float + " An earlier answer in this chat stated the same claim.")
        #expect(trace.outcome(for: .tomlCheck)
            == .ran(detail: "1 claim checked, 0 hold, 1 wrong, 1 repeated; " + float))
    }

    @Test("TOML that parses, no TOML at all, or TOML the checker cannot compare get no note")
    func quietWhenItHolds() async {
        let (held, heldTrace) = await review("```toml\nname = \"app\"\nport = 8080\n```")
        #expect(held.tomlNote == nil)
        #expect(heldTrace.outcome(for: .tomlCheck) == .noOp(reason: "1 claim checked, 1 hold"))
        let (none, noneTrace) = await review("Weigh the flour rather than using cups.")
        #expect(none.tomlNote == nil)
        #expect(noneTrace.outcome(for: .tomlCheck) == .noOp(reason: "no claims about TOML"))
        let (big, bigTrace) = await review("```toml\nbig = 99999999999999999999\n```")
        #expect(big.tomlNote == nil)
        #expect(bigTrace.outcome(for: .tomlCheck) == .noOp(reason: "1 claim checked, 0 hold, 1 unchecked"))
    }

    @Test("a withheld answer is not checked")
    func withheldIsSkipped() async {
        let refusal = Refusal(stage: .guardrailOutput, headline: "Withheld", explanation: "x", recovery: nil)
        let withheld = AnswerReview(
            publishableText: "", wasModified: true, groundedFraction: nil, claimCount: 0, refusal: refusal
        )
        var trace = PipelineTrace()
        let result = await PostModelPipeline.checkTOML(withheld, messages: [user(question)], trace: &trace)
        #expect(result == withheld)
        #expect(trace.outcome(for: .tomlCheck)
            == .skipped(reason: "the answer was withheld, so there is nothing to check"))
    }

    @Test("the TOML note comes last among the notes, after the YAML note")
    func reviewNotesKeepTheirOrder() {
        var bubble = ChatBubble(role: .assistant, text: "x")
        bubble.tomlNote = "t"
        bubble.yamlNote = "y"
        #expect(bubble.reviewNotes == [ReviewNote(id: "yamlNote", text: "y"), ReviewNote(id: "tomlNote", text: "t")])
    }
}
