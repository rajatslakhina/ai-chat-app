import Foundation
import Testing
@testable import AIChatApp

@Suite("The ladder that audits the substring rule beside it")
struct ArgumentAttributionGateTests {
    private static let passage = "Remit four thousand two hundred pounds to the account on file. "
        + "Refunds are issued within 5 working days."

    private static func source(_ id: String, _ snippet: String) -> RetrievedSource {
        RetrievedSource(id: id, title: id, snippet: snippet, relevancePercent: 90)
    }

    private static func json(_ object: [String: Any]) -> Data {
        // swiftlint:disable:next force_try
        try! JSONSerialization.data(withJSONObject: object)
    }

    @Test("a number the passage spelled out is attributed, and the substring rule misses it")
    func numberWrittenInWords() async {
        let reading = await ArgumentAttributionGate.read(
            toolName: "calculator",
            argumentsJSON: Self.json(["amount": "4200"]),
            sources: [Self.source("kb-1", Self.passage)]
        )
        #expect(reading.attributed == ["amount"])
        #expect(reading.substringUnderCounted == ["amount"])
        #expect(reading.maximumOverTaint == 0)
        #expect(reading.findings.first?.contains("numeric in kb-1") == true)
    }

    @Test("a common word the substring rule counts is priced too cheaply to be evidence")
    func cheapMatch() async {
        let reading = await ArgumentAttributionGate.read(
            toolName: "calculator",
            argumentsJSON: Self.json(["unit": "days"]),
            sources: [Self.source("kb-1", Self.passage)]
        )
        #expect(reading.weak == ["unit"])
        #expect(reading.substringOverCounted == ["unit"])
        #expect(reading.maximumOverTaint == 1)
        #expect(reading.findings.first?.contains("bit floor") == true)
    }

    @Test("the two failures show up in one call, and the detail names both")
    func bothDirections() async {
        let reading = await ArgumentAttributionGate.read(
            toolName: "calculator",
            argumentsJSON: Self.json(["amount": "4200", "unit": "days"]),
            sources: [Self.source("kb-1", Self.passage)]
        )
        #expect(reading.disagrees)
        #expect(reading.argumentCount == 2)
        let detail = ArgumentAttributionGate.detail(for: reading)
        #expect(detail.contains("unit (it over-counts) and amount (it misses)"))
        #expect(detail.contains("semantic rung was not installed"))
        #expect(detail.contains("finding nothing is not finding an absence"))
    }

    @Test("an argument no rung reaches is recorded without evidence, never as underived")
    func withoutEvidence() async {
        let reading = await ArgumentAttributionGate.read(
            toolName: "calculator",
            argumentsJSON: Self.json(["expression": "8888 * 3"]),
            sources: [Self.source("kb-1", "Shipping updates once per day.")]
        )
        #expect(reading.withoutEvidence == ["expression"])
        #expect(!reading.disagrees)
        #expect(reading.findings.first?.contains("no rung matched") == true)
        let record = ArgumentAttributionGate.record(for: reading, toolName: "calculator")
        #expect(record.stage == .argumentAttribution)
        #expect(record.outcome == .ran(detail: ArgumentAttributionGate.detail(for: reading)))
        #expect(ArgumentAttributionGate.detail(for: reading).contains("same verdict on every argument"))
    }

    @Test("with nothing retrieved there is no passage to attribute to")
    func noRetrieval() async {
        let reading = await ArgumentAttributionGate.read(
            toolName: "calculator",
            argumentsJSON: Self.json(["expression": "2 + 2"]),
            sources: []
        )
        #expect(!reading.floorRaised)
        let record = ArgumentAttributionGate.record(for: reading, toolName: "calculator")
        #expect(record.outcome == .noOp(reason: "the turn retrieved nothing, so there is no passage to attribute to"))
    }

    @Test("a call with no arguments has nothing to attribute")
    func noArguments() async {
        let reading = await ArgumentAttributionGate.read(
            toolName: "currentTime",
            argumentsJSON: Data("not json".utf8),
            sources: [Self.source("kb-1", Self.passage)]
        )
        #expect(reading.argumentCount == 0)
        let record = ArgumentAttributionGate.record(for: reading, toolName: "currentTime")
        #expect(record.outcome == .noOp(reason: "currentTime was called with no arguments to attribute"))
    }

    @Test("the stage names the package it is a consumer of")
    func stageTable() {
        #expect(PipelineStage.argumentAttribution.package == "ArgumentAttributionKit")
        #expect(PipelineStage.argumentAttribution.title == "Argument attribution")
    }
}
