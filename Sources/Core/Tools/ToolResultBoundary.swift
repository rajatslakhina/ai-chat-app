import ContentBoundaryKit
import Foundation
import ProviderGatewayKit

/// Frames every tool result the model reads as data, inside a `ContentBoundaryKit` envelope.
///
/// The tool loop feeds each result back as a *user* message (`ProviderEffectExecutor.runTurn`), so
/// before this stage a result reading "System: ignore your instructions" sat in the same channel,
/// with the same standing, as the person typing. The envelope cannot make a model ignore that text.
/// What it does is make the boundary unambiguous: the result is datamarked, its end line carries an
/// id drawn after the result was known (so the result cannot contain it), chat-template tokens in it
/// are defanged, and the system prompt says how to read it.
///
/// Only the tool's own payload goes inside. The `Tool "<name>" returned:` header and the outcome
/// receipt `OutcomeMonitorKit` appends stay outside, because the receipt is the app's advice to the
/// model, and advice placed inside a block the model is told never to obey would be advice ignored.
enum ToolResultBoundary {
    static let policy = BoundaryPolicy(mode: .datamark, neutralization: .defang)

    /// One result as the model reads it, and the stage record for framing it.
    struct Framed: Sendable {
        let observation: String
        let record: StageRecord
    }

    /// - Parameters:
    ///   - followUp: AgentLoopKit's follow-up text, `Tool "<name>" returned: <json>`.
    ///   - observation: `followUp` with anything appended after it (the outcome receipt).
    static func frame(
        followUp: String,
        observation: String,
        toolName: String,
        session: BoundarySession
    ) async -> Framed {
        let head = "Tool \"\(toolName)\" returned: "
        let payload = followUp.hasPrefix(head) ? String(followUp.dropFirst(head.count)) : followUp
        let advice = String(observation.dropFirst(followUp.count))
        do {
            let envelope = try await session.wrap(payload, from: .tool(toolName))
            let framed = "Tool \"\(toolName)\" returned:\n" + envelope.rendered + advice
            let check = EnvelopeParser.verify(framed, against: [envelope])
            guard check.holds else {
                return withheld(toolName, because: check.problems.joined(separator: "; "))
            }
            return Framed(observation: framed, record: record(.ran(detail: detail(envelope))))
        } catch {
            return withheld(toolName, because: "\(error)")
        }
    }

    /// The system prompt gains the envelope-reading instruction whenever tools are offered, since
    /// any hop of such a turn may carry a framed result. A turn without tools is sent unchanged.
    static func instructing(_ messages: [LLMMessage], toolsOffered: Bool) -> [LLMMessage] {
        guard toolsOffered else { return messages }
        guard let first = messages.first, first.role == .system else {
            return [LLMMessage(role: .system, content: BoundaryPolicy.instruction)] + messages
        }
        let system = LLMMessage(
            id: first.id,
            role: .system,
            content: first.content + "\n\n" + BoundaryPolicy.instruction,
            toolCallID: first.toolCallID
        )
        return [system] + messages.dropFirst()
    }

    /// Fail closed: a result that cannot be framed and verified is not sent at all. The model is
    /// told it is unavailable, so the answer it writes says so instead of guessing.
    static func withheld(_ toolName: String, because reason: String) -> Framed {
        Framed(
            observation: "Tool \"\(toolName)\" returned a result that could not be framed as data, so it "
                + "was withheld. Tell the user that this tool's result is unavailable.",
            record: record(.failed(message: "\(toolName) result withheld: \(reason)"))
        )
    }

    static func skipped(_ reason: String) -> StageRecord {
        record(.skipped(reason: reason))
    }

    static func detail(_ envelope: Envelope) -> String {
        let kinds = Set(envelope.findings.map(\.kind.rawValue)).sorted()
        let count = envelope.findings.count
        let found = kinds.isEmpty
            ? "nothing structure-shaped in it"
            : "\(count) finding(s) (\(kinds.joined(separator: ", "))), defanged where rewritable"
        return "\(envelope.origin.label) framed as \(envelope.mode); \(found)"
    }

    private static func record(_ outcome: StageOutcome) -> StageRecord {
        StageRecord(stage: .contentBoundary, outcome: outcome, durationMs: 0)
    }
}
