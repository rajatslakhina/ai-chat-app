import Foundation
import ProviderGatewayKit

/// What the pre-model stages produce: everything needed to make the call, or a reason not to.
///
/// The three cases are deliberately not one optional. "Ready to send", "already answered from
/// cache" and "refused before we spent anything" are three different things a chat UI has to
/// render differently, and an optional plus a side-channel error would let a caller forget one.
enum TurnPreparation: Sendable, Equatable {
    /// Send this.
    case ready(PreparedTurn)
    /// The cache already had the answer. No provider call, no cost, no tokens.
    case cached(text: String, providerID: String)
    /// A stage said no. Nothing was sent and nothing was spent.
    case refused(Refusal)
}

/// One retrieved passage, in the shape the chat UI shows as a source chip.
struct RetrievedSource: Sendable, Equatable, Identifiable {
    let id: String
    let title: String
    let snippet: String
    /// 0...100, so the UI can draw a relevance bar without knowing about cosine distance.
    let relevancePercent: Int

    /// What this passage is a reading *of*, for the temporal pass. `nil` when the corpus did not
    /// say — which is not the same as "one subject", so supersession simply is not asked.
    let subject: String?

    /// When this passage was last known accurate, carried from the corpus rather than guessed.
    ///
    /// Optional and it has to be: the lexical half of retrieval produces hits with no date, and a
    /// stand-in here would turn "unknown" into "fresh" — the one direction that costs trust. This
    /// app has already written down twice what happens when a stage infers provenance from
    /// whatever field was nearest to hand.
    let observedAt: Date?

    init(
        id: String,
        title: String,
        snippet: String,
        relevancePercent: Int,
        subject: String? = nil,
        observedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.snippet = snippet
        self.relevancePercent = relevancePercent
        self.subject = subject
        self.observedAt = observedAt
    }
}

/// The assembled request, plus what the assembly cost the user in visible terms.
struct PreparedTurn: Sendable, Equatable {
    /// The model this turn should go to, chosen by the semantic router or the default.
    let modelID: String
    /// The messages to send, after templating, redaction, retrieval and compaction.
    let messages: [LLMMessage]
    /// The user's text as it will actually leave the device — redacted if the guardrail redacted.
    let outboundUserText: String
    /// The user's text as they typed it, kept so the bubble shows what they wrote.
    let displayUserText: String
    /// Sources injected by retrieval, for the "3 sources" chip.
    let sources: [RetrievedSource]
    /// True when compaction dropped or summarized earlier turns, so the UI can show the divider.
    let didCompact: Bool
    /// Approximate input size after all of the above, for the context meter.
    let estimatedInputTokens: Int

    /// `LLMMessage` carries a `UUID` that is fresh on every construction, so the synthesized `==`
    /// would report two structurally identical turns as different. Comparison is on what the
    /// provider would actually receive.
    static func == (lhs: PreparedTurn, rhs: PreparedTurn) -> Bool {
        lhs.modelID == rhs.modelID
            && lhs.outboundUserText == rhs.outboundUserText
            && lhs.displayUserText == rhs.displayUserText
            && lhs.sources == rhs.sources
            && lhs.didCompact == rhs.didCompact
            && lhs.estimatedInputTokens == rhs.estimatedInputTokens
            && lhs.messages.map(\.content) == rhs.messages.map(\.content)
            && lhs.messages.map(\.role) == rhs.messages.map(\.role)
    }
}

/// A turn as the conversation holds it, before any package has touched it.
///
/// Kept separate from `LLMMessage` because the UI needs things the gateway does not model — a
/// stable identity for SwiftUI, and the *displayed* text as distinct from the *sent* text, which
/// diverge the moment the guardrail redacts something.
struct ConversationMessage: Sendable, Equatable, Identifiable {
    let id: UUID
    let role: LLMMessageRole
    let text: String
    /// Pinned messages survive compaction. The system prompt is always pinned.
    let pinned: Bool

    init(id: UUID = UUID(), role: LLMMessageRole, text: String, pinned: Bool = false) {
        self.id = id
        self.role = role
        self.text = text
        self.pinned = pinned
    }

    /// The same characters/4 approximation ProviderGatewayKit uses, so the context meter in the
    /// composer and the gateway's own budget check never disagree about how big a turn is.
    var estimatedTokens: Int { max(1, text.count / 4) }
}
