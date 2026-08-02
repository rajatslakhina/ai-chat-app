import Foundation
import OutputRepairKit
import StructuredOutputKit
import Testing
@testable import AIChatApp

// MARK: - Shared fixtures

enum MetadataFixtures {
    static let titleJSON = #"{"title":"Capital of France"}"#
    static let followUpsJSON = """
    {"followUps":["What is the population?","When was it founded?"]}
    """

    /// The reply a model gives when it ignores "no prose, no fences" — which is most of them.
    static let fencedTitle = """
    Sure, here you go:

    ```json
    {"title": "Capital of France"}
    ```
    """

    static func title(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "{\"title\":\"\(escaped)\"}"
    }

    static func followUps(_ values: [String]) -> String {
        let items = values.map { "\"\($0)\"" }.joined(separator: ",")
        return "{\"followUps\":[\(items)]}"
    }

    /// The issues a contract rejected `raw` with, or nil when it accepted it.
    static func issues(of contract: MetadataContract, for raw: String) -> [RepairIssue]? {
        guard case let .invalid(issues) = contract.validate(raw) else { return nil }
        return issues
    }

    static func accepted(_ contract: MetadataContract, _ raw: String) -> String? {
        guard case let .valid(text) = contract.validate(raw) else { return nil }
        return text
    }
}

// MARK: - Schema

@Suite("Chat metadata schemas")
struct ChatMetadataSchemaTests {
    @Test("each type publishes the fields it decodes, and requires all of them")
    func schemasMatchTheTypes() {
        #expect(ChatTitleDraft.jsonSchema.required == ["title"])
        #expect(ChatTitleDraft.jsonSchema.properties?.keys.sorted() == ["title"])
        #expect(ChatFollowUpsDraft.jsonSchema.required == ["followUps"])
        #expect(ChatFollowUpsDraft.jsonSchema.properties?.keys.sorted() == ["followUps"])
        #expect(ChatMetadata.jsonSchema.required?.sorted() == ["followUps", "title", "titleSource"])
        #expect(
            ChatMetadata.jsonSchema.properties?.keys.sorted() == ["followUps", "title", "titleSource"]
        )
    }

    /// The union has to be assembled from the same nodes the halves publish, or the prompt the
    /// model is given drifts away from the schema its answer is checked against.
    @Test("the combined schema reuses the very field nodes the drafts publish")
    func fieldsAreShared() {
        #expect(ChatMetadata.jsonSchema.properties?["title"] == ChatTitleDraft.jsonSchema.properties?["title"])
        #expect(
            ChatMetadata.jsonSchema.properties?["followUps"]
                == ChatFollowUpsDraft.jsonSchema.properties?["followUps"]
        )
    }

    @Test("titleSource is constrained to the two values the app can actually produce")
    func titleSourceIsEnumerated() {
        #expect(ChatMetadata.jsonSchema.properties?["titleSource"]?.enumValues == ["model", "fallback"])
    }

    /// The instructions are what the model is actually told, so they have to name the keys.
    @Test("the rendered instructions name the field the answer will be checked for")
    func promptBuilderNamesTheFields() {
        #expect(MetadataAsk.title.instruction.contains("\"title\""))
        #expect(MetadataAsk.followUps.instruction.contains("\"followUps\""))
        #expect(MetadataAsk.title.instruction.contains("no Markdown code fences"))
    }

    @Test("both asks carry a prompt containing the conversation and the shape")
    func promptCarriesBoth() {
        let prompt = MetadataAsk.title.prompt(userText: "capital of France", assistantText: "Paris.")
        #expect(prompt.contains("capital of France"))
        #expect(prompt.contains("Paris."))
        #expect(prompt.contains("\"title\""))
    }

    /// A metadata call that grows with the answer it describes is a cost that climbs for nothing.
    @Test("a very long answer is truncated out of the prompt")
    func promptIsBounded() {
        let long = String(repeating: "x", count: 5_000)
        let prompt = MetadataAsk.followUps.prompt(userText: long, assistantText: long)
        #expect(prompt.count < 2_000)
    }
}

@Suite("Fallback title")
struct FallbackTitleTests {
    @Test("short text is used as it stands")
    func shortText() {
        #expect(ChatMetadata.fallbackTitle(from: "capital of France") == "capital of France")
    }

    @Test("long text is truncated with an ellipsis rather than clipped by the navigation bar")
    func longText() {
        let title = ChatMetadata.fallbackTitle(from: String(repeating: "a", count: 200))
        #expect(title.count == ChatMetadata.maxTitleCharacters)
        #expect(title.hasSuffix("…"))
    }

