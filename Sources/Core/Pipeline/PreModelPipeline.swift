import ExplorationChannelKit
import AgentMemoryKit
import CensoredFeedbackKit
import AnswerabilityKit
import ConformalGateKit
import ContextCompactionKit
import EvidenceSensitivityKit
import Foundation
import SourceIndependenceKit
import GuardrailKit
import MorphologyMatchAnswerability
import PromptTemplateKit
import ProviderGatewayKit
import ResponseCacheKit
import RetrievalKit
import SemanticRouterKit
import SpotlightRAG

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
    /// When true, a tool call stops the turn and waits for the user to sign for it.
    ///
    /// Off by default. A demo that asks permission before its first calculator call teaches that
    /// the prompt is noise, which is exactly the habit the authority layer exists to avoid forming.
    var toolApprovalRequired: Bool = false
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
    /// Nil keeps the dense-only behaviour, and the lexical stage records itself as skipped.
    private let lexical: LexicalIndex?
    private let compactor: ContextCompactor
    /// Judges whether the retrieved passages can answer the question, before anything is sent.
    ///
    /// `.lenient` rather than `.strict`: this is a chat client, and ordinary questions arrive
    /// with one aspect and a partial match. A strict gate would refuse conversation, and a gate
    /// users switch off protects nobody.
    ///
    /// Reads evidence through `MorphologyEvidenceMatcher` rather than the package default. The
    /// default does no stemming, and this app's own budget corpus says `spend` and `spends` while
    /// users ask about `spending` — a gap that made a coverage verdict untrustworthy enough that
    /// this stage could only ever record it. See `PreModelPipeline+Answerability.swift`.
    let answerability: AnswerabilityGate
    /// Measures whether the gate above actually depended on the evidence it was handed.
    let stability: SensitivityAnalyzer
    /// Pure value type, so it needs no isolation and no injection point beyond its policy.
    let independence = SourceIndependenceAnalyzer()
    /// The same judgement the gate makes, in a form that can be re-run over a subset.
    ///
    /// A second engine rather than a handle on the gate's own, because `VerdictProbing` is
    /// synchronous by contract — a probe that awaited an actor could not be a pure function of
    /// its evidence, and the whole measurement depends on it being one. Kept injectable so a
    /// caller that configures a non-default gate can keep the two in step; a mismatch here would
    /// measure the stability of a ruling nobody made.
    let stabilityEngine: AnswerabilityEngine
    /// Where labelled turns accumulate, and the only state in this actor that outlives a send.
    /// Defaulted rather than threaded through every caller, and injected in tests so two of them
    /// cannot certify against each other's turns.
    let calibration: CalibrationStore
    /// Every decision this app made, answered or refused — the population the certificate
    /// above is a promise about, rather than the admitted half of it that gets labelled.
    let censoring: FeedbackLedger?
    /// The exploration budget. Optional and injected exactly as `censoring` is, so two tests
    /// cannot spend each other's.
    let exploration: ExplorationChannel?
    var settings: PipelineSettings

    init(
        prompts: PromptRegistry,
        guardrail: GuardrailPipeline,
        router: SemanticRouter,
        cache: ResponseCache,
        memory: MemoryStore,
        retriever: Retriever,
        lexical: LexicalIndex? = nil,
        compactor: ContextCompactor,
        answerability: AnswerabilityGate = AnswerabilityGate(
            engine: AnswerabilityEngine(policy: .lenient, matcher: MorphologyEvidenceMatcher())
        ),
        stability: SensitivityAnalyzer = SensitivityAnalyzer(policy: .standard),
        stabilityEngine: AnswerabilityEngine = AnswerabilityEngine(
            policy: .lenient,
            matcher: MorphologyEvidenceMatcher()
        ),
        calibration: CalibrationStore = ConformalLedger.shared,
        censoring: FeedbackLedger? = CensoringLedger.shared,
        exploration: ExplorationChannel? = ExplorationBudget.shared,
        settings: PipelineSettings = PipelineSettings()
    ) {
        self.prompts = prompts
        self.guardrail = guardrail
        self.router = router
        self.cache = cache
        self.memory = memory
        self.retriever = retriever
        self.lexical = lexical
        self.compactor = compactor
        self.answerability = answerability
        self.stability = stability
        self.stabilityEngine = stabilityEngine
        self.calibration = calibration
        self.censoring = censoring
        self.exploration = exploration
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
        let sources: [RetrievedSource]
        let retrievalBlock: String
        switch await retrievePassages(for: outbound, trace: &trace) {
        case let .refused(refusal): return .refused(refusal)
        case let .passages(found, block): (sources, retrievalBlock) = (found, block)
        }

        let assembled = assemble(
            systemPrompt: systemPrompt,
            memoryBlock: memoryBlock,
            retrievalBlock: retrievalBlock,
            history: history,
            userText: outbound
        )
        let (finalMessages, didCompact) = await compactIfNeeded(assembled, trace: &trace)

        // After compaction on purpose: the gate should judge the evidence the model will
        // actually receive, not the evidence retrieval happened to find.
        recordEvidenceKeying(of: sources, for: outbound, trace: &trace)
        if let refusal = await refusalBeforeSending(sources: sources, outbound: outbound, trace: &trace) {
            return .refused(refusal)
        }

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

// MARK: - Retrieval

/// An extension rather than more actor body: these three are the only members that reconcile two
/// independent rankings, and `type_body_length` is a fair signal that they had outgrown sitting
/// among the single-stage methods.
extension PreModelPipeline {
    private func retrievePassages(
        for outbound: String,
        trace: inout PipelineTrace
    ) async -> RetrievalResult {
        guard settings.retrievalEnabled else {
            trace.record(.retrieval, .skipped(reason: "retrieval disabled in Settings"))
            trace.record(.sourceConflict, .skipped(reason: "retrieval disabled in Settings"))
            return .passages([], "")
        }
        var dense: [ScoredChunk] = []
        do {
            dense = try await retriever.retrieve(query: outbound, topK: settings.retrievalTopK)
            if dense.isEmpty {
                trace.record(.retrieval, .noOp(reason: "no indexed passages matched"))
            } else {
                trace.record(.retrieval, .ran(detail: "\(dense.count) passage(s) matched"))
            }
        } catch {
            trace.record(.retrieval, .failed(message: "\(error)"))
        }

        let lexicalHits = await lexicalRanking(for: outbound, trace: &trace)
        let fused = fuseRankings(dense: dense, lexical: lexicalHits, trace: &trace)
        guard !fused.isEmpty else {
            trace.record(.sourceConflict, .noOp(reason: "nothing was retrieved to compare"))
            return .passages([], "")
        }

        switch await auditSourceConflicts(fused, for: outbound, trace: &trace) {
        case let .refused(refusal):
            return .refused(refusal)
        case let .admitted(admitted):
            guard !admitted.isEmpty else { return .passages([], "") }
            // Each passage is labelled with the identifier the answer is asked to cite it by.
            // Without a label there is nothing for the model to cite and nothing for the
            // citation stage to check, so attribution would be unverifiable by construction —
            // and an unverifiable attribution is indistinguishable from a correct one.
            let block = admitted
                .map { "[\($0.id)] \($0.snippet)" }
                .joined(separator: "\n---\n")
            return .passages(admitted, block)
        }
    }

    /// The lexical half. Absent when no index was composed, which stays a legitimate configuration.
    private func lexicalRanking(
        for outbound: String,
        trace: inout PipelineTrace
    ) async -> [IndexHit] {
        guard let lexical else {
            trace.record(.lexicalRetrieval, .skipped(reason: "no lexical index is configured"))
            return []
        }
        do {
            let hits = try await lexical.ranking(for: outbound, limit: settings.retrievalTopK)
            guard !hits.isEmpty else {
                trace.record(.lexicalRetrieval, .noOp(reason: "no passage carried those terms"))
                return []
            }
            trace.record(.lexicalRetrieval, .ran(detail: "\(hits.count) passage(s) matched"))
            return hits
        } catch {
            trace.record(.lexicalRetrieval, .failed(message: "\(error)"))
            return []
        }
    }

    /// Reciprocal-rank fusion over whichever halves produced anything.
    ///
    /// Rank rather than score, which is the point of RRF: a cosine similarity and a lexical score
    /// are not on the same scale and averaging them is meaningless. Ordering is comparable even
    /// when the numbers are not.
    private func fuseRankings(
        dense: [ScoredChunk],
        lexical: [IndexHit],
        trace: inout PipelineTrace
    ) -> [RetrievedSource] {
        let denseIDs = dense.map { DocumentID($0.chunk.documentID) }
        let lexicalIDs = lexical.map(\.id)
        let rankings = [denseIDs, lexicalIDs].filter { !$0.isEmpty }
        guard !rankings.isEmpty else {
            trace.record(.rankFusion, .noOp(reason: "neither half returned a passage"))
            return []
        }

        // Described from what was actually fused, never from a fixed corpus: a lookup that only
        // knew the bundled documents would silently drop every passage indexed by anything else,
        // and the dropped ones would look like a retrieval miss rather than a bug here.
        var described: [DocumentID: RetrievedSource] = [:]
        for scored in dense {
            described[DocumentID(scored.chunk.documentID)] = RetrievedSource(scored)
        }
        for hit in lexical where described[hit.id] == nil {
            described[hit.id] = RetrievedSource(
                id: hit.id.rawValue,
                title: hit.title,
                snippet: String(hit.body.prefix(160)),
                relevancePercent: 0
            )
        }

        let fused = RankFusion().fuse(rankings).prefix(settings.retrievalTopK)
        let best = fused.first?.score ?? 1
        let sources: [RetrievedSource] = fused.compactMap { result in
            guard let source = described[result.id] else { return nil }
            return RetrievedSource(
                id: source.id,
                title: source.title,
                snippet: source.snippet,
                // Relative to the best hit: an RRF score is a sum of 1/(k+rank) terms with no
                // upper bound anyone would recognise, so showing it raw would put "0.03" under a
                // passage that is in fact the strongest match there is.
                relevancePercent: best > 0 ? Int((result.score / best * 100).rounded()) : 0,
                // Carried through rather than re-derived. Fusion reorders passages and rescales
                // one number; it learns nothing about when a passage was written, and rebuilding
                // the struct without these would silently undate the whole corpus.
                subject: source.subject,
                observedAt: source.observedAt
            )
        }
        let detail = "\(rankings.count) ranking(s) → \(sources.count) passage(s) injected"
        trace.record(.rankFusion, sources.isEmpty
            ? .noOp(reason: "fusion matched no known document")
            : .ran(detail: detail))
        return sources
    }
}
