import Foundation
import LoopGuardKit

/// Watches one turn's tool hops for a model that is going round in circles.
///
/// `maxToolHops` already stops a turn that never converges, but only after every hop has been
/// paid for, and its refusal can only say "too many calls". A model that sends
/// `calculator(1+1)` twice and gets `2` twice is not going to learn anything from a third
/// identical call. `LoopGuardKit` notices on the second repeat, puts a specific nudge into the
/// observation the model reads next, and if the model repeats itself anyway, stops the turn
/// before the follow-up call that would turn the result into prose.
///
/// The detectors are tuned for a three-hop turn. The package defaults (three repeats, a
/// six-step window) could never fire in a turn this short, which would make the stage a
/// Diagnostics row that watches nothing.
enum ToolLoopWatch {
    static let policy = LoopGuardPolicy(
        detectors: [ExactRepeatDetector(threshold: 2), NoProgressDetector(window: 2)],
        maxNudges: 1,
        historyLimit: 8
    )

    /// What the watch saw over one turn, folded into the stage's outcome when the turn ends.
    struct Summary: Sendable, Equatable {
        var watched = 0
        var nudged: LoopSignal?
        var halted: LoopSignal?

        mutating func absorb(_ verdict: LoopVerdict) {
            watched += 1
            switch verdict {
            case .proceed:
                break
            case let .nudge(signal, _):
                nudged = signal
            case let .halt(signal):
                halted = signal
            }
        }
    }

    static func step(toolName: String, argumentsJSON: Data, observation: String) -> LoopGuardKit.ToolStep {
        LoopGuardKit.ToolStep(
            toolName: toolName,
            arguments: String(data: argumentsJSON, encoding: .utf8) ?? "{}",
            observation: canonicalObservation(observation)
        )
    }

    /// The observation with its JSON payload re-serialized with sorted keys.
    ///
    /// AgentLoopKit's `DefaultAgentPromptStrategy` encodes a tool's result with a plain
    /// `JSONEncoder`, and Swift dictionaries do not promise an iteration order, so the same
    /// `calculator` result can reach the model as `{"expression":…,"result":2}` on one hop and
    /// `{"result":2,"expression":…}` on the next. Compared as raw strings those are two different
    /// observations and an identical-call loop never looks identical. The model still reads the
    /// original text; only the loop guard's copy is canonicalized.
    static func canonicalObservation(_ text: String) -> String {
        guard let start = text.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return text }
        return String(text[..<start]) + ArgumentCanonicalizer.canonicalize(String(text[start...]))
    }

    /// The observation the model reads next: unchanged, or with the nudge appended after it so
    /// the tool's own result still comes first.
    static func observation(_ observation: String, after verdict: LoopVerdict) -> String {
        guard case let .nudge(signal, _) = verdict else { return observation }
        return observation + "\n\n" + signal.nudge
    }

    static func outcome(for summary: Summary, toolsAvailable: Bool) -> StageOutcome {
        guard toolsAvailable else {
            return .skipped(reason: "no tools registered for this conversation")
        }
        if let halted = summary.halted {
            return .refused(refusal(for: halted))
        }
        guard summary.watched > 0 else {
            return .noOp(reason: "no tool call this turn; nothing to watch")
        }
        if let nudged = summary.nudged {
            return .ran(detail: "nudged after \(nudged.summary); the model changed course")
        }
        return .ran(detail: "watched \(summary.watched) tool step(s); no loop")
    }

    /// A refusal the user can act on: what was stopped, why that was the system working, and a
    /// different model as the way forward, the same recovery the hop cap offers.
    static func refusal(for signal: LoopSignal) -> Refusal {
        Refusal(
            stage: .loopGuard,
            headline: "Stopped a repeating tool call",
            explanation: "The assistant kept getting the same result (\(signal.summary)) and did not "
                + "change course when asked, so it was stopped before another paid call.",
            recovery: .switchModel
        )
    }

    static let replayReason = "replayed an earlier result; no tool hops to watch"
}
