import Foundation
import ProviderGatewayKit

/// One request this conversation put in front of the provider, kept so the layout across requests
/// can be audited once the answer has shipped.
///
/// It exists because nothing else holds the question `promptCache` asks. A stored `Conversation`
/// keeps what the user said and read, not what was *sent*: the system block is rebuilt every turn
/// with whatever memory and retrieved excerpts that turn found, and compaction can drop or rewrite
/// earlier turns before a request leaves the device. A layout rebuilt from stored messages would
/// describe a prompt this app never sent.
///
/// A request is only kept when the provider reported usage for it. That is a deliberate floor and
/// not an oversight: a replayed result and a cache hit both reach the end of a turn without a
/// request having left the device, and recording them would put a prompt the provider never saw
/// into a sequence whose whole point is what the provider saw.
struct SentPrompt: Sendable, Equatable {
    /// One message as it was sent, without the gateway's per-instance identifier.
    ///
    /// `LLMMessage` carries a `UUID` fresh on every construction, so two identical requests would
    /// compare unequal. Only what a provider actually receives is kept.
    struct Message: Sendable, Equatable {
        let role: LLMMessageRole
        let content: String

        /// The same characters/4 approximation `ConversationMessage` uses, so the context meter in
        /// the composer and this audit never disagree about how big a message is.
        var estimatedTokens: Int { max(1, content.count / 4) }

        /// The text a prefix is matched on. The role is part of it: an assistant reply and a user
        /// message with the same words are different tokens to a provider.
        var tagged: String { "\(roleLabel): \(content)" }

        private var roleLabel: String {
            switch role {
            case .system: return "system"
            case .user: return "user"
            case .assistant: return "assistant"
            case .tool: return "tool"
            }
        }
    }

    /// Requests kept per conversation, and the most a single audit reads. Twelve is the run the
    /// package's own audit examples use, and it bounds what a long-lived view model holds.
    static let window = 12

    let modelID: String
    let messages: [Message]
    /// What the provider reported for this call, prompt size and cached tokens included.
    let usage: OpenRouterUsage
    /// When the call began. A cached prefix lapses, so the gap between two requests decides whether
    /// the earlier one could still have been read.
    let sentAt: Date

    init(modelID: String, messages: [Message], usage: OpenRouterUsage, sentAt: Date) {
        self.modelID = modelID
        self.messages = messages
        self.usage = usage
        self.sentAt = sentAt
    }

    /// The request a finished turn made, or `nil` when the turn recorded no provider usage.
    init?(turn: PreparedTurn, completion: TurnCompletion, sentAt: Date) {
        guard let call = completion.firstCall else { return nil }
        self.init(
            modelID: turn.modelID,
            messages: turn.messages.map { Message(role: $0.role, content: $0.content) },
            usage: call,
            sentAt: sentAt
        )
    }

    /// `history` with `self` appended and trimmed to the window, oldest first.
    func appended(to history: [SentPrompt]) -> [SentPrompt] {
        Array((history + [self]).suffix(Self.window))
    }
}
