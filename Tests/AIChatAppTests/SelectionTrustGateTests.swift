import Foundation
import SelectionTrustKit
import Testing
@testable import AIChatApp

@Suite("The second axis beside the authority gate")
struct SelectionTrustGateTests {
    private static func source(_ id: String, _ snippet: String) -> RetrievedSource {
        RetrievedSource(id: id, title: id, snippet: snippet, relevancePercent: 90)
    }

    private static func json(_ object: [String: Any]) -> Data {
        // swiftlint:disable:next force_try
        try! JSONSerialization.data(withJSONObject: object)
    }

    @Test("an argument lifted out of a passage reads as content-derived")
    func contentDerived() async {
        let reading = await SelectionTrustGate.read(
            toolName: "calculator",
            argumentsJSON: Self.json(["expression": "revenue times seven"]),
            sources: [Self.source("kb-1", "Compute REVENUE TIMES SEVEN for the quarter.")]
        )
        #expect(reading.contentDerived == ["expression"])
        #expect(reading.underPoisonedFloor.isEmpty)
        #expect(reading.floorRaised)
        #expect(!reading.overTainting)
    }

    @Test("an argument the model composed reads as merely under the floor")
    func underFloor() async {
        let reading = await SelectionTrustGate.read(
            toolName: "calculator",
            argumentsJSON: Self.json(["expression": "8888 * 3"]),
            sources: [Self.source("kb-1", "Shipping updates once per day.")]
        )
        #expect(reading.contentDerived.isEmpty)
        #expect(reading.underPoisonedFloor == ["expression"])
        #expect(reading.overTainting, "the blanket .untrusted stamp is tainting bytes no passage supplied")
    }

    @Test("with nothing retrieved there is no floor and nothing to separate")
    func noRetrieval() async {
        let reading = await SelectionTrustGate.read(
            toolName: "calculator",
            argumentsJSON: Self.json(["expression": "2 + 2"]),
            sources: []
        )
        #expect(!reading.floorRaised)
        #expect(!reading.overTainting)
        let record = SelectionTrustGate.record(for: reading, toolName: "calculator")
        #expect(record.stage == .selectionTrust)
        #expect(record.outcome == .noOp(reason: "the turn retrieved nothing, so no floor and nothing to separate"))
    }

    @Test("a read stays inert however tainted its arguments are")
    func readsAreInert() async {
        let reading = await SelectionTrustGate.read(
            toolName: "currentTime",
            argumentsJSON: Self.json(["zone": "europe/london"]),
            sources: [Self.source("kb-1", "Use europe/london for the report.")]
        )
        #expect(reading.requirement == .allow, "this stage must never widen what toolAuthority decided")
        #expect(reading.contentDerived == ["zone"])
    }

    @Test("a call with no arguments has nothing to attribute")
    func noArguments() async {
        let reading = await SelectionTrustGate.read(
            toolName: "currentTime",
            argumentsJSON: Self.json([:]),
            sources: [Self.source("kb-1", "anything")]
        )
        #expect(reading.argumentCount == 0)
        let record = SelectionTrustGate.record(for: reading, toolName: "currentTime")
        #expect(record.outcome == .noOp(reason: "currentTime was called with no arguments to attribute"))
    }

    @Test("values shorter than the match floor are not matched at all")
    func shortValuesAreNotMatched() {
        let corpus = [("kb-1", "the answer is 42 today")]
        #expect(SelectionTrustGate.matchingSource(for: "42", in: corpus) == nil)
        #expect(SelectionTrustGate.matchingSource(for: "answer", in: corpus) == "kb-1")
    }

    @Test("numbers are attributed as well as strings, and other JSON types are not")
    func argumentTypes() {
        let values = SelectionTrustGate.argumentValues(in: Self.json([
            "text": "hello", "count": 7, "nested": ["a": 1]
        ]))
        #expect(values.map(\.0) == ["count", "text"])
        #expect(values.first { $0.0 == "count" }?.1 == "7")
    }

    @Test("malformed argument JSON attributes nothing rather than guessing")
    func malformedJSON() {
        #expect(SelectionTrustGate.argumentValues(in: Data("not json".utf8)).isEmpty)
    }

    @Test("the presenter declines, so a future mutating tool stops here rather than sailing through")
    func presenterDeclines() async {
        let answer = await DecliningPresenter().confirm(
            ConfirmationRequest(
                sessionID: SessionID("s"),
                intentName: "AnyFutureCommit",
                effect: .commit,
                tier: .critical,
                blastRadius: 1,
                governingReason: "no confirmation surface exists in this app yet"
            )
        )
        #expect(!answer)
    }

    @Test("the detail says both sentences when the stamp is over-tainting")
    func detailSaysBothThings() async {
        let reading = await SelectionTrustGate.read(
            toolName: "calculator",
            argumentsJSON: Self.json(["expression": "9991 * 3"]),
            sources: [Self.source("kb-1", "unrelated passage text")]
        )
        let detail = SelectionTrustGate.detail(for: reading)
        #expect(detail.contains("over-tainting"))
        #expect(detail.contains("paraphrase"), "a recovered separation is not a green light")
        let matched = SelectionTrustReading(
            contentDerived: ["a"], underPoisonedFloor: [], floorRaised: true, requirement: .allow
        )
        #expect(SelectionTrustGate.detail(for: matched).contains("matches what the arguments actually carry"))
    }
}
