import ContextCompactionKit
import ResponseCacheKit
import Foundation
import ProviderGatewayKit
import RetrievalKit

extension PreModelPipeline {
    /// Stores a completed exchange so the cache can serve the next identical one.
    ///
    /// Separate from `prepare` because it must only run after a turn genuinely succeeded —
    /// caching a refusal, or remembering a failed answer, poisons every later turn.
    func recordCompletion(
        turn: PreparedTurn,
        systemPrompt: String?,
        answer: String,
        providerID: String,
        estimatedCost: Decimal = 0
    ) async {
        guard settings.cacheEnabled else { return }
        await cache.store(
            CachedResponse(text: answer, providerID: providerID),
            for: CacheableRequest(
                modelID: turn.modelID,
                systemPrompt: systemPrompt,
                prompt: turn.outboundUserText
            ),
            estimatedCost: estimatedCost
        )
    }

    func assemble(
        systemPrompt: String,
        memoryBlock: String,
        retrievalBlock: String,
        history: [ConversationMessage],
        userText: String
    ) -> [ConversationMessage] {
        var messages: [ConversationMessage] = []
        var system = systemPrompt
        if !memoryBlock.isEmpty {
            system += "\n\nWhat you remember about this user:\n\(memoryBlock)"
        }
        if !retrievalBlock.isEmpty {
            system += "\n\nRelevant excerpts from the user's documents, each labelled with the "
                + "identifier to cite it by:\n\(retrievalBlock)"
                + "\n\nWhen a statement comes from one of these excerpts, cite it inline as "
                + "[identifier]. Cite only identifiers listed above."
        }
        if !system.isEmpty {
            // Pinned: the system block must survive compaction, or the model loses its
            // instructions exactly when the conversation is longest and needs them most.
            messages.append(ConversationMessage(role: .system, text: system, pinned: true))
        }
        messages.append(contentsOf: history)
        messages.append(ConversationMessage(role: .user, text: userText))
        return messages
    }

    static func compactable(_ message: ConversationMessage) -> CompactableMessage {
        CompactableMessage(
            id: message.id,
            role: CompactableRole(message.role),
            content: message.text,
            pinned: message.pinned
        )
    }

    static func conversational(_ message: CompactableMessage) -> ConversationMessage {
        ConversationMessage(
            id: message.id,
            role: message.role.llmRole,
            text: message.content,
            pinned: message.pinned
        )
    }
}

extension CompactableRole {
    /// The two role vocabularies line up one-for-one, including `.tool`.
    ///
    /// Worth stating because the obvious shortcut is wrong: flattening a tool result into
    /// assistant text would let a summarizing strategy rewrite a tool's output as prose, and the
    /// model would then be reasoning over a paraphrase of its own tool call rather than the
    /// result. Keeping the role intact keeps that distinction through compaction.
    init(_ role: LLMMessageRole) {
        switch role {
        case .system: self = .system
        case .user: self = .user
        case .assistant: self = .assistant
        case .tool: self = .tool
        }
    }

    var llmRole: LLMMessageRole {
        switch self {
        case .system: return .system
        case .user: return .user
        case .assistant: return .assistant
        case .tool: return .tool
        }
    }
}

extension RetrievedSource {
    init(_ scored: ScoredChunk) {
        self.id = scored.chunk.id
        self.title = scored.chunk.metadata["filename"] ?? scored.chunk.documentID
        self.snippet = String(scored.chunk.text.prefix(160))
        // Cosine similarity is 0...1 here; clamped because a scorer swap must not produce a bar
        // that overflows its track.
        self.relevancePercent = min(100, max(0, Int((scored.score * 100).rounded())))
    }
}
