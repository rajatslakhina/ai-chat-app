import ProviderGatewayKit
import SessionMaskKit

extension PreModelPipeline {
    /// Gives every sensitive value in the outgoing messages one token for the whole conversation.
    ///
    /// The last thing before the wire, after compaction, on every message that will be sent. Its
    /// real job is the history. `guardrailInput` redacts the message being sent, but the history
    /// is rebuilt every turn from what the bubbles hold, and a user bubble holds what was typed:
    /// a card number redacted on turn 1 was sent raw inside the history on turn 2 and every turn
    /// after it. Memory recall and retrieved excerpts arrive in the system block and are masked
    /// the same way.
    ///
    /// The same value gets the same token on every turn, so the history is byte-identical to what
    /// the previous turn sent, which is also what keeps it a reusable prompt-cache prefix.
    ///
    /// No refusal. Masking fixes what it finds, so there is nothing for the user to act on. If the
    /// vault cannot be made the stage records `.failed` and the turn goes out as it did before
    /// this stage existed: unmasked history, guardrail-redacted message.
    func maskSession(
        _ messages: [ConversationMessage],
        conversationID: String,
        trace: inout PipelineTrace
    ) async -> [ConversationMessage] {
        let vault: MaskVault
        do {
            vault = try await masks.vault(for: conversationID)
        } catch {
            trace.record(.sessionMask, .failed(message: "no vault for this conversation: \(error)"))
            return messages
        }
        var masked: [ConversationMessage] = []
        var counts: [MaskCategory: Int] = [:]
        var touched = 0
        for message in messages {
            let result = await vault.mask(message.text, source: Self.maskSource(for: message.role))
            touched += result.isUnchanged ? 0 : 1
            for replacement in result.replacements {
                counts[replacement.token.category, default: 0] += 1
            }
            masked.append(
                ConversationMessage(
                    id: message.id,
                    role: message.role,
                    text: result.text,
                    pinned: message.pinned
                )
            )
        }
        guard touched > 0 else {
            trace.record(.sessionMask, .noOp(reason: "nothing to mask in \(messages.count) message(s)"))
            return messages
        }
        let total = counts.values.reduce(0, +)
        let summary = counts.sorted { $0.key < $1.key }.map { "\($0.key.label) x\($0.value)" }
        trace.record(
            .sessionMask,
            .ran(
                detail: "masked \(total) value(s) in \(touched) of \(messages.count) message(s) "
                    + "(\(summary.joined(separator: ", "))); the same value keeps its token every turn"
            )
        )
        return masked
    }

    static func maskSource(for role: LLMMessageRole) -> MaskSource {
        switch role {
        case .user: return .user
        case .assistant: return .assistant
        case .system: return MaskSource("system")
        case .tool: return .tool("result")
        }
    }
}
