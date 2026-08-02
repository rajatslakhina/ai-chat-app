import AgentMemoryKit
import ContextCompactionKit
import Foundation
import GuardrailKit
import PromptTemplateKit
import ProviderGatewayKit
import ResponseCacheKit
import RetrievalKit
import SemanticRouterKit

/// Knobs the Settings screen owns.
struct PipelineSettings: Sendable, Equatable {
    var defaultModelID: String = "openai/gpt-4o"
    var promptName: String = "chat.system"
    var contextWindowTokens: Int = 128_000
    var reservedResponseTokens: Int = 1_024
    var retrievalTopK: Int = 3
    var memoryTopK: Int = 3
    var retrievalEnabled: Bool = true
    var memoryEnabled: Bool = true
    var cacheEnabled: Bool = true
    var routingEnabled: Bool = true
}

/// Runs everything that happens before the model is called.
///
/// An actor because it owns seven other actors and is driven from a `@MainActor` view model; the
/// stages must not interleave across two concurrent sends of the same conversation.
///
/// The ordering is not arbitrary. Templating comes first so the guardrail screens the *rendered*
/// text rather than a template that hides PII behind a variable. Routing comes before the cache so
/// a cache key is scoped to the model that would actually have answered. Retrieval comes before
/// compaction so retrieved passages are subject to the same budget as everything else — the
/// opposite order lets retrieval push the conversation over the window and get it silently
/// truncated afterwards.
actor PreModelPipeline {
    private let prompts: PromptRegistry
    private let guardrail: GuardrailPipeline
    private let router: SemanticRouter
    let cache: ResponseCache
    private let memory: MemoryStore
    private let retriever: Retriever
    private let compactor: ContextCompactor
    var settings: PipelineSettings

    init(
        prompts: PromptRegistry,
        guardrail: GuardrailPipeline,
        router: SemanticRouter,
        cache: ResponseCache,
        memory: MemoryStore,
        retriever: Retriever,
        compactor: ContextCompactor,
        settings: PipelineSettings = PipelineSettings()
    ) {
        self.prompts = prompts
        self.guardrail = guardrail
        self.router = router
        self.cache = cache
        self.memory = memory
        self.retriever = retriever
        self.compactor = compactor
        self.settings = settings
    }

    func update(settings: PipelineSettings) {
        self.settings = settings
    }

    /// Prepares one turn, recording what every stage did into `trace`.
    ///
    /// `trace` is `inout` rather than returned alongside because the caller needs it even when a
    /// stage refuses — a refusal with no record of the stages that ran before it is exactly the
    /// thing the Diagnostics screen exists to prevent.
    func prepare(
        userText: String,
        history: [ConversationMessage],
        trace: inout PipelineTrace
    ) async -> TurnPreparation {
        let systemPrompt = await renderTemplate(trace: &trace)

        // A `switch` rather than `guard case`: `ScreenResult` has exactly two cases, and the
        // `guard`-shaped version needed a second `guard` whose else-branch no input could reach.
        let outbound: String
        switch await screenInput(userText, trace: &trace) {
        case let .allowed(text): outbound = text
        case let .refused(refusal): return .refused(refusal)
        }

        let modelID = await chooseModel(for: outbound, trace: &trace)

        if let cached = await lookupCache(
            model: modelID,
            systemPrompt: systemPrompt,
            outbound: outbound,
            trace: &trace
        ) {
            return .cached(text: cached.text, providerID: cached.providerID)
        }

        let memoryBlock = await recallMemory(for: outbound, trace: &trace)
        let (sources, retrievalBlock) = await retrievePassages(for: outbound, trace: &trace)

        let assembled = assemble(
            systemPrompt: systemPrompt,
            memoryBlock: memoryBlock,
            retrievalBlock: retrievalBlock,
            history: history,
            userText: outbound
        )
        let (finalMessages, didCompact) = await compactIfNeeded(assembled, trace: &trace)

        return .ready(
            PreparedTurn(
                modelID: modelID,
                messages: finalMessages.map { LLMMessage(role: $0.role, content: $0.text) },
                outboundUserText: outbound,
                displayUserText: userText,
                sources: sources,
                didCompact: didCompact,
                estimatedInputTokens: finalMessages.reduce(0) { $0 + $1.estimatedTokens }
            )
        )
    }

    // MARK: - Stages

    /// The system block, versioned and rolled back independently of code.
    private func renderTemplate(trace: inout PipelineTrace) async -> String {
        do {
            let rendered = try await prompts.render(
                name: settings.promptName,
                variables: ["locale": Locale.current.identifier]
            )
            let version = try await prompts.activeVersion(name: settings.promptName)
            trace.record(.promptTemplate, .ran(detail: "\(settings.promptName) v\(version.id)"))
            return rendered
        } catch {
            // A missing template is a config error, not something a user can fix — but the turn
            // can still proceed without a system block, so this degrades rather than refuses.
            trace.record(.promptTemplate, .failed(message: "\(error)"))
            return ""
        }
    }

    private enum ScreenResult {
        case allowed(String)
        case refused(Refusal)
    }

    /// Screens the RENDERED text, so nothing hides behind a template variable.
    private func screenInput(_ userText: String, trace: inout PipelineTrace) async -> ScreenResult {
        let screened = await guardrail.screenRequest(userText)
        switch screened.verdict {
        case .allow:
            trace.record(.guardrailInput, .noOp(reason: "no findings"))
        case .redacted:
            trace.record(
                .guardrailInput,
                .ran(detail: "redacted \(screened.findings.count) span(s) before sending")
            )
        case let .blocked(reason):
            let refusal = Refusal(
                stage: .guardrailInput,
                headline: "Message not sent",
                explanation: reason,
                recovery: nil
            )
            trace.record(.guardrailInput, .refused(refusal))
            return .refused(refusal)
        }
        // `textToForward` is nil for exactly one verdict — `.blocked` — and that verdict has
        // already returned above, so unwrapping it here needed a second refusal branch no message
        // could reach. The sanitized text is what forwards in both of the remaining cases, and it
        // is the original text unchanged when nothing was redacted.
        return .allowed(screened.sanitizedText)
    }

    /// Picks the model before anything is priced against it.
    private func chooseModel(for outbound: String, trace: inout PipelineTrace) async -> String {
        guard settings.routingEnabled else {
            trace.record(.semanticRoute, .skipped(reason: "routing disabled in Settings"))
            return settings.defaultModelID
        }
        do {
            guard let match = try await router.route(outbound) else {
                // Not a failure. No route cleared its threshold, so the default answers.
                trace.record(.semanticRoute, .noOp(reason: "no route matched; using default"))
                return settings.defaultModelID
            }
            let model = match.route.metadata["model"] ?? settings.defaultModelID
            let score = Int((match.score * 100).rounded())
            trace.record(.semanticRoute, .ran(detail: "\(match.routeName) → \(model) (\(score)%)"))
            return model
        } catch {
            trace.record(.semanticRoute, .failed(message: "\(error)"))
            return settings.defaultModelID
        }
    }

    /// Keyed on the chosen model, so a cheap model's answer is never served as the expensive one's.
    private func lookupCache(
        model: String,
        systemPrompt: String,
        outbound: String,
        trace: inout PipelineTrace
    ) async -> CachedResponse? {
        guard settings.cacheEnabled else {
            trace.record(.cacheLookup, .skipped(reason: "cache disabled in Settings"))
            return nil
        }
        let request = CacheableRequest(
            modelID: model,
            systemPrompt: systemPrompt.isEmpty ? nil : systemPrompt,
            prompt: outbound
        )
        if let hit = await cache.response(for: request) {
            trace.record(.cacheLookup, .ran(detail: "hit — no provider call, no cost"))
            return hit
        }
        trace.record(.cacheLookup, .noOp(reason: "miss"))
        return nil
    }

    private func recallMemory(for outbound: String, trace: inout PipelineTrace) async -> String {
        guard settings.memoryEnabled else {
            trace.record(.memoryRecall, .skipped(reason: "memory disabled in Settings"))
            return ""
        }
        do {
            let recalled = try await memory.recall(query: outbound, topK: settings.memoryTopK)
            guard !recalled.isEmpty else {
                trace.record(.memoryRecall, .noOp(reason: "nothing relevant remembered"))
                return ""
            }
            trace.record(.memoryRecall, .ran(detail: "recalled \(recalled.count) memory item(s)"))
            return recalled.map { "- \($0.content)" }.joined(separator: "\n")
        } catch {
            trace.record(.memoryRecall, .failed(message: "\(error)"))
            return ""
        }
    }

    private func retrievePassages(
        for outbound: String,
        trace: inout PipelineTrace
    ) async -> ([RetrievedSource], String) {
        guard settings.retrievalEnabled else {
            trace.record(.retrieval, .skipped(reason: "retrieval disabled in Settings"))
            return ([], "")
        }
        do {
            let scored = try await retriever.retrieve(query: outbound, topK: settings.retrievalTopK)
            guard !scored.isEmpty else {
                trace.record(.retrieval, .noOp(reason: "no indexed passages matched"))
                return ([], "")
            }
            trace.record(.retrieval, .ran(detail: "\(scored.count) passage(s) injected"))
            return (
                scored.map(RetrievedSource.init),
                scored.map(\.chunk.text).joined(separator: "\n---\n")
            )
        } catch {
            trace.record(.retrieval, .failed(message: "\(error)"))
            return ([], "")
        }
    }

    /// Runs LAST, so retrieved and recalled text is inside the same budget as the conversation
    /// rather than bolted on after the budget was already satisfied.
    private func compactIfNeeded(
        _ assembled: [ConversationMessage],
        trace: inout PipelineTrace
    ) async -> ([ConversationMessage], Bool) {
        do {
            let budget = CompactionBudget(
                maxTokens: settings.contextWindowTokens,
                reservedForResponse: settings.reservedResponseTokens
            )
            let result = try await compactor.compact(assembled.map(Self.compactable), budget: budget)
            guard !result.strategiesApplied.isEmpty else {
                trace.record(
                    .contextCompaction,
                    .noOp(reason: "\(result.tokensBefore) tokens fits the window")
                )
                return (assembled, false)
            }
            let applied = result.strategiesApplied.joined(separator: ", ")
            trace.record(
                .contextCompaction,
                .ran(detail: "\(result.tokensBefore) → \(result.tokensAfter) tokens via \(applied)")
            )
            return (result.messages.map(Self.conversational), true)
        } catch {
            trace.record(.contextCompaction, .failed(message: "\(error)"))
            return (assembled, false)
        }
    }
}
