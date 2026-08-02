import AgentMemoryKit
import ContextCompactionKit
import Foundation
import GuardrailKit
import PromptTemplateKit
import ResponseCacheKit
import RetrievalKit
import SemanticRouterKit
import SpotlightRAG
import Testing
@testable import AIChatApp

/// The lexical half, and the fusion that reconciles it with the dense half.
@Suite("Hybrid retrieval")
struct HybridRetrievalTests {
    // MARK: - The corpus

    @Test("the two halves index one corpus, or fusion combines rankings over different documents")
    func oneCorpusFeedsBothHalves() {
        let lexicalIDs = Set(AppKnowledge.documents.map(\.id.rawValue))
        let denseIDs = Set(AppKnowledge.retrievalDocuments.map(\.id))
        #expect(lexicalIDs == denseIDs)
        #expect(!lexicalIDs.isEmpty)
    }

    @Test("every passage keeps a stable digest across launches")
    func digestsAreStable() {
        // `IndexableDocument.digest` includes `updatedAt`, so a `Date()` here would give the same
        // document a different digest on every launch and make reconciliation meaningless.
        let first = AppKnowledge.documents.map(\.digest)
        let second = AppKnowledge.documents.map(\.digest)
        #expect(first == second)
        #expect(AppKnowledge.documents.allSatisfy { $0.updatedAt == AppKnowledge.epoch })
    }

    @Test("titles and bodies are addressable by id, and unknown ids simply are not there")
    func lookup() {
        #expect(AppKnowledge.title(for: "budget") == "Budgets and spend")
        #expect(AppKnowledge.body(for: "budget")?.contains("microcents") == true)
        #expect(AppKnowledge.title(for: "nope") == nil)
        #expect(AppKnowledge.body(for: "nope") == nil)
    }

    // MARK: - The lexical index

    @Test("a seeded index finds a passage by a term the embedder would blur away")
    func lexicalFindsExactTerms() async throws {
        let index = LexicalIndex()
        try await index.seed()

        let hits = try await index.ranking(for: "microcents ceiling", limit: 3)
        #expect(!hits.isEmpty)
        #expect(hits.contains { $0.id == DocumentID("budget") })
    }

    @Test("seeding twice replaces rather than duplicates")
    func seedingIsIdempotent() async throws {
        let index = LexicalIndex()
        try await index.seed()
        try await index.seed()

        let hits = try await index.ranking(for: "budget", limit: 10)
        let ids = hits.map(\.id)
        #expect(Set(ids).count == ids.count, "a document must not appear twice")
    }

    @Test("a query matching nothing returns nothing rather than everything")
    func lexicalMisses() async throws {
        let index = LexicalIndex()
        try await index.seed()

        let hits = try await index.ranking(for: "zzzzqqq nonsense", limit: 3)
        #expect(hits.isEmpty)
    }

    @Test("a passage outside the asked-for scope is not returned")
    func scopeIsEnforced() async throws {
        // The mechanism that keeps one principal's passages out of another's results. One scope
        // today, but the query refuses anything outside what it was asked for.
        let index = LexicalIndex(scope: OwnerScope("someone-else"))
        try await index.seed()

        let hits = try await index.ranking(for: "budget", limit: 3)
        #expect(hits.isEmpty, "the corpus is scoped to app, so another scope sees none of it")
    }

    // MARK: - Fusion, through the pipeline

    private func pipeline(lexical: LexicalIndex?) async -> PreModelPipeline {
        let prompts = PromptRegistry()
        _ = try? await prompts.register(name: "chat.system", template: "You are terse.")
        let retriever = Retriever(embedder: HashingEmbeddingProvider())
        for document in AppKnowledge.retrievalDocuments {
            try? await retriever.index(document)
        }
        return PreModelPipeline(
            prompts: prompts,
            guardrail: GuardrailPipeline(policy: GuardrailPolicy()),
            router: SemanticRouter(),
            cache: ResponseCache(capacity: 4),
            memory: MemoryStore(),
            retriever: retriever,
            lexical: lexical,
            compactor: ContextCompactor(strategies: [SlidingWindowCompactionStrategy()])
        )
    }

    private func prepare(
        _ pipeline: PreModelPipeline,
        text: String
    ) async -> (TurnPreparation, PipelineTrace) {
        var trace = PipelineTrace()
        let result = await pipeline.prepare(userText: text, history: [], trace: &trace)
        return (result, trace)
    }

    @Test("both halves run and the fusion says how many rankings it reconciled")
    func fusesBothHalves() async throws {
        let index = LexicalIndex()
        try await index.seed()
        let (result, trace) = await prepare(
            await pipeline(lexical: index),
            text: "how much am I spending, what is the ceiling"
        )

        guard case let .ready(turn) = result else {
            Issue.record("expected .ready")
            return
        }
        #expect(!turn.sources.isEmpty)
        #expect(trace.outcome(for: .lexicalRetrieval)?.summary.contains("matched") == true)
        #expect(trace.outcome(for: .rankFusion)?.summary.contains("2 ranking(s)") == true)
        // Relative to the strongest hit, because a raw reciprocal-rank score is a sum of
        // 1/(k+rank) terms and would render as a couple of percent for the best passage there is.
        #expect(turn.sources.first?.relevancePercent == 100)
        #expect(turn.sources.allSatisfy { (0...100).contains($0.relevancePercent) })
    }

    @Test("with no lexical index the turn still prepares, and the stage says it was skipped")
    func degradesToDenseOnly() async throws {
        let (result, trace) = await prepare(
            await pipeline(lexical: nil),
            text: "how much am I spending"
        )

        guard case .ready = result else {
            Issue.record("expected .ready")
            return
        }
        #expect(
            trace.outcome(for: .lexicalRetrieval)?.summary.contains("no lexical index") == true
        )
        // One ranking is still a ranking: fusion over a single list is order-preserving.
        #expect(trace.outcome(for: .rankFusion)?.summary.contains("1 ranking(s)") == true)
    }

    @Test("retrieval switched off in Settings skips the dense half by name")
    func retrievalDisabled() async throws {
        let index = LexicalIndex()
        try await index.seed()
        let pipeline = await pipeline(lexical: index)
        var settings = PipelineSettings()
        settings.retrievalEnabled = false
        await pipeline.update(settings: settings)

        let (_, trace) = await prepare(pipeline, text: "how much am I spending")
        #expect(trace.outcome(for: .retrieval)?.summary.contains("disabled in Settings") == true)
    }

    @Test("a lexical index that throws is recorded, not swallowed, and the turn continues")
    func lexicalFailureIsRecorded() async throws {
        let (result, trace) = await prepare(
            await pipeline(lexical: LexicalIndex(backend: FailingSearchIndex())),
            text: "how much am I spending"
        )

        guard case .ready = result else {
            Issue.record("a lexical failure must degrade the turn, not refuse it")
            return
        }
        #expect(trace.outcome(for: .lexicalRetrieval)?.isFailure == true)
    }
}

/// A backend whose every operation fails, so the failure branch is exercised rather than reasoned
/// about.
private struct FailingSearchIndex: SearchIndexBackend {
    struct Failure: Error {}

    func upsert(_ payloads: [IndexedPayload]) async throws { throw Failure() }
    func remove(ids: [DocumentID]) async throws { throw Failure() }
    func search(_ query: IndexQuery) async throws -> [IndexHit] { throw Failure() }
}