    @Test("newlines are flattened, because a title is one line")
    func flattensNewlines() {
        #expect(ChatMetadata.fallbackTitle(from: "hello\nworld") == "hello world")
    }

    @Test("nothing to fall back on still produces a title, not an empty navigation bar")
    func emptyText() {
        #expect(ChatMetadata.fallbackTitle(from: "   \n ") == "New conversation")
    }

    @Test("the fallback labels itself as one")
    func labelled() {
        let metadata = ChatMetadata.fallback(userText: "hi", followUps: ["a"])
        #expect(metadata.titleSource == .fallback)
        #expect(metadata.followUps == ["a"])
    }
}

// MARK: - Contract

@Suite("Metadata contract — what it accepts")
struct MetadataContractAcceptanceTests {
    @Test("a clean JSON object is accepted and handed back verbatim")
    func acceptsCleanJSON() {
        #expect(
            MetadataFixtures.accepted(MetadataAsk.title.contract, MetadataFixtures.titleJSON)
                == MetadataFixtures.titleJSON
        )
    }

    /// Models wrap JSON in fences constantly. A contract that rejected them would spend its whole
    /// attempt budget teaching a model to stop doing something it will keep doing.
    @Test("a fenced object wrapped in prose is unwrapped rather than rejected")
    func acceptsFencedJSON() {
        let accepted = MetadataFixtures.accepted(MetadataAsk.title.contract, MetadataFixtures.fencedTitle)
        #expect(accepted == #"{"title": "Capital of France"}"#)
    }

    @Test("undeclared extra keys are ignored, not treated as a violation")
    func ignoresExtraKeys() {
        let raw = #"{"title":"Paris","confidence":0.9}"#
        #expect(MetadataFixtures.accepted(MetadataAsk.title.contract, raw) == raw)
    }

    @Test("two and three suggestions are both accepted")
    func acceptsBothCounts() {
        for count in [2, 3] {
            let raw = MetadataFixtures.followUps((1...count).map { "question \($0)" })
            #expect(MetadataFixtures.accepted(MetadataAsk.followUps.contract, raw) != nil)
        }
    }
}

@Suite("Metadata contract — what it rejects, and how it explains it")
struct MetadataContractRejectionTests {
    private let title = MetadataAsk.title.contract
    private let followUps = MetadataAsk.followUps.contract

    @Test("prose with no JSON in it is rejected with an excerpt, not the whole reply")
    func rejectsProse() throws {
        let issues = try #require(MetadataFixtures.issues(of: title, for: "I'd call it Paris, probably."))
        #expect(issues.count == 1)
        #expect(issues[0].problem.contains("did not contain a JSON object"))
        #expect(issues[0].observed?.contains("Paris") == true)
    }

    @Test("an empty reply is rejected without pretending it said something")
    func rejectsEmpty() throws {
        let issues = try #require(MetadataFixtures.issues(of: title, for: "   "))
        #expect(issues[0].observed == "an empty reply")
    }

    @Test("a JSON array is rejected as the wrong shape, not as unparseable")
    func rejectsArray() throws {
        let issues = try #require(MetadataFixtures.issues(of: title, for: #"["Paris"]"#))
        #expect(issues[0].problem.contains("did not contain a JSON object"))
    }

    @Test("a missing required field names the field")
    func rejectsMissingField() throws {
        let issues = try #require(MetadataFixtures.issues(of: title, for: "{}"))
        #expect(issues[0].problem.contains("title"))
        #expect(issues[0].problem.contains("required"))
    }

    @Test("the wrong primitive type says what was expected and what arrived")
    func rejectsWrongType() throws {
        let issues = try #require(MetadataFixtures.issues(of: title, for: #"{"title":42}"#))
        #expect(issues[0].problem.contains("expected string"))
    }

    @Test("an array of the wrong element type is caught per element")
    func rejectsWrongElementType() throws {
        let issues = try #require(MetadataFixtures.issues(of: followUps, for: #"{"followUps":[1,2]}"#))
        #expect(issues[0].problem.contains("expected string"))
    }

    @Test("a title too long for a navigation bar is rejected with both numbers")
    func rejectsLongTitle() throws {
        let raw = MetadataFixtures.title(String(repeating: "a", count: 200))
        let issues = try #require(MetadataFixtures.issues(of: title, for: raw))
        #expect(issues[0].path == "title")
        #expect(issues[0].expected == "at most 48 characters")
        #expect(issues[0].observed == "200 characters")
    }

