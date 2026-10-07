import Foundation
import ProgressGateKit

/// Whether a tool turn's answer is supported by what its tools actually returned.
///
/// The agent loop ends a turn when the model stops asking for tools and answers. That answer is the
/// model's own report that the work is done, and until now the loop took it at its word. *The
/// Unreliable Progress Bar* (arXiv 2609.08589) found that models report their progress reliably at
/// some stages of a task and not at others, and advises frameworks not to control task flow on the
/// model's report alone. `ProgressGateKit` checks the report against evidence instead.
///
/// The evidence here is what `OutcomeMonitorKit` already decided about each result. When a result
/// breaks its outcome contract, the model is handed a receipt naming the recovery tool, and the
/// model decides what to do with it. If it answers without calling that tool again, the answer
/// rests on a result the app has already flagged, and saying "done" does not change that. The turn
/// still publishes the model's prose; the refusal banner says what it rests on, and the turn is not
/// cached, so Try again really asks again.
///
/// Deliberately not a nudge-and-continue. Sending the gate's guidance back for another hop would
/// cost a paid call, and the overclaiming answer has already streamed onto the screen, so the second
/// answer would be appended under the first. Telling the user is cheaper and honest.
///
/// Honest scope, as for the outcome check itself: both of this app's tools compute locally and
/// neither has broken its contract in testing, so today this guards against a regression in a tool
/// reaching the user as a finished answer, rather than catching a live fault.
enum ToolProgressCheck {
    /// What one turn's tool hops established.
    struct Ledger: Sendable, Equatable {
        /// Calls the registry actually dispatched, successful or not.
        var dispatched = 0
        /// The latest contract verdict per tool: `true` kept it (or has none), `false` broke it.
        /// A later call to the same tool that keeps its contract clears an earlier breach.
        var latest: [String: Bool] = [:]

        /// Folds in one hop. `keptContract` is nil when there was no result to check (the call
        /// errored or never ran), which leaves that tool's last verdict standing.
        mutating func absorb(tool: String, dispatched ran: Bool, keptContract: Bool?) {
            if ran { dispatched += 1 }
            if let keptContract { latest[tool] = keptContract }
        }

        /// Tools whose latest result broke its contract, sorted so the banner reads the same way
        /// every time.
        var broken: [String] {
            latest.filter { !$0.value }.map(\.key).sorted()
        }

        var evidence: Evidence {
            Evidence([
                "tool.dispatched": .number(Double(dispatched)),
                "contracts.broken": .number(Double(broken.count))
            ])
        }
    }

    static let keptContracts = "every tool's latest result kept its outcome contract"

    /// A tool turn's lifecycle: a tool ran, and then every result it is answering from held up.
    static func ladder() throws -> StageLadder {
        try StageLadder(baseline: "asked", stages: [
            Stage("tool ran", requires: .atLeast("tool.dispatched", 1)),
            Stage("results checked", requires: .custom(keptContracts) { evidence in
                evidence["contracts.broken"] == .number(0)
            })
        ])
    }

    /// The model answered, which claims the turn is done. The claim is checked against the ledger.
    ///
    /// `build` exists so a test can hand in a ladder that fails to build; the app always uses
    /// `ladder()`, whose two distinct stage names cannot fail.
    static func outcome(
        answeredWith ledger: Ledger,
        toolsAvailable: Bool,
        ladder build: () throws -> StageLadder = ladder
    ) -> StageOutcome {
        guard toolsAvailable else {
            return .skipped(reason: "no tools registered for this conversation")
        }
        guard ledger.dispatched > 0 else {
            return .noOp(reason: "model answered directly; no tool evidence to check the answer against")
        }
        let audit: StageAudit
        do {
            audit = try build().audit(.done, against: ledger.evidence)
        } catch {
            return .failed(message: "the completion ladder could not be built: \(error)")
        }
        guard audit.reading.isFinal else {
            return .refused(refusal(for: ledger.broken))
        }
        return .ran(detail: "answer supported by evidence: \(ledger.dispatched) tool result(s), "
            + "and \(keptContracts)")
    }

    /// The turn ended without an answer (hop cap, loop guard, a declined call), so nothing claimed
    /// the turn was done.
    static func unanswered(toolsAvailable: Bool) -> StageOutcome {
        guard toolsAvailable else {
            return .skipped(reason: "no tools registered for this conversation")
        }
        return .skipped(reason: unansweredReason)
    }

    static let unansweredReason =
        "the turn ended before the model answered; there was no completion claim to check"
    static let replayReason = "replayed an earlier result; no tool hops to check an answer against"

    static func refusal(for broken: [String]) -> Refusal {
        let tools = broken.joined(separator: " and ")
        let what = broken.count == 1 ? "a result that broke its check" : "results that broke their checks"
        return Refusal(
            stage: .progressGate,
            headline: "Answered on an unverified result",
            explanation: "\(tools) returned \(what), and the assistant answered without checking again. "
                + "Treat the answer as unverified.",
            recovery: .retryLater(after: nil)
        )
    }
}
