import AgentMemoryKit
import ContextCompactionKit
import Foundation
import GuardrailKit
import PromptTemplateKit
import ResponseCacheKit
import RetrievalKit
import SemanticRouterKit
import Testing
@testable import AIChatApp

/// The `sourceConflict` stage, exercised through the real `PreModelPipeline` rather than by
/// calling the package directly — the stage table test only proves a case exists, and a stage that
/// is listed but never runs is exactly the gap this suite is for.
@Suite("Source conflict stage")
struct SourceConflictStageTests {
    private func pipeline() async -> PreModelPipeline {
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
            compactor: ContextCompactor(strategies: [SlidingWindowCompactionStrategy()])
        )
    }

    private func source(_ id: String, _ snippet: String) -> RetrievedSource {
        RetrievedSource(id: id, title: id, snippet: snippet, relevancePercent: 80)
    }

    @Test("the stage always records an outcome, even when retrieval finds nothing to compare")
    func alwaysRecords() async throws {
        var trace = PipelineTrace()
        _ = await pipeline().prepare(userText: "zzzzqqq nonsense", history: [], trace: &trace)
        #expect(
            trace.records.contains { $0.stage == .sourceConflict },
            "a stage with no record is indistinguishable from a stage that is not wired in"
        )
    }

    @Test("a real query through the real corpus reaches the stage")
    func runsOnARealQuery() async throws {
        var trace = PipelineTrace()
        _ = await pipeline().prepare(userText: "what is the budget?", history: [], trace: &trace)
        let record = trace.records.first { $0.stage == .sourceConflict }
        #expect(record != nil)
        #expect(record?.outcome.isFailure == false, "the stage must not break on the bundled corpus")
    }

    @Test("one passage is a no-op, because a single source cannot disagree with itself")
    func singlePassageIsNoOp() async throws {
        var trace = PipelineTrace()
        let result = await pipeline().auditSourceConflicts(
            [source("a", "The timeout is 30 seconds.")],
            for: "request timeout",
            trace: &trace
        )
        #expect(result == .admitted([source("a", "The timeout is 30 seconds.")]))
        let record = trace.records.first { $0.stage == .sourceConflict }
        #expect(record?.outcome == .noOp(reason: "fewer than two passages; nothing to compare"))
    }

    @Test("passages that agree are admitted untouched")
    func agreementIsAdmitted() async throws {
        var trace = PipelineTrace()
        let passages = [
            source("a", "The request timeout is 30 seconds."),
            source("b", "Requests stop after 30 seconds.")
        ]
        let result = await pipeline().auditSourceConflicts(passages, for: "request timeout", trace: &trace)
        #expect(result == .admitted(passages))
        #expect(trace.records.first { $0.stage == .sourceConflict }?.outcome.isRefusal == false)
    }

    /// The refusal path, and the reason the stage exists. Two documents, one topic, nothing to
    /// separate them — so the turn does not go out.
    @Test("sources that contradict each other with no tie-breaker refuse the turn")
    func contradictionRefuses() async throws {
        var trace = PipelineTrace()
        let result = await pipeline().auditSourceConflicts(
            [
                source("doc-a", "The request timeout is 30 seconds."),
                source("doc-b", "The request timeout is 60 seconds.")
            ],
            for: "request timeout",
            trace: &trace
        )

        guard case let .refused(refusal) = result else {
            Issue.record("contradictory sources with no tie-breaker must refuse")
            return
        }
        #expect(refusal.stage == .sourceConflict)
        #expect(!refusal.headline.isEmpty)
        #expect(!refusal.explanation.isEmpty)
        #expect(refusal.recovery != nil, "a refusal the user cannot act on is barely better than silence")
        #expect(refusal.recoveryTitle != nil)
    }

    /// The refusal has to reach the trace, not just the return value. The banner reads the trace.
    @Test("the refusal is recorded on the trace, which is what reaches the user")
    func refusalReachesTheTrace() async throws {
        var trace = PipelineTrace()
        _ = await pipeline().auditSourceConflicts(
            [
                source("doc-a", "Caching is enabled by default."),
                source("doc-b", "Caching is disabled by default.")
            ],
            for: "response cache default",
            trace: &trace
        )
        let record = trace.records.first { $0.stage == .sourceConflict }
        #expect(record?.outcome.isRefusal == true)
    }

    /// Corroboration is counted in documents. Two independent sources outvote one.
    @Test("the minority position is withheld when independent documents outnumber it")
    func minorityIsWithheld() async throws {
        var trace = PipelineTrace()
        let result = await pipeline().auditSourceConflicts(
            [
                source("doc-a", "The request timeout is 30 seconds."),
                source("doc-b", "Requests stop after 30 seconds."),
                source("doc-c", "The request timeout is 60 seconds.")
            ],
            for: "request timeout",
            trace: &trace
        )
        guard case let .admitted(admitted) = result else {
            Issue.record("a decidable conflict must not refuse")
            return
        }
        #expect(admitted.map(\.id) == ["doc-a", "doc-b"])
        #expect(trace.records.first { $0.stage == .sourceConflict }?.outcome.isRefusal == false)
    }

    @Test("a query with no subject skips rather than comparing everything to everything")
    func subjectlessQuerySkips() async throws {
        var trace = PipelineTrace()
        let passages = [
            source("doc-a", "The request timeout is 30 seconds."),
            source("doc-b", "The request timeout is 60 seconds.")
        ]
        let result = await pipeline().auditSourceConflicts(passages, for: "the of and", trace: &trace)
        #expect(result == .admitted(passages))
        #expect(
            trace.records.first { $0.stage == .sourceConflict }?.outcome
                == .skipped(reason: "the query carries no subject to scope on")
        )
    }

    /// The refusal has to survive the whole of `prepare`, not just the audit function. A stage
    /// that refuses into a value nobody returns is a stage that refuses in silence.
    @Test("a contradictory corpus refuses the whole turn, not just the audit")
    func refusalReachesPrepare() async throws {
        let prompts = PromptRegistry()
        _ = try? await prompts.register(name: "chat.system", template: "You are terse.")
        let retriever = Retriever(embedder: HashingEmbeddingProvider())
        for (id, text) in [
            ("doc-fast", "Widget latency. The widget latency budget is 30 milliseconds."),
            ("doc-slow", "Widget latency. The widget latency budget is 90 milliseconds.")
        ] {
            try? await retriever.index(RetrievalKit.Document(id: id, text: text, metadata: [:]))
        }
        let pipeline = PreModelPipeline(
            prompts: prompts,
            guardrail: GuardrailPipeline(policy: GuardrailPolicy()),
            router: SemanticRouter(),
            cache: ResponseCache(capacity: 4),
            memory: MemoryStore(),
            retriever: retriever,
            compactor: ContextCompactor(strategies: [SlidingWindowCompactionStrategy()])
        )

        var trace = PipelineTrace()
        let preparation = await pipeline.prepare(
            userText: "what is the widget latency budget?",
            history: [],
            trace: &trace
        )
        guard case let .refused(refusal) = preparation else {
            Issue.record("two sources disagreeing on one number must stop the turn")
            return
        }
        #expect(refusal.stage == .sourceConflict)
        #expect(trace.records.first { $0.stage == .sourceConflict }?.outcome.isRefusal == true)
        #expect(
            !trace.records.contains { $0.stage == .contextCompaction },
            "nothing after the refusal should have run"
        )
    }

    /// A malformed retrieved set is a failure, not a refusal, and the turn continues on the
    /// evidence rather than dying — the audit is an improvement to the pipeline, not a gate the
    /// pipeline cannot survive losing.
    @Test("a duplicate passage id fails the stage without taking the turn down")
    func duplicateIDsFailOpen() async throws {
        var trace = PipelineTrace()
        let passages = [
            source("doc-a", "The request timeout is 30 seconds."),
            source("doc-a", "The request timeout is 60 seconds.")
        ]
        let result = await pipeline().auditSourceConflicts(passages, for: "request timeout", trace: &trace)
        #expect(result == .admitted(passages))
        #expect(trace.records.first { $0.stage == .sourceConflict }?.outcome.isFailure == true)
    }

    @Test("the stage is owned by SourceConflictKit and titled for a Diagnostics reader")
    func stageMetadata() {
        #expect(PipelineStage.sourceConflict.package == "SourceConflictKit")
        #expect(PipelineStage.sourceConflict.title == "Source conflict")
        #expect(PipelineStage.sourceConflict.id == "sourceConflict")
    }
}
