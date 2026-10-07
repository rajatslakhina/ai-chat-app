import Foundation
import OutcomeMonitorKit
import StructuredOutputKit
import ToolRegistryKit

/// What each of this app's tools promises about its *result*.
///
/// `ToolRegistryKit` validates a call's arguments before the handler runs; nothing looked at what
/// the handler handed back before the model read it as fact. These contracts do. Both tools compute
/// their answers locally, so in testing neither has broken its contract: the contracts are a guard
/// against a regression in the tool (a time zone formatted wrong, an evaluator that lets a
/// non-finite value through) reaching the model looking like an answer.
enum ToolOutcomeContracts {
    static var all: [OutcomeContract] { [calculator, currentTime] }

    /// A calculator result names the expression it evaluated and a finite number. There is no
    /// recovery tool: the evaluator is deterministic, so calling it again would return the same
    /// value, and the receipt says to treat it as unverified instead.
    static let calculator = OutcomeContract(
        tool: DemoTools.calculatorName,
        properties: [.nonEmpty("expression"), .range("result")]
    )

    /// A clock result must name its zone, and its two renderings of the instant must agree. The
    /// second property is the one a schema cannot express: both fields can be well-formed while
    /// one of them is wrong.
    static let currentTime = OutcomeContract(
        tool: DemoTools.clockName,
        properties: [
            .nonEmpty("timeZone"),
            .kind("iso8601", .string),
            .range("unixSeconds", min: 0),
            sameInstant
        ],
        recoveryTools: [
            RecoveryTool(name: DemoTools.clockName, purpose: "call it again with timeZone \"UTC\"")
        ]
    )

    static let sameInstant = OutcomeProperty(
        path: .root,
        expectation: "iso8601 and unixSeconds name the same instant"
    ) { value in
        guard case let .object(fields)? = value,
              case let .string(stamp)? = fields["iso8601"],
              case let .number(seconds)? = fields["unixSeconds"],
              let date = ISO8601DateFormatter().date(from: stamp) else { return false }
        return abs(date.timeIntervalSince1970 - seconds) < 1
    }
}

/// Runs `OutcomeMonitorKit` over a tool result and decides what the model is handed.
///
/// The monitor never withholds or rewrites a result. A violation adds a receipt after the
/// observation, naming the broken property and the recovery tool, and the model decides. It is not
/// a refusal, so nothing here can stop the turn: the stage records what it found, and Diagnostics
/// shows it.
enum ToolOutcomeCheck {
    static func monitor() -> OutcomeMonitor {
        OutcomeMonitor(contracts: ToolOutcomeContracts.all)
    }

    /// The stage record for a call that dispatched, and the observation to send back.
    static func check(
        _ result: ToolCallResult,
        observation: String,
        monitor: OutcomeMonitor
    ) async -> Checked {
        guard case let .success(value) = result.outcome else {
            return Checked(
                record: skipped("the call returned an error, not a result to check"),
                observation: observation,
                keptContract: nil
            )
        }
        let inspection = await monitor.inspect(tool: result.toolName, result: rawJSON(value))
        return Checked(
            record: StageRecord(stage: .outcomeMonitor, outcome: outcome(of: inspection), durationMs: 0),
            observation: inspection.annotate(observation),
            keptContract: keptContract(inspection)
        )
    }

    /// One checked result: the stage record, the observation the model reads, and whether the
    /// result kept its contract (nil when there was no result to check).
    struct Checked: Sendable {
        let record: StageRecord
        let observation: String
        let keptContract: Bool?
    }

    /// What the completion check reads: only a broken contract counts against the answer. A tool
    /// with no contract has nothing to break.
    static func keptContract(_ inspection: Inspection) -> Bool {
        guard case .violated = inspection else { return true }
        return false
    }

    static func skipped(_ reason: String) -> StageRecord {
        StageRecord(stage: .outcomeMonitor, outcome: .skipped(reason: reason), durationMs: 0)
    }

    static func outcome(of inspection: Inspection) -> StageOutcome {
        switch inspection {
        case let .conforms(tool):
            return .ran(detail: "\(tool) result conforms to its outcome contract")
        case let .unmonitored(tool):
            return .noOp(reason: "\(tool) has no outcome contract")
        case let .violated(receipt):
            let broken = receipt.violations.map(\.property).joined(separator: "; ")
            return .ran(detail: "\(receipt.tool) broke \(broken) — receipt sent to the model")
        }
    }

    /// Sorted keys, so the same result always produces the same bytes. A value `JSONEncoder`
    /// refuses (a NaN or an infinity) comes back as text that does not parse, which the monitor
    /// then reports as a violation at `$` instead of passing it along unchecked.
    static func rawJSON(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
              let text = String(bytes: data, encoding: .utf8) else { return "<unencodable tool result>" }
        return text
    }
}
