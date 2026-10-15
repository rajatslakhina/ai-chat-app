import DegenerationGuardKit

/// A model that starts repeating itself rarely stops before its output cap. OpenRouter returns
/// HTTP 200 for it, the stream keeps going, and every repeated token is billed, streamed into the
/// bubble and kept in the history the next turn re-sends.
///
/// `DegenerationGuardKit`'s monitor sits in `ProviderEffectExecutor.streamOnce`, one per model
/// call, fed every fragment as it arrives. When the answer ends in the same passage or sentence
/// four times in a row, the executor stops reading, which cancels the request, and keeps the text
/// before the second copy. The answer is still delivered, cut back to that point, and the stage
/// refuses with a banner so the user knows the answer was cut short and can ask again. A refusal
/// also keeps the cut answer out of the response cache, so Try again reaches the model.
///
/// What it costs: OpenRouter sends the usage envelope with the last event, and a loop that is cut
/// is still being generated, so a cut turn normally ends with no usage and the metering stage says
/// so. The part that was read was billed and is not in the month's total; see the README's
/// "Remaining work".
enum LiveDegenerationGuard {
    /// What the monitors saw across the model calls of one attempt.
    struct Summary: Sendable, Equatable {
        var calls = 0
        var scanned = 0
        var finding: DegenerationFinding?

        mutating func absorb(_ monitor: DegenerationMonitor) {
            calls += 1
            scanned += monitor.scanned
            if finding == nil { finding = monitor.finding }
        }
    }

    /// Digits compared as written: these are answers a person reads, and masking them would cut
    /// a times table or a price list (DegenerationGuardKit's README measures 4 of 12).
    static let policy = DegenerationPolicy.standard

    static let replayed: StageOutcome = .noOp(reason: "replayed an earlier result; nothing streamed to check")

    static let notCalled: StageOutcome = .skipped(
        reason: "the idempotency guard stopped the turn before anything streamed"
    )

    static let discarded: StageOutcome = .noOp(
        reason: "the call did not finish; no answer was delivered to check"
    )

    /// What the monitors found for a turn that completed.
    static func outcome(_ summary: Summary) -> StageOutcome {
        guard let finding = summary.finding else {
            let checked = "checked \(summary.scanned) character(s) over \(summary.calls) model call(s)"
            return .noOp(reason: checked + "; no repetition")
        }
        return .refused(refusal(for: finding))
    }

    static func refusal(for finding: DegenerationFinding) -> Refusal {
        Refusal(
            stage: .degenerationGuard,
            headline: "The answer started repeating itself",
            explanation: "The model wrote \(repeated(finding.kind)), so the app stopped reading after "
                + "\(finding.detectedAt) characters instead of paying for the rest. The repetition was "
                + "removed: you are seeing the answer up to where it began.",
            recovery: .retryLater(after: nil)
        )
    }

    /// What repeated, in words.
    static func repeated(_ kind: LoopKind) -> String {
        switch kind {
        case let .verbatim(period, copies):
            return "the same \(period)-character passage \(copies) times in a row"
        case let .unitCycle(units, copies):
            let what = units == 1 ? "sentence" : "\(units) sentences"
            return "the same \(what) \(copies) times in a row"
        case let .custom(name):
            return "a repeating pattern (\(name))"
        }
    }
}
