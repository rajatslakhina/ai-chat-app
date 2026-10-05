import Foundation
import OutcomeMonitorKit
import StructuredOutputKit
import Testing
import ToolAuthorityKit
import ToolRegistryKit
@testable import AIChatApp

@Suite("Tool outcome check")
struct ToolOutcomeCheckTests {
    private static let instant = Date(timeIntervalSince1970: 1_790_000_000)

    private func success(_ tool: String, _ value: JSONValue) -> ToolCallResult {
        ToolCallResult(id: "c1", toolName: tool, outcome: .success(value))
    }

    private func clockResult(zone: String = "Asia/Kolkata") async throws -> JSONValue {
        try await DemoTools.currentTimeHandler(now: { Self.instant })
            .handle(arguments: .object(["timeZone": .string(zone)]))
    }

    /// A tool registered without a contract would go to the model unchecked, and the stage would
    /// only say `.noOp`. This pins the set so adding a tool without a contract fails here first.
    @Test("every tool the app registers has an outcome contract")
    func everyToolHasAContract() {
        let contracted = Set(ToolOutcomeContracts.all.map(\.tool))
        #expect(contracted == [DemoTools.calculator.name, DemoTools.currentTime.name])
    }

    @Test("the real calculator's result conforms")
    func calculatorConforms() async throws {
        let value = try await DemoTools.calculatorHandler()
            .handle(arguments: .object(["expression": .string("(3 + 4) * 12")]))
        let checked = await ToolOutcomeCheck.check(
            success(DemoTools.calculatorName, value), observation: "obs", monitor: ToolOutcomeCheck.monitor()
        )
        #expect(checked.record.stage == .outcomeMonitor)
        #expect(checked.record.outcome == .ran(detail: "calculator result conforms to its outcome contract"))
        #expect(checked.observation == "obs", "a conforming result is handed over unchanged")
    }

    @Test("the real clock's result conforms in more than one zone")
    func clockConforms() async throws {
        let monitor = ToolOutcomeCheck.monitor()
        for zone in ["Asia/Kolkata", "America/St_Johns", "UTC"] {
            let checked = await ToolOutcomeCheck.check(
                success(DemoTools.clockName, try await clockResult(zone: zone)), observation: "o", monitor: monitor
            )
            #expect(checked.record.outcome == .ran(detail: "current_time result conforms to its outcome contract"))
        }
    }

    /// Both fields are well-formed, so a schema passes it. Only the cross-field property catches
    /// that they name different instants.
    @Test("a clock result whose two renderings disagree gets a receipt naming the recovery call")
    func clockDisagreementIsCaught() async throws {
        guard case var .object(fields) = try await clockResult() else {
            Issue.record("the clock did not return an object")
            return
        }
        fields["unixSeconds"] = .number(Self.instant.timeIntervalSince1970 + 3_600)
        let checked = await ToolOutcomeCheck.check(
            success(DemoTools.clockName, .object(fields)), observation: "obs", monitor: ToolOutcomeCheck.monitor()
        )
        #expect(checked.record.outcome == .ran(
            detail: "current_time broke $: iso8601 and unixSeconds name the same instant — receipt sent to the model"
        ))
        #expect(checked.observation.hasPrefix("obs\n\n[outcome-monitor]"), "the observation is kept, then the receipt")
        #expect(checked.observation.contains("Recovery tools: current_time (call it again with timeZone \"UTC\")"))
    }

    @Test("an unparseable stamp, a missing zone and a negative epoch all break the clock contract")
    func clockFieldViolations() async {
        let broken: JSONValue = .object([
            "timeZone": .string(" "), "iso8601": .string("yesterday"), "unixSeconds": .number(-1)
        ])
        let inspection = await ToolOutcomeCheck.monitor()
            .inspect(tool: DemoTools.clockName, result: ToolOutcomeCheck.rawJSON(broken))
        #expect(inspection.receipt?.violations.map(\.path.description) == ["timeZone", "unixSeconds", "$"])
    }

    /// `JSONEncoder` refuses a non-finite number, and the result must not slip through unchecked
    /// because it could not be rendered.
    @Test("a calculator result that cannot be encoded is a violation at the root")
    func unencodableResult() async {
        #expect(ToolOutcomeCheck.rawJSON(.number(.infinity)) == "<unencodable tool result>")
        let checked = await ToolOutcomeCheck.check(
            success(DemoTools.calculatorName, .object(["expression": .string("1/x"), "result": .number(.nan)])),
            observation: "o",
            monitor: ToolOutcomeCheck.monitor()
        )
        #expect(checked.record.outcome.summary.contains("$: parseable JSON"))
        #expect(checked.observation.contains("No recovery tool is registered for `calculator`"))
    }

    @Test("sorted keys, so the same result always renders the same bytes")
    func rawJSONIsSorted() {
        #expect(ToolOutcomeCheck.rawJSON(.object(["b": .number(1), "a": .bool(true)])) == #"{"a":true,"b":1}"#)
    }

    @Test("a tool error is skipped, and a tool without a contract is a no-op")
    func failureAndUnmonitored() async {
        let failed = ToolCallResult(id: "c", toolName: "calculator", outcome: .failure(.unknownTool("nope")))
        let skipped = await ToolOutcomeCheck.check(failed, observation: "err", monitor: ToolOutcomeCheck.monitor())
        #expect(skipped.record.outcome == .skipped(reason: "the call returned an error, not a result to check"))
        #expect(skipped.observation == "err")
        let other = await ToolOutcomeCheck.check(
            success("weather", .object([:])), observation: "o", monitor: ToolOutcomeCheck.monitor()
        )
        #expect(other.record.outcome == .noOp(reason: "weather has no outcome contract"))
    }

    @Test("the round trip records the check right after dispatch, on every path")
    func roundTripRecordsTheStage() async throws {
        let registry = ToolRegistryKit.ToolRegistry()
        await registry.register(DemoTools.calculator, handler: DemoTools.calculatorHandler())
        await registry.register(DemoTools.currentTime, handler: DemoTools.currentTimeHandler())
        let round = ToolRoundTrip(
            registry: registry,
            gate: ToolAuthorityGate(capabilities: ToolAuthorityGate.readOnly(tools: [DemoTools.calculatorName]))
        )
        let context = ToolCallContext(conversationID: "outcome", provenance: .modelAuthored)

        let ran = await round.resolve(
            id: "c1", toolName: DemoTools.calculatorName, argumentsJSON: Data(#"{"expression":"2*21"}"#.utf8), in: context
        )
        let stages = ran.records.map(\.stage)
        let dispatch = try #require(stages.firstIndex(of: .toolDispatch))
        #expect(stages[dispatch + 1] == .outcomeMonitor)
        #expect(ran.records[dispatch + 1].outcome.summary.contains("conforms"))
        #expect(ran.records.suffix(2).map(\.stage) == [.scopeDrift, .toolCallScheduling])

        let denied = await round.resolve(
            id: "c2", toolName: DemoTools.clockName, argumentsJSON: Data("{}".utf8), in: context
        )
        let check = denied.records.first { $0.stage == .outcomeMonitor }
        #expect(check?.outcome == .skipped(reason: "the call was not authorized, so nothing returned"))

        let cancelled = Task {
            await round.resolve(
                id: "c3", toolName: DemoTools.calculatorName, argumentsJSON: Data(#"{"expression":"1"}"#.utf8), in: context
            )
        }
        cancelled.cancel()
        let skipped = await cancelled.value.records.first { $0.stage == .outcomeMonitor }
        #expect(skipped?.outcome == .skipped(reason: "the turn was cancelled before the call ran"))
    }
}