    @Test("a blank title is rejected even though it is a valid string")
    func rejectsBlankTitle() throws {
        let issues = try #require(MetadataFixtures.issues(of: title, for: MetadataFixtures.title("   ")))
        #expect(issues[0].problem.contains("blank"))
    }

    @Test("a multi-line title is rejected, because a navigation bar has one line")
    func rejectsMultilineTitle() throws {
        let issues = try #require(MetadataFixtures.issues(of: title, for: MetadataFixtures.title("a\nb")))
        #expect(issues.contains { $0.problem.contains("more than one line") })
    }

    @Test("too few and too many suggestions are both rejected with the allowed range")
    func rejectsWrongCounts() throws {
        for values in [["only one"], ["a", "b", "c", "d"]] {
            let raw = MetadataFixtures.followUps(values)
            let issues = try #require(MetadataFixtures.issues(of: followUps, for: raw))
            #expect(issues.contains { $0.expected == "2 to 3 items" })
        }
    }

    @Test("a suggestion too long for a chip is rejected by index")
    func rejectsLongSuggestion() throws {
        let raw = MetadataFixtures.followUps(["short", String(repeating: "b", count: 200)])
        let issues = try #require(MetadataFixtures.issues(of: followUps, for: raw))
        #expect(issues.contains { $0.path == "followUps[1]" })
    }

    @Test("a blank suggestion is rejected rather than rendering an empty chip")
    func rejectsBlankSuggestion() throws {
        let raw = MetadataFixtures.followUps(["fine", "   "])
        let issues = try #require(MetadataFixtures.issues(of: followUps, for: raw))
        #expect(issues.contains { $0.path == "followUps[1]" && $0.problem.contains("blank") })
    }

    /// Two identical chips look like a rendering bug. It is a model bug, and repair can fix it.
    @Test("duplicate suggestions are rejected")
    func rejectsDuplicates() throws {
        let raw = MetadataFixtures.followUps(["same", "same"])
        let issues = try #require(MetadataFixtures.issues(of: followUps, for: raw))
        #expect(issues.contains { $0.problem.contains("identical") })
    }

    /// `ContractResult.invalid([])` is legal in OutputRepairKit and produces a repair prompt
    /// reading "fix exactly these 0 problem(s)" — a billed round trip carrying no instruction.
    @Test("no rejection is ever explained with an empty list of reasons")
    func neverRejectsWithoutAReason() {
        let corpus = [
            "", "   ", "not json", "[]", "{}", "null", "42",
            #"{"title":42}"#, #"{"title":""}"#, #"{"followUps":[]}"#,
            MetadataFixtures.title(String(repeating: "z", count: 90)),
            MetadataFixtures.followUps(["a", "a"]),
            MetadataFixtures.followUps(Array(repeating: "x", count: 9))
        ]
        for contract in [MetadataAsk.title.contract, MetadataAsk.followUps.contract] {
            for raw in corpus {
                guard case let .invalid(issues) = contract.validate(raw) else { continue }
                #expect(!issues.isEmpty, "\(raw) was rejected without a reason")
                for issue in issues {
                    #expect(!issue.description.isEmpty)
                }
            }
        }
    }

    /// The excerpt travels into a repair prompt and from there into the trace, and a rejected
    /// reply in a chat app routinely quotes the user's own message straight back.
    @Test("the excerpt of a rejected reply is bounded")
    func excerptIsBounded() {
        let excerpt = MetadataContract.excerpt(of: String(repeating: "secret ", count: 400))
        #expect(excerpt.count < 80)
        #expect(excerpt.hasSuffix("…\""))
    }
}

@Suite("Metadata rules on their own")
struct MetadataRuleTests {
    /// The contract runs the schema check first, so these only fire for a direct caller — but
    /// "no opinion about a field that is not there" is the answer they have to give.
    @Test("a field that is absent draws no opinion")
    func absentFields() {
        #expect(MetadataRules.title([:]).isEmpty)
        #expect(MetadataRules.followUps([:]).isEmpty)
        #expect(MetadataRules.title(["title": .number(3)]).isEmpty)
        #expect(MetadataRules.followUps(["followUps": .string("nope")]).isEmpty)
    }

    @Test("a non-string element is skipped rather than crashing the count")
    func mixedElements() {
        let issues = MetadataRules.followUps(["followUps": .array([.string("a"), .number(1)])])
        #expect(issues.contains { $0.expected == "2 to 3 items" })
    }

    @Test("every issue renders as one readable line")
    func issuesRender() {
        let issues = MetadataRules.title(["title": .string("")])
        #expect(issues.first?.description.contains("title:") == true)
    }
}
