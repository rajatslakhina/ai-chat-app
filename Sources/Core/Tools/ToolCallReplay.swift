import Foundation
import ToolAuthorityKit
import TrajectoryConsistencyKit

/// Canonical tool-call arguments, and the replay check behind "approve, then resend".
///
/// `ToolAuthorityGate` keys a signature on `ProposalDigest`, which hashes the argument text it is
/// given. Approving resends the turn, and the call that comes back is a fresh model output: the
/// model writes the same JSON however it likes on that run, with other spacing, other key order,
/// `4` as `4.0`. Before this stage a signature keyed on the text it signed did not recognise the
/// same call spelled again, and the user was asked a second time for something they had already
/// approved. Canonicalizing first means the digest, and the bytes the tool runs with, are the
/// call's values rather than its spelling, so what was approved is exactly what runs.
///
/// Arguments with two readings (a repeated key, two keys Swift would merge, invalid JSON or UTF-8)
/// have no canonical form. They go through exactly as every call did before this stage, and the
/// stage records why. The registry still rejects what it cannot decode.
///
/// When a signature is waiting for its resend, the stage also says whether this call is the one
/// that was signed. If it is not, the approval prompt that follows names what changed, because
/// "Approval needed" twice in a row with no reason looks like the first tap did nothing.
enum ToolCallReplay {
    /// The arguments to authorize and dispatch, and why they were left as written when they were.
    struct Canonical: Sendable, Equatable {
        let arguments: Data
        /// `arguments` as text, which is what the authority digest hashes.
        let text: String
        let problem: CanonicalizationError?
    }

    /// Canonicalizes one call and records the stage, asking the gate whether a signature in this
    /// conversation is waiting for its resend.
    static func prepare(
        _ argumentsJSON: Data,
        tool: String,
        conversationID: String,
        gate: ToolAuthorityGate
    ) async -> (Canonical, StageRecord) {
        let canonical = Self.canonical(argumentsJSON)
        let signed = await gate.signedCallAwaitingReplay(conversationID: conversationID)
        let record = Self.record(original: argumentsJSON, canonical: canonical, tool: tool, signed: signed)
        return (canonical, record)
    }

    static func canonical(_ argumentsJSON: Data) -> Canonical {
        let normalized = ToolRoundTrip.normalized(argumentsJSON)
        // `normalized` reads undecodable bytes as an empty field and sends `{}`, as it did before
        // this stage. That is not a respelling, so it is reported as the problem it is.
        guard let raw = String(data: argumentsJSON, encoding: .utf8) else {
            return Canonical(arguments: normalized, text: "{}", problem: .notUTF8)
        }
        do throws(CanonicalizationError) {
            let value = try CanonicalJSON.parse(normalized)
            return Canonical(arguments: Data(value.canonicalUTF8), text: value.canonicalText, problem: nil)
        } catch {
            // Blank text normalizes to `{}`, which always parses, so `normalized` is `raw` here.
            return Canonical(arguments: normalized, text: raw, problem: error)
        }
    }

    static func record(
        original: Data,
        canonical: Canonical,
        tool: String,
        signed: ApprovalRequest?
    ) -> StageRecord {
        if let problem = canonical.problem {
            return StageRecord(
                stage: .trajectoryConsistency,
                outcome: .skipped(reason: "\(problem); authorized and dispatched without canonicalization"),
                durationMs: 0
            )
        }
        let sizes = "\(original.count) \u{2192} \(canonical.arguments.count) bytes"
        var detail = original == canonical.arguments
            ? "arguments already canonical"
            : "arguments respelled canonically (\(sizes))"
        if let signed {
            let verdict = ReplayCheck.compare(
                reference: ToolStep(tool: signed.tool.raw, arguments: signed.arguments),
                replay: ToolStep(tool: tool, argumentsJSON: canonical.arguments)
            )
            detail += verdict.isSameCall
                ? "; this is the call you signed, so the signature applies"
                : "; this is not the call you signed: \(verdict)"
        }
        return StageRecord(stage: .trajectoryConsistency, outcome: .ran(detail: detail), durationMs: 0)
    }

    /// Why a call asking for approval is not the one the user signed in the same conversation, or
    /// nil when it is that call or the signature belongs to another conversation.
    static func difference(signed: ApprovalRequest, proposed: ApprovalRequest) -> String? {
        guard signed.principal == proposed.principal, signed.digest != proposed.digest else { return nil }
        let verdict = ReplayCheck.compare(
            reference: ToolStep(tool: signed.tool.raw, arguments: signed.arguments),
            replay: ToolStep(tool: proposed.tool.raw, arguments: proposed.arguments)
        )
        return "It differs from the call you approved: \(verdict)."
    }
}
